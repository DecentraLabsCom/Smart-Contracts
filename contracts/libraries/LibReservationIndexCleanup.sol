// SPDX-License-Identifier: GPL-3.0-or-later
pragma solidity ^0.8.31;

import {EnumerableSet} from "@openzeppelin/contracts/utils/structs/EnumerableSet.sol";
import {AppStorage, Reservation, Tree} from "./LibAppStorage.sol";
import {LibTracking} from "./LibTracking.sol";
import {RivalIntervalTreeLibrary} from "./RivalIntervalTreeLibrary.sol";

/// @title LibReservationIndexCleanup
/// @notice Shared cleanup for reservations that leave the active lifecycle.
/// @dev Reservation creation writes the same record to several bounded indexes. Every finalizer
///      must remove the calendar slot, global index, renter index, and (for institutional records)
///      both user-facing institutional indexes together.
library LibReservationIndexCleanup {
    using EnumerableSet for EnumerableSet.Bytes32Set;
    using RivalIntervalTreeLibrary for Tree;

    uint8 internal constant _CONFIRMED = 1;
    uint8 internal constant _ACCESS_AUTHORIZED = 2;

    function removeFinalizedReservationIndexes(
        AppStorage storage s,
        bytes32 key,
        Reservation storage reservation
    ) internal {
        uint256 labId = reservation.labId;
        if (s.calendars[labId].root != 0 && s.calendars[labId].exists(reservation.start)) {
            s.calendars[labId].remove(reservation.start);
        }

        _removeReservationKey(s.reservationKeysByToken[labId], key);
        _removeReservationKey(s.renters[reservation.renter], key);
        _removeUserReservationIndex(s, labId, reservation.renter, key);

        bytes32 pucHash = s.reservationPucHash[key];
        if (pucHash != bytes32(0)) {
            address trackingKey = LibTracking.trackingKeyFromInstitutionHash(reservation.payerInstitution, pucHash);
            _removeUserReservationIndex(s, labId, trackingKey, key);
            _removeReservationKey(s.renters[trackingKey], key);
        }
    }

    function _removeReservationKey(
        EnumerableSet.Bytes32Set storage set,
        bytes32 key
    ) private {
        set.remove(key);
    }

    function _removeUserReservationIndex(
        AppStorage storage s,
        uint256 labId,
        address user,
        bytes32 key
    ) private {
        EnumerableSet.Bytes32Set storage reservations = s.reservationKeysByTokenAndUser[labId][user];
        if (!reservations.remove(key)) return;

        if (s.activeReservationCountByTokenAndUser[labId][user] > 0) {
            s.activeReservationCountByTokenAndUser[labId][user]--;
        }
        if (s.activeReservationByTokenAndUser[labId][user] == key) {
            s.activeReservationByTokenAndUser[labId][user] = _findNextActiveReservation(s, labId, user);
        }
    }

    function _findNextActiveReservation(
        AppStorage storage s,
        uint256 labId,
        address user
    ) private view returns (bytes32 nextKey) {
        EnumerableSet.Bytes32Set storage reservations = s.reservationKeysByTokenAndUser[labId][user];
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
