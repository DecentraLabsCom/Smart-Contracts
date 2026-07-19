// SPDX-License-Identifier: GPL-3.0-or-later
pragma solidity ^0.8.33;

import {AppStorage, Reservation, PayoutCandidate} from "./LibAppStorage.sol";
import {LibReservationConfig} from "./LibReservationConfig.sol";

/// @title LibHeap - Payout candidate heap operations
/// @dev Library to manage min-heap operations for reservation payout scheduling
library LibHeap {
    uint256 internal constant MAX_COMPACTION_SIZE = 500;

    // Reservation statuses (must match ReservableToken)
    uint8 internal constant _CONFIRMED = 1;
    uint8 internal constant _ACCESS_AUTHORIZED = 2;

    function enqueuePayoutCandidate(
        AppStorage storage s,
        uint256 labId,
        bytes32 key,
        uint32 end
    ) internal {
        PayoutCandidate[] storage heap = s.payoutHeaps[labId];
        if (s.payoutHeapContains[key]) return;
        heap.push(PayoutCandidate({end: end, key: key}));
        s.payoutHeapContains[key] = true;
        s.payoutHeapIndexPlusOne[key] = heap.length;
        _heapifyUp(s, heap, heap.length - 1);
    }

    /// @notice Removes a reservation candidate in O(log n).
    /// @dev Entries written before the index mapping was introduced are lazily
    ///      invalidated in O(1), then removed by normal heap processing.
    function removePayoutCandidates(
        AppStorage storage s,
        uint256 labId,
        bytes32 key
    ) internal {
        PayoutCandidate[] storage heap = s.payoutHeaps[labId];
        uint256 indexPlusOne = s.payoutHeapIndexPlusOne[key];

        if (indexPlusOne == 0) {
            if (s.payoutHeapContains[key]) {
                s.payoutHeapContains[key] = false;
                s.payoutHeapInvalidCount[labId]++;
            }
            return;
        }

        uint256 index = indexPlusOne - 1;
        if (index >= heap.length || heap[index].key != key) {
            s.payoutHeapIndexPlusOne[key] = 0;
            if (s.payoutHeapContains[key]) {
                s.payoutHeapContains[key] = false;
                s.payoutHeapInvalidCount[labId]++;
            }
            return;
        }

        _removeAt(s, heap, index);
    }

    function popEligiblePayoutCandidate(
        AppStorage storage s,
        uint256 labId,
        uint256 currentTime
    ) internal returns (bytes32) {
        PayoutCandidate[] storage heap = s.payoutHeaps[labId];
        uint256 heapSize = heap.length;
        uint256 invalidCount = s.payoutHeapInvalidCount[labId];
        if (heapSize > 0 && invalidCount > heapSize / 5) {
            _compactHeap(s, labId);
            heapSize = heap.length;
            invalidCount = s.payoutHeapInvalidCount[labId];
        }

        while (heapSize > 0) {
            PayoutCandidate memory root = heap[0];
            if (root.end > currentTime) return bytes32(0);

            Reservation storage reservation = s.reservations[root.key];
            bool isCurrent = reservation.labId == labId && (reservation.end == 0 || reservation.end == root.end);
            if (
                isCurrent && reservation.status == _ACCESS_AUTHORIZED && !s.reservationSessionStartedRecorded[root.key]
                    && LibReservationConfig.isWithinSessionAttestationGrace(reservation.end, currentTime)
            ) {
                return bytes32(0);
            }

            _removeHeapRoot(s, heap);
            if (isCurrent && (reservation.status == _CONFIRMED || reservation.status == _ACCESS_AUTHORIZED)) {
                return root.key;
            }

            if (invalidCount > 0) {
                s.payoutHeapInvalidCount[labId]--;
                invalidCount--;
            }
            heapSize--;
        }
        return bytes32(0);
    }

    function _heapifyUp(
        AppStorage storage s,
        PayoutCandidate[] storage heap,
        uint256 index
    ) private {
        while (index > 0) {
            uint256 parent = (index - 1) / 2;
            if (heap[index].end >= heap[parent].end) break;

            bytes32 childKey = heap[index].key;
            bytes32 parentKey = heap[parent].key;
            PayoutCandidate memory temp = heap[index];
            heap[index] = heap[parent];
            heap[parent] = temp;
            s.payoutHeapIndexPlusOne[childKey] = parent + 1;
            s.payoutHeapIndexPlusOne[parentKey] = index + 1;
            index = parent;
        }
    }

    function _removeHeapRoot(
        AppStorage storage s,
        PayoutCandidate[] storage heap
    ) private {
        uint256 lastIndex = heap.length - 1;
        bytes32 removedKey = heap[0].key;
        s.payoutHeapIndexPlusOne[removedKey] = 0;
        s.payoutHeapContains[removedKey] = false;

        if (lastIndex == 0) {
            heap.pop();
            return;
        }

        bytes32 movedKey = heap[lastIndex].key;
        heap[0] = heap[lastIndex];
        heap.pop();
        s.payoutHeapIndexPlusOne[movedKey] = 1;
        _heapifyDown(s, heap, 0);
    }

    function _heapifyDown(
        AppStorage storage s,
        PayoutCandidate[] storage heap,
        uint256 index
    ) private {
        uint256 length = heap.length;
        while (true) {
            uint256 left = index * 2 + 1;
            if (left >= length) break;
            uint256 right = left + 1;
            uint256 smallest = left;
            if (right < length && heap[right].end < heap[left].end) smallest = right;
            if (heap[index].end <= heap[smallest].end) break;

            bytes32 currentKey = heap[index].key;
            bytes32 smallestKey = heap[smallest].key;
            PayoutCandidate memory temp = heap[index];
            heap[index] = heap[smallest];
            heap[smallest] = temp;
            s.payoutHeapIndexPlusOne[currentKey] = smallest + 1;
            s.payoutHeapIndexPlusOne[smallestKey] = index + 1;
            index = smallest;
        }
    }

    function _removeAt(
        AppStorage storage s,
        PayoutCandidate[] storage heap,
        uint256 index
    ) private {
        uint256 lastIndex = heap.length - 1;
        bytes32 removedKey = heap[index].key;
        s.payoutHeapIndexPlusOne[removedKey] = 0;
        s.payoutHeapContains[removedKey] = false;

        if (index == lastIndex) {
            heap.pop();
            return;
        }

        PayoutCandidate memory moved = heap[lastIndex];
        heap[index] = moved;
        heap.pop();
        s.payoutHeapIndexPlusOne[moved.key] = index + 1;

        if (index > 0 && heap[index].end < heap[(index - 1) / 2].end) {
            _heapifyUp(s, heap, index);
        } else {
            _heapifyDown(s, heap, index);
        }
    }

    function _compactHeap(
        AppStorage storage s,
        uint256 labId
    ) private {
        PayoutCandidate[] storage heap = s.payoutHeaps[labId];
        uint256 originalLength = heap.length;
        if (originalLength > MAX_COMPACTION_SIZE) return;

        uint256 writeIndex;
        for (uint256 readIndex; readIndex < originalLength; readIndex++) {
            bytes32 key = heap[readIndex].key;
            Reservation storage reservation = s.reservations[key];

            if (_isCurrentPayoutCandidate(reservation, heap[readIndex], labId)) {
                if (writeIndex != readIndex) heap[writeIndex] = heap[readIndex];
                s.payoutHeapContains[key] = true;
                s.payoutHeapIndexPlusOne[key] = writeIndex + 1;
                writeIndex++;
            } else {
                s.payoutHeapContains[key] = false;
                s.payoutHeapIndexPlusOne[key] = 0;
            }
        }

        while (heap.length > writeIndex) heap.pop();

        if (writeIndex > 1) {
            for (uint256 i = (writeIndex - 1) / 2 + 1; i > 0; i--) {
                _heapifyDown(s, heap, i - 1);
            }
        }
        s.payoutHeapInvalidCount[labId] = 0;
    }

    function _isCurrentPayoutCandidate(
        Reservation storage reservation,
        PayoutCandidate storage candidate,
        uint256 labId
    ) private view returns (bool) {
        return reservation.labId == labId && (reservation.end == 0 || reservation.end == candidate.end)
            && (reservation.status == _CONFIRMED || reservation.status == _ACCESS_AUTHORIZED);
    }
}
