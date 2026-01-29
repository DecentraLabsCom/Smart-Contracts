// SPDX-License-Identifier: GPL-3.0-or-later
pragma solidity ^0.8.31;

import {EnumerableSet} from "@openzeppelin/contracts/utils/structs/EnumerableSet.sol";
import {IERC721} from "@openzeppelin/contracts/token/ERC721/IERC721.sol";
import {LibAppStorage, AppStorage, Reservation} from "./LibAppStorage.sol";
import {LibTracking} from "./LibTracking.sol";
import {LibReservationCancellation} from "./LibReservationCancellation.sol";

interface IReservableTokenCalcV {
    function calculateRequiredStake(
        address provider,
        uint256 listedLabsCount
    ) external view returns (uint256);
}

library LibInstitutionalReservationRequestValidation {
    using EnumerableSet for EnumerableSet.Bytes32Set;

    error InstitutionalBackendMissing();
    error OnlyInstitutionalBackend();
    error InvalidInstitutionalUserId();
    error MaxReservationsReached();

    uint8 internal constant _PENDING = 0;
    uint8 internal constant _CONFIRMED = 1;
    uint8 internal constant _IN_USE = 2;
    uint8 internal constant _COLLECTED = 4;
    uint8 internal constant _CANCELLED = 5;

    uint32 internal constant _RESERVATION_MARGIN = 0;
    uint256 internal constant _PENDING_REQUEST_TTL = 1 hours;

    uint256 internal constant _MAX_RESERVATIONS_PER_LAB_USER = 10;

    function validateInstRequest(
        address provider,
        string calldata userId,
        uint256 labId,
        uint32 start,
        uint32 end
    ) external returns (address owner, bytes32 key, address trackingKey) {
        AppStorage storage s = LibAppStorage.diamondStorage();

        if (s.institutionalBackends[provider] == address(0)) revert InstitutionalBackendMissing();
        if (msg.sender != s.institutionalBackends[provider] && msg.sender != address(this)) {
            revert OnlyInstitutionalBackend();
        }
        if (bytes(userId).length == 0 || bytes(userId).length > 256) revert InvalidInstitutionalUserId();
        if (!s.tokenStatus[labId]) revert();

        owner = IERC721(address(this)).ownerOf(labId);
        if (
            s.providerStakes[owner].stakedAmount
                < IReservableTokenCalcV(address(this))
                    .calculateRequiredStake(owner, s.providerStakes[owner].listedLabsCount)
        ) {
            revert();
        }
        if (start >= end || start <= block.timestamp + _RESERVATION_MARGIN) revert();

        key = _getReservationKey(labId, start);
        trackingKey = LibTracking.trackingKeyFromInstitutionHash(provider, keccak256(bytes(userId)));

        uint256 count = s.activeReservationCountByTokenAndUser[labId][trackingKey];
        if (count >= _MAX_RESERVATIONS_PER_LAB_USER - 2) {
            _releaseExpiredReservationsInternal(s, labId, trackingKey, _MAX_RESERVATIONS_PER_LAB_USER);
            count = s.activeReservationCountByTokenAndUser[labId][trackingKey];
        }
        if (count >= _MAX_RESERVATIONS_PER_LAB_USER) revert MaxReservationsReached();

        Reservation storage existing = s.reservations[key];
        if (existing.renter != address(0) && existing.status != _CANCELLED && existing.status != _COLLECTED) revert();
    }

    function _releaseExpiredReservationsInternal(
        AppStorage storage s,
        uint256 labId,
        address trackingKey,
        uint256 maxBatch
    ) private returns (uint256 processed) {
        EnumerableSet.Bytes32Set storage userReservations = s.reservationKeysByTokenAndUser[labId][trackingKey];
        uint256 len = userReservations.length();
        uint256 i;
        uint256 currentTime = block.timestamp;

        while (i < len && processed < maxBatch) {
            bytes32 key = userReservations.at(i);
            Reservation storage reservation = s.reservations[key];

            if (reservation.end < currentTime && reservation.status == _CONFIRMED) {
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
        reservation.status = _COLLECTED;
        s.reservationKeysByToken[labId].remove(key);
        s.renters[reservation.renter].remove(key);
        if (s.totalReservationsCount > 0) s.totalReservationsCount--;
        if (s.activeReservationCountByTokenAndUser[labId][trackingKey] > 0) {
            s.activeReservationCountByTokenAndUser[labId][trackingKey]--;
        }
        s.reservationKeysByTokenAndUser[labId][trackingKey].remove(key);
    }

    function _getReservationKey(
        uint256 labId,
        uint32 time
    ) private pure returns (bytes32) {
        return keccak256(abi.encodePacked(labId, time));
    }
}
