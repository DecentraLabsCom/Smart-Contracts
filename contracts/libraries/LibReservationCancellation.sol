// SPDX-License-Identifier: GPL-3.0-or-later
pragma solidity ^0.8.33;

import {EnumerableSet} from "@openzeppelin/contracts/utils/structs/EnumerableSet.sol";
import {
    LibAppStorage,
    AppStorage,
    Reservation,
    PastReservationBuffer,
    UserActiveReservation
} from "./LibAppStorage.sol";
import {LibTracking} from "./LibTracking.sol";
import {RivalIntervalTreeLibrary, Tree} from "./RivalIntervalTreeLibrary.sol";

library LibReservationCancellation {
    using EnumerableSet for EnumerableSet.Bytes32Set;
    using RivalIntervalTreeLibrary for Tree;

    uint8 internal constant _PENDING = 0;
    uint8 internal constant _CONFIRMED = 1;
    uint8 internal constant _IN_USE = 2;
    uint8 internal constant _COMPLETED = 3;
    uint8 internal constant _COLLECTED = 4;
    uint8 internal constant _CANCELLED = 5;

    uint8 internal constant _TOKEN_BUFFER_CAP = 40;
    uint8 internal constant _USER_BUFFER_CAP = 20;

    function cancelReservation(
        bytes32 reservationKey
    ) internal {
        AppStorage storage s = LibAppStorage.diamondStorage();
        Reservation storage reservation = s.reservations[reservationKey];
        bytes32 storedHash = s.reservationPucHash[reservationKey];
        bool isInstitutional = storedHash != bytes32(0);
        address trackingKey = isInstitutional
            ? LibTracking.trackingKeyFromInstitutionHash(reservation.renter, storedHash)
            : reservation.renter;
        uint256 labId = reservation.labId;

        if (reservation.status == _CONFIRMED || reservation.status == _IN_USE || reservation.status == _PENDING) {
            if (s.activeReservationCountByTokenAndUser[labId][reservation.renter] > 0) {
                s.activeReservationCountByTokenAndUser[labId][reservation.renter]--;
            }
            s.reservationKeysByTokenAndUser[labId][reservation.renter].remove(reservationKey);

            if (
                (reservation.status == _CONFIRMED || reservation.status == _IN_USE)
                    && s.activeReservationByTokenAndUser[labId][reservation.renter] == reservationKey
            ) {
                bytes32 nextKey = _findNextEarliestReservation(s, labId, reservation.renter);
                s.activeReservationByTokenAndUser[labId][reservation.renter] = nextKey;
            }
        }

        s.reservationKeysByToken[labId].remove(reservationKey);
        s.renters[reservation.renter].remove(reservationKey);

        _recordPastOnCancel(s, reservation, reservationKey, trackingKey);

        _cancelReservationBase(s, reservationKey, reservation);

        if (isInstitutional) {
            if (s.activeReservationCountByTokenAndUser[labId][trackingKey] > 0) {
                s.activeReservationCountByTokenAndUser[labId][trackingKey]--;
            }
            s.reservationKeysByTokenAndUser[labId][trackingKey].remove(reservationKey);

            if (s.activeReservationByTokenAndUser[labId][trackingKey] == reservationKey) {
                bytes32 nextKey = _findNextEarliestReservation(s, labId, trackingKey);
                s.activeReservationByTokenAndUser[labId][trackingKey] = nextKey;
            }

            s.renters[trackingKey].remove(reservationKey);
            _invalidateInstitutionalActiveReservation(s, labId, reservation, reservationKey);
        }
    }

    function applyCancellationFees(
        uint256 labId,
        uint96 providerFee,
        uint96 treasuryFee,
        uint96 governanceFee
    ) internal {
        AppStorage storage s = LibAppStorage.diamondStorage();
        if (providerFee > 0) {
            s.pendingProviderPayout[labId] += providerFee;
            if (block.timestamp > s.pendingProviderLastUpdated[labId]) {
                s.pendingProviderLastUpdated[labId] = block.timestamp;
            }
        }
        if (treasuryFee > 0) {
            s.pendingProjectTreasury += treasuryFee;
        }
        if (governanceFee > 0) {
            s.pendingGovernance += governanceFee;
        }
    }

    function _cancelReservationBase(
        AppStorage storage s,
        bytes32 reservationKey,
        Reservation storage reservation
    ) private {
        bool wasActive = _isActiveReservationStatus(reservation.status);
        if (reservation.status == _CONFIRMED || reservation.status == _IN_USE) {
            _removeReservationFromCalendar(s, reservation.labId, reservation.start);
        }

        if (wasActive) {
            _decrementActiveReservationCounters(s, reservation);
        }

        reservation.status = _CANCELLED;

        if (s.payoutHeapContains[reservationKey]) {
            s.payoutHeapInvalidCount[reservation.labId]++;
        }

        if (s.totalReservationsCount > 0) {
            s.totalReservationsCount--;
        }
    }

    function _recordPastOnCancel(
        AppStorage storage s,
        Reservation storage reservation,
        bytes32 reservationKey,
        address trackingKey
    ) private {
        address user = trackingKey;
        if (user == address(0)) {
            return;
        }
        _recordPast(s, reservation.labId, user, reservationKey, uint32(block.timestamp));
    }

    function _recordPast(
        AppStorage storage s,
        uint256 labId,
        address userTrackingKey,
        bytes32 reservationKey,
        uint32 endTime
    ) private {
        _insertPast(s.pastReservationsByToken[labId], reservationKey, endTime, _TOKEN_BUFFER_CAP);
        _insertPast(s.pastReservationsByTokenAndUser[labId][userTrackingKey], reservationKey, endTime, _USER_BUFFER_CAP);
    }

    function _insertPast(
        PastReservationBuffer storage buf,
        bytes32 key,
        uint32 endTime,
        uint8 cap
    ) private {
        uint8 size = buf.size;
        if (size > cap) {
            size = cap;
            buf.size = cap;
        }
        if (size == cap && endTime <= buf.ends[size - 1]) {
            return;
        }
        uint8 pos = size;
        while (pos > 0 && endTime > buf.ends[pos - 1]) {
            pos--;
        }
        uint8 upper = size < cap ? size : cap - 1;
        for (uint8 i = upper; i > pos; i--) {
            buf.keys[i] = buf.keys[i - 1];
            buf.ends[i] = buf.ends[i - 1];
        }
        buf.keys[pos] = key;
        buf.ends[pos] = endTime;
        if (size < cap) {
            buf.size = size + 1;
        }
    }

    function _findNextEarliestReservation(
        AppStorage storage s,
        uint256 labId,
        address user
    ) private view returns (bytes32) {
        EnumerableSet.Bytes32Set storage tokenUserReservations = s.reservationKeysByTokenAndUser[labId][user];
        bytes32 earliestKey = bytes32(0);
        uint32 earliestStart = type(uint32).max;
        uint256 length = tokenUserReservations.length();
        for (uint256 i; i < length;) {
            bytes32 key = tokenUserReservations.at(i);
            Reservation storage res = s.reservations[key];
            if (
                (res.status == _CONFIRMED || res.status == _IN_USE) && res.end >= block.timestamp
                    && res.start < earliestStart
            ) {
                earliestKey = key;
                earliestStart = res.start;
            }
            unchecked {
                ++i;
            }
        }
        return earliestKey;
    }

    function _invalidateInstitutionalActiveReservation(
        AppStorage storage s,
        uint256 labId,
        Reservation storage reservation,
        bytes32 reservationKey
    ) private {
        bytes32 storedHash = s.reservationPucHash[reservationKey];
        if (storedHash == bytes32(0)) {
            return;
        }
        address trackingKey = LibTracking.trackingKeyFromInstitutionHash(reservation.renter, storedHash);
        _invalidateActiveReservationEntry(s, labId, trackingKey, reservationKey);
        if (s.activeReservationHeapContains[reservationKey]) {
            s.activeReservationHeapContains[reservationKey] = false;
        }
    }

    function _invalidateActiveReservationEntry(
        AppStorage storage s,
        uint256 labId,
        address trackingKey,
        bytes32 reservationKey
    ) private {
        if (trackingKey == address(0)) {
            return;
        }
        if (!s.activeReservationHeapContains[reservationKey]) {
            return;
        }
        s.activeReservationHeapContains[reservationKey] = false;
        UserActiveReservation[] storage heap = s.activeReservationHeaps[labId][trackingKey];
        if (heap.length > 0 && heap[0].key == reservationKey) {
            _removeActiveReservationRoot(heap);
        }
    }

    function _removeActiveReservationRoot(
        UserActiveReservation[] storage heap
    ) private {
        uint256 lastIndex = heap.length - 1;
        if (lastIndex == 0) {
            heap.pop();
            return;
        }
        heap[0] = heap[lastIndex];
        heap.pop();
        _activeHeapifyDown(heap, 0);
    }

    function _activeHeapifyDown(
        UserActiveReservation[] storage heap,
        uint256 index
    ) private {
        uint256 length = heap.length;
        while (true) {
            uint256 left = index * 2 + 1;
            if (left >= length) {
                break;
            }
            uint256 right = left + 1;
            uint256 smallest = left;
            if (right < length && heap[right].start < heap[left].start) {
                smallest = right;
            }
            if (heap[index].start <= heap[smallest].start) {
                break;
            }
            UserActiveReservation memory temp = heap[index];
            heap[index] = heap[smallest];
            heap[smallest] = temp;
            index = smallest;
        }
    }

    function _isActiveReservationStatus(
        uint8 status
    ) private pure returns (bool) {
        return status == _CONFIRMED || status == _IN_USE || status == _COMPLETED;
    }

    function _decrementActiveReservationCounters(
        AppStorage storage s,
        Reservation storage reservation
    ) private {
        if (s.labActiveReservationCount[reservation.labId] > 0) {
            s.labActiveReservationCount[reservation.labId]--;
        }
        if (s.providerActiveReservationCount[reservation.labProvider] > 0) {
            s.providerActiveReservationCount[reservation.labProvider]--;
        }
    }

    function _removeReservationFromCalendar(
        AppStorage storage s,
        uint256 labId,
        uint32 start
    ) private {
        Tree storage calendar = s.calendars[labId];
        if (calendar.root == 0) {
            return;
        }
        if (calendar.exists(start)) {
            calendar.remove(start);
        }
    }
}
