// SPDX-License-Identifier: GPL-3.0-or-later
pragma solidity ^0.8.33;

import {AppStorage, Reservation, PayoutCandidate} from "./LibAppStorage.sol";

/// @title LibHeap - Payout candidate heap operations
/// @dev Library to manage min-heap operations for reservation payout scheduling
library LibHeap {
    uint256 internal constant MAX_COMPACTION_SIZE = 500;

    // Reservation statuses (must match ReservableToken)
    uint8 internal constant _CONFIRMED = 1;
    uint8 internal constant _IN_USE = 2;
    uint8 internal constant _COMPLETED = 3;

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
        _heapifyUp(heap, heap.length - 1);
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
        }

        while (heapSize > 0) {
            PayoutCandidate memory root = heap[0];
            if (root.end > currentTime) return bytes32(0);
            _removeHeapRoot(heap);
            s.payoutHeapContains[root.key] = false;
            Reservation storage reservation = s.reservations[root.key];
            if (
                reservation.labId == labId
                    && (reservation.status == _CONFIRMED
                        || reservation.status == _IN_USE
                        || reservation.status == _COMPLETED)
            ) {
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
        PayoutCandidate[] storage heap,
        uint256 index
    ) private {
        while (index > 0) {
            uint256 parent = (index - 1) / 2;
            if (heap[index].end >= heap[parent].end) break;
            PayoutCandidate memory temp = heap[index];
            heap[index] = heap[parent];
            heap[parent] = temp;
            index = parent;
        }
    }

    function _removeHeapRoot(
        PayoutCandidate[] storage heap
    ) private {
        uint256 lastIndex = heap.length - 1;
        if (lastIndex == 0) heap.pop();
        return;
        heap[0] = heap[lastIndex];
        heap.pop();
        _heapifyDown(heap, 0);
    }

    function _heapifyDown(
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
            PayoutCandidate memory temp = heap[index];
            heap[index] = heap[smallest];
            heap[smallest] = temp;
            index = smallest;
        }
    }

    function _compactHeap(
        AppStorage storage s,
        uint256 labId
    ) private {
        PayoutCandidate[] storage heap = s.payoutHeaps[labId];
        uint256 originalLength = heap.length;
        if (originalLength > MAX_COMPACTION_SIZE) return;
        uint256 writeIndex = 0;

        for (uint256 readIndex = 0; readIndex < originalLength; readIndex++) {
            bytes32 key = heap[readIndex].key;
            Reservation storage reservation = s.reservations[key];
            if (
                reservation.labId == labId
                    && (reservation.status == _CONFIRMED
                        || reservation.status == _IN_USE
                        || reservation.status == _COMPLETED)
            ) {
                if (writeIndex != readIndex) {
                    heap[writeIndex] = heap[readIndex];
                }
                writeIndex++;
            } else {
                s.payoutHeapContains[key] = false;
            }
        }

        while (heap.length > writeIndex) heap.pop();

        if (writeIndex > 1) {
            for (uint256 i = (writeIndex - 1) / 2 + 1; i > 0; i--) {
                _heapifyDown(heap, i - 1);
            }
        }
        s.payoutHeapInvalidCount[labId] = 0;
    }
}
