// SPDX-License-Identifier: GPL-3.0-or-later
pragma solidity ^0.8.31;

import {EnumerableSet} from "@openzeppelin/contracts/utils/structs/EnumerableSet.sol";
import {LibAppStorage, AppStorage, Reservation, INSTITUTION_ROLE} from "./LibAppStorage.sol";
import {LibTracking} from "./LibTracking.sol";
import {LibReservationCancellation} from "./LibReservationCancellation.sol";
import {LibReservationConfig} from "./LibReservationConfig.sol";
import {LibReputation} from "./LibReputation.sol";
import {LibProviderReceivable} from "./LibProviderReceivable.sol";
import {LibHeap} from "./LibHeap.sol";

interface IInstitutionalTreasuryFacetRelease {
    function refundToInstitutionalTreasuryForReservation(
        address provider,
        bytes32 pucHash,
        bytes32 reservationKey,
        uint256 amount
    ) external;
}

library LibInstitutionalReservationRelease {
    using EnumerableSet for EnumerableSet.Bytes32Set;
    using EnumerableSet for EnumerableSet.AddressSet;

    error InvalidBatchSize();
    error InvalidPucHash();
    error UnknownInstitution();

    uint8 internal constant _PENDING = 0;
    uint8 internal constant _CONFIRMED = 1;
    uint8 internal constant _ACCESS_AUTHORIZED = 2;
    uint8 internal constant _SETTLED = 3;

    uint256 internal constant _PENDING_REQUEST_TTL = LibReservationConfig.PENDING_REQUEST_TTL;

    /// @notice Finalize expired reservations for an institutional user.
    /// @dev Permissionless by design: refunds and provider receivable accruals are
    ///      determined from the reservation state, so they do not depend on the
    ///      payer institution's backend remaining available or cooperating.
    function releaseInstitutionalExpiredReservations(
        address institutionalProvider,
        bytes32 pucHash,
        uint256 labId,
        uint256 maxBatch
    ) external returns (uint256 processed) {
        AppStorage storage s = LibAppStorage.diamondStorage();
        if (!s.roleMembers[INSTITUTION_ROLE].contains(institutionalProvider)) revert UnknownInstitution();

        if (maxBatch == 0 || maxBatch > 50) revert InvalidBatchSize();
        if (pucHash == bytes32(0)) revert InvalidPucHash();

        address trackingKey = LibTracking.trackingKeyFromInstitutionHash(institutionalProvider, pucHash);
        return _releaseExpiredReservationsInternal(s, labId, trackingKey, maxBatch);
    }

    function _releaseExpiredReservationsInternal(
        AppStorage storage s,
        uint256 labId,
        address trackingKey,
        uint256 maxBatch
    ) private returns (uint256 processed) {
        EnumerableSet.Bytes32Set storage userReservations = s.reservationKeysByTokenAndUser[labId][trackingKey];
        uint256 len = userReservations.length();
        uint256 i = 0;
        uint256 currentTime = block.timestamp;

        while (i < len && processed < maxBatch) {
            bytes32 key = userReservations.at(i);
            Reservation storage reservation = s.reservations[key];

            if (_isEconomicallyExpired(s, reservation, key, currentTime)) {
                _simpleFinalizeReservation(s, key, reservation, labId, trackingKey);
                len = userReservations.length();
                unchecked {
                    ++processed;
                }
                continue;
            }
            if (reservation.status == _PENDING) {
                uint256 ttl = reservation.requestPeriodDuration;
                if (ttl == 0) ttl = _PENDING_REQUEST_TTL;
                bool expired =
                    reservation.requestPeriodStart == 0 || currentTime >= reservation.requestPeriodStart + ttl;
                if (expired) {
                    LibReservationCancellation.cancelReservation(key);
                    len = userReservations.length();
                    unchecked {
                        ++processed;
                    }
                    continue;
                }
            }
            unchecked {
                ++i;
            }
        }

        return processed;
    }

    function _isEconomicallyExpired(
        AppStorage storage s,
        Reservation storage reservation,
        bytes32 key,
        uint256 currentTime
    ) private view returns (bool) {
        if (reservation.status == _CONFIRMED) {
            return reservation.end < currentTime;
        }
        if (reservation.status != _ACCESS_AUTHORIZED) {
            return false;
        }

        if (s.reservationSessionStartedRecorded[key]) {
            return reservation.end < currentTime;
        }

        return currentTime > LibReservationConfig.sessionAttestationDeadline(reservation.end);
    }

    function _simpleFinalizeReservation(
        AppStorage storage s,
        bytes32 key,
        Reservation storage reservation,
        uint256 labId,
        address trackingKey
    ) private {
        uint8 previousStatus = reservation.status;
        bool sessionStartedRecorded = s.reservationSessionStartedRecorded[key];

        LibHeap.removePayoutCandidates(s, labId, key);
        if (sessionStartedRecorded) {
            if (reservation.providerShare > 0) {
                LibProviderReceivable.accrueReceivable(labId, reservation.providerShare, key);
                LibProviderReceivable.updateAccruedTimestamp(labId, block.timestamp);
            }
        } else if (reservation.price > 0) {
            IInstitutionalTreasuryFacetRelease(address(this))
                .refundToInstitutionalTreasuryForReservation(
                    reservation.payerInstitution, s.reservationPucHash[key], key, reservation.price
                );
        }

        reservation.status = _SETTLED;
        if (previousStatus == _ACCESS_AUTHORIZED && sessionStartedRecorded) {
            LibReputation.recordCompletion(labId);
        }
        if (previousStatus == _CONFIRMED || previousStatus == _ACCESS_AUTHORIZED || previousStatus == _PENDING) {
            if (s.labActiveReservationCount[labId] > 0) s.labActiveReservationCount[labId]--;
            if (s.providerActiveReservationCount[reservation.labProvider] > 0) {
                s.providerActiveReservationCount[reservation.labProvider]--;
            }
        }
        _removeReservationIndex(s.reservationKeysByToken[labId], key);
        _removeReservationIndex(s.renters[reservation.renter], key);
        if (s.totalReservationsCount > 0) s.totalReservationsCount--;
        _removeActiveReservationIndex(s, labId, trackingKey, key);
    }

    /// @dev Index cleanup is intentionally idempotent for reservations created before
    /// a particular secondary index was introduced or repaired.
    function _removeReservationIndex(
        EnumerableSet.Bytes32Set storage set,
        bytes32 key
    ) private {
        if (!set.remove(key)) return;
    }

    function _removeActiveReservationIndex(
        AppStorage storage s,
        uint256 labId,
        address trackingKey,
        bytes32 key
    ) private {
        EnumerableSet.Bytes32Set storage reservations = s.reservationKeysByTokenAndUser[labId][trackingKey];
        if (!reservations.remove(key)) return;
        if (s.activeReservationCountByTokenAndUser[labId][trackingKey] > 0) {
            s.activeReservationCountByTokenAndUser[labId][trackingKey]--;
        }
        if (s.activeReservationByTokenAndUser[labId][trackingKey] == key) {
            s.activeReservationByTokenAndUser[labId][trackingKey] = _findNextActiveReservation(s, labId, trackingKey);
        }
    }

    function _findNextActiveReservation(
        AppStorage storage s,
        uint256 labId,
        address trackingKey
    ) private view returns (bytes32 nextKey) {
        EnumerableSet.Bytes32Set storage reservations = s.reservationKeysByTokenAndUser[labId][trackingKey];
        uint32 earliestStart = type(uint32).max;
        for (uint256 i; i < reservations.length();) {
            bytes32 candidateKey = reservations.at(i);
            Reservation storage candidate = s.reservations[candidateKey];
            if (
                (candidate.status == _CONFIRMED || candidate.status == _ACCESS_AUTHORIZED)
                    && candidate.start < earliestStart
            ) {
                earliestStart = candidate.start;
                nextKey = candidateKey;
            }
            unchecked {
                ++i;
            }
        }
    }
}
