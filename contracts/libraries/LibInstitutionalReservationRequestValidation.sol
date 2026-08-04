// SPDX-License-Identifier: GPL-3.0-or-later
pragma solidity ^0.8.31;

import {EnumerableSet} from "@openzeppelin/contracts/utils/structs/EnumerableSet.sol";
import {LibAppStorage, AppStorage, Reservation, ProviderNetworkStatus} from "./LibAppStorage.sol";
import {LibERC721Storage} from "./LibERC721Storage.sol";
import {LibTracking} from "./LibTracking.sol";
import {LibReservationCancellation} from "./LibReservationCancellation.sol";
import {LibReservationConfig} from "./LibReservationConfig.sol";
import {LibInstitutionalReservationSettlement} from "./LibInstitutionalReservationSettlement.sol";

// Slither reports a library as missing inheritance even though Solidity libraries
// cannot inherit interfaces. The validation facet implements IInstValidation.
// slither-disable-next-line missing-inheritance
library LibInstitutionalReservationRequestValidation {
    using EnumerableSet for EnumerableSet.Bytes32Set;

    error InstitutionalBackendMissing();
    error OnlyInstitutionalBackend();
    error InvalidInstitutionalUserId();
    error MaxReservationsReached();

    uint8 internal constant _PENDING = 0;
    uint8 internal constant _SETTLED = 3;
    uint8 internal constant _CANCELLED = 4;

    uint32 internal constant _RESERVATION_MARGIN = 0;
    uint256 internal constant _PENDING_REQUEST_TTL = LibReservationConfig.PENDING_REQUEST_TTL;

    uint256 internal constant _MAX_RESERVATIONS_PER_LAB_USER = 10;

    function validateInstRequest(
        address provider,
        bytes32 pucHash,
        uint256 labId,
        uint32 start,
        uint32 end
    ) external returns (address owner, bytes32 key, address trackingKey) {
        AppStorage storage s = LibAppStorage.diamondStorage();

        if (s.institutionalBackends[provider] == address(0)) revert InstitutionalBackendMissing();
        if (msg.sender != s.institutionalBackends[provider] && msg.sender != address(this)) {
            revert OnlyInstitutionalBackend();
        }
        if (pucHash == bytes32(0)) revert InvalidInstitutionalUserId();
        if (!s.tokenStatus[labId] || s.labReservationIntakeStopped[labId]) revert();

        owner = LibERC721Storage.ownerOf(labId);
        if (s.providerNetworkStatus[owner] != ProviderNetworkStatus.ACTIVE) {
            revert();
        }
        if (start >= end || start <= block.timestamp + _RESERVATION_MARGIN) revert();

        key = _getReservationKey(labId, start, pucHash);
        trackingKey = LibTracking.trackingKeyFromInstitutionHash(provider, pucHash);

        uint256 count = s.activeReservationCountByTokenAndUser[labId][trackingKey];
        if (count >= _MAX_RESERVATIONS_PER_LAB_USER - 2) {
            _releaseExpiredReservationsInternal(s, labId, trackingKey, _MAX_RESERVATIONS_PER_LAB_USER);
            count = s.activeReservationCountByTokenAndUser[labId][trackingKey];
        }
        if (count >= _MAX_RESERVATIONS_PER_LAB_USER) revert MaxReservationsReached();

        Reservation storage existing = s.reservations[key];
        if (existing.renter != address(0) && existing.status != _CANCELLED && existing.status != _SETTLED) {
            if (existing.status == _PENDING) {
                uint256 ttl = existing.requestPeriodDuration;
                if (ttl == 0) ttl = _PENDING_REQUEST_TTL;
                bool expired = existing.requestPeriodStart == 0
                    || LibReservationConfig.isPendingRequestExpired(
                        existing.requestPeriodStart, ttl, existing.start, block.timestamp
                    );
                if (expired) {
                    LibReservationCancellation.cancelReservation(key);
                    return (owner, key, trackingKey);
                }
            }
            revert();
        }
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

            if (LibInstitutionalReservationSettlement.finalizeExpiredReservation(
                    s, key, reservation, labId, currentTime
                )) {
                len = userReservations.length();
                unchecked {
                    ++processed;
                }
                continue;
            }
            if (reservation.status == _PENDING) {
                uint256 ttl = reservation.requestPeriodDuration;
                if (ttl == 0) ttl = _PENDING_REQUEST_TTL;
                bool expired = reservation.requestPeriodStart == 0
                    || LibReservationConfig.isPendingRequestExpired(
                        reservation.requestPeriodStart, ttl, reservation.start, currentTime
                    );
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

    function _getReservationKey(
        uint256 labId,
        uint32 time,
        bytes32 pucHash
    ) private pure returns (bytes32) {
        return keccak256(abi.encodePacked(labId, time, pucHash));
    }
}
