// SPDX-License-Identifier: GPL-3.0-or-later
pragma solidity ^0.8.31;

import {EnumerableSet} from "@openzeppelin/contracts/utils/structs/EnumerableSet.sol";
import {LibAppStorage, AppStorage, Reservation, INSTITUTION_ROLE} from "./LibAppStorage.sol";
import {LibTracking} from "./LibTracking.sol";
import {LibReservationCancellation} from "./LibReservationCancellation.sol";
import {LibReservationConfig} from "./LibReservationConfig.sol";
import {LibReputation} from "./LibReputation.sol";

library LibInstitutionalReservationRelease {
    using EnumerableSet for EnumerableSet.Bytes32Set;
    using EnumerableSet for EnumerableSet.AddressSet;

    error InvalidBatchSize();
    error InvalidPucHash();
    error UnknownInstitution();
    error UnauthorizedInstitution();
    error BackendMissing();
    error NotBackend();

    uint8 internal constant _PENDING = 0;
    uint8 internal constant _CONFIRMED = 1;
    uint8 internal constant _ACCESS_AUTHORIZED = 2;
    uint8 internal constant _SETTLED = 3;

    uint256 internal constant _PENDING_REQUEST_TTL = LibReservationConfig.PENDING_REQUEST_TTL;

    function releaseInstitutionalExpiredReservations(
        address institutionalProvider,
        bytes32 pucHash,
        uint256 labId,
        uint256 maxBatch
    ) external returns (uint256 processed) {
        AppStorage storage s = LibAppStorage.diamondStorage();
        if (!s.roleMembers[INSTITUTION_ROLE].contains(institutionalProvider)) revert UnknownInstitution();
        address backend = s.institutionalBackends[institutionalProvider];
        if (backend == address(0)) revert BackendMissing();
        if (msg.sender != backend) revert NotBackend();

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

            if (
                reservation.end < currentTime
                    && (reservation.status == _CONFIRMED || reservation.status == _ACCESS_AUTHORIZED)
            ) {
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

    function _simpleFinalizeReservation(
        AppStorage storage s,
        bytes32 key,
        Reservation storage reservation,
        uint256 labId,
        address trackingKey
    ) private {
        uint8 previousStatus = reservation.status;
        bool sessionStartedRecorded = s.reservationSessionStartedRecorded[key];

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
        if (s.activeReservationCountByTokenAndUser[labId][trackingKey] > 0) {
            s.activeReservationCountByTokenAndUser[labId][trackingKey]--;
        }
        _removeReservationIndex(s.reservationKeysByTokenAndUser[labId][trackingKey], key);
    }

    /// @dev Index cleanup is intentionally idempotent for reservations created before
    /// a particular secondary index was introduced or repaired.
    function _removeReservationIndex(
        EnumerableSet.Bytes32Set storage set,
        bytes32 key
    ) private {
        if (!set.remove(key)) return;
    }
}
