// SPDX-License-Identifier: GPL-3.0-or-later
pragma solidity ^0.8.31;

import {IERC721} from "@openzeppelin/contracts/token/ERC721/IERC721.sol";
import {EnumerableSet} from "@openzeppelin/contracts/utils/structs/EnumerableSet.sol";
import {ReentrancyGuardTransient} from "@openzeppelin/contracts/utils/ReentrancyGuardTransient.sol";
import {AppStorage, Reservation, PayoutCandidate, LibAppStorage} from "../../libraries/LibAppStorage.sol";
import {LibAccessControlEnumerable} from "../../libraries/LibAccessControlEnumerable.sol";
import {ActionIntentPayload} from "../../libraries/IntentTypes.sol";
import {LibIntent} from "../../libraries/LibIntent.sol";
import {LibLabAdmin} from "../../libraries/LibLabAdmin.sol";
import {LibReputation} from "../../libraries/LibReputation.sol";
import {LibProviderReceivable, SETTLEMENT_OPERATOR_ROLE} from "../../libraries/LibProviderReceivable.sol";

/// @title ProviderSettlementFacet
/// @author
/// - Luis de la Torre Cubillo
/// - Juan Luis Ramos Villalón
/// @dev Facet contract to manage provider receivable accrual and settlement requests.
/// Reservation completion accrues provider debt onchain; settlement remains a separate workflow.

contract ProviderSettlementFacet is ReentrancyGuardTransient {
    using EnumerableSet for EnumerableSet.Bytes32Set;
    using EnumerableSet for EnumerableSet.AddressSet;
    using LibAccessControlEnumerable for AppStorage;

    /// @dev Reservation status constants (must match reservation facets)
    uint8 internal constant _PENDING = 0;
    uint8 internal constant _CONFIRMED = 1;
    uint8 internal constant _IN_USE = 2;
    uint8 internal constant _COMPLETED = 3;
    uint8 internal constant _SETTLED = 4;
    uint8 internal constant _CANCELLED = 5;

    /// @dev Provider receivable lifecycle buckets
    uint8 internal constant _RECEIVABLE_ACCRUED = 1;
    uint8 internal constant _RECEIVABLE_QUEUED = 2;
    uint8 internal constant _RECEIVABLE_INVOICED = 3;
    uint8 internal constant _RECEIVABLE_APPROVED = 4;
    uint8 internal constant _RECEIVABLE_PAID = 5;
    uint8 internal constant _RECEIVABLE_REVERSED = 6;
    uint8 internal constant _RECEIVABLE_DISPUTED = 7;

    /// @notice Event emitted when a lab intent is processed
    event LabIntentProcessed(
        bytes32 indexed requestId, uint256 labId, string action, address provider, bool success, string reason
    );

    /// @notice Emitted when a provider payout request queues newly accrued provider receivable for settlement
    event ProviderPayoutRequested(
        address indexed provider, uint256 indexed labId, uint256 amount, uint256 reservationsProcessed
    );

    /// @notice Emitted when provider receivable moves between lifecycle buckets
    event ProviderReceivableLifecycleTransition(
        address indexed operator,
        uint256 indexed labId,
        uint8 indexed fromState,
        uint8 toState,
        uint256 amount,
        bytes32 referenceHash
    );

    /// @dev Returns the AppStorage struct from the diamond storage slot.
    function _s() internal pure returns (AppStorage storage s) {
        s = LibAppStorage.diamondStorage();
    }

    /// @dev Modifier to restrict access to functions that can only be executed by the LabProvider.
    modifier isLabProvider() {
        _isLabProvider();
        _;
    }

    function _isLabProvider() internal view {
        require(_s()._isLabProvider(msg.sender), "Only one LabProvider can perform this action");
    }

    /// @dev Modifier to restrict access to functions that can only be executed by the DEFAULT_ADMIN_ROLE.
    modifier onlyDefaultAdminRole() {
        _onlyDefaultAdminRole();
        _;
    }

    function _onlyDefaultAdminRole() internal view {
        AppStorage storage s = _s();
        require(s.roleMembers[s.DEFAULT_ADMIN_ROLE].contains(msg.sender), "Only admin");
    }

    /// @notice Requests settlement of the currently accrued provider receivable for a lab
    function requestProviderPayout(
        uint256 _labId,
        uint256 maxBatch
    ) external isLabProvider nonReentrant {
        _requestProviderPayout(_labId, maxBatch);
    }

    /// @notice Requests provider payout via intent while using provider-payout terminology externally
    function requestProviderPayoutWithIntent(
        bytes32 requestId,
        ActionIntentPayload calldata payload
    ) external isLabProvider nonReentrant {
        require(payload.labId != 0, "REQUEST_PAYOUT: labId required");
        require(payload.executor == msg.sender, "Executor must be caller");
        LibLabAdmin._requireLabCreator(payload.labId, payload.puc);
        uint256 maxBatch = uint256(payload.maxBatch);
        if (maxBatch == 0 || maxBatch > 100) revert("Invalid batch size");

        bytes32 payloadHash = LibIntent.hashActionPayload(payload);
        LibIntent.consumeIntent(requestId, LibIntent.ACTION_REQUEST_PROVIDER_PAYOUT, payloadHash, msg.sender);

        _requestProviderPayout(payload.labId, maxBatch);
        emit LabIntentProcessed(requestId, payload.labId, "REQUEST_PROVIDER_PAYOUT", msg.sender, true, "");
    }

    /// @notice Returns the provider receivable currently accrued or immediately settleable for a lab
    function getLabProviderReceivable(
        uint256 _labId
    )
        external
        view
        returns (
            uint256 providerReceivable,
            uint256 deferredInstitutionalReceivable,
            uint256 totalReceivable,
            uint256 eligibleReservationCount
        )
    {
        AppStorage storage s = _s();

        providerReceivable = _outstandingProviderReceivable(s, _labId);
        deferredInstitutionalReceivable = 0;
        eligibleReservationCount = 0;

        uint256 currentTime = block.timestamp;
        PayoutCandidate[] storage heap = s.payoutHeaps[_labId];
        uint256 heapLength = heap.length;

        if (heapLength > 0) {
            (uint256 pendingProviderReceivable, uint256 pendingClosures) =
                _accumulateEligiblePayoutFromHeap(s, heap, heapLength, 0, currentTime, _labId);
            providerReceivable += pendingProviderReceivable;
            eligibleReservationCount = pendingClosures;
        }

        totalReceivable = providerReceivable + deferredInstitutionalReceivable;
    }

    /// @notice Bounded/paginated variant of getLabProviderReceivable to avoid large eth_call executions.
    /// @dev Scans payout heap entries in [offset, offset+limit). To aggregate full pending values,
    ///      callers should iterate until hasMore=false, summing chunk outputs.
    ///      The already-accrued + already-requested provider receivable buckets are included only when offset == 0.
    ///      NOTE: this function intentionally uses linear index scanning (instead of heap branch pruning)
    ///      so offset pagination remains deterministic and easy to compose off-chain.
    /// @param _labId The lab to query
    /// @param offset Heap index offset to start scanning from
    /// @param limit Max heap entries to scan in this call (1-1000)
    /// @return providerReceivableChunk Provider receivable found in this chunk (+fixed onchain buckets if offset==0)
    /// @return deferredInstitutionalReceivableChunk Reserved for compatibility (currently always 0)
    /// @return totalReceivableChunk Sum of provider and institutional chunk outputs
    /// @return eligibleReservationCountChunk Number of closeable reservations found in this chunk
    /// @return nextOffset Offset to use in next page call
    /// @return hasMore True when more heap entries remain after this chunk
    function getLabProviderReceivablePaginated(
        uint256 _labId,
        uint256 offset,
        uint256 limit
    )
        external
        view
        returns (
            uint256 providerReceivableChunk,
            uint256 deferredInstitutionalReceivableChunk,
            uint256 totalReceivableChunk,
            uint256 eligibleReservationCountChunk,
            uint256 nextOffset,
            bool hasMore
        )
    {
        require(limit > 0 && limit <= 1000, "Invalid limit");

        AppStorage storage s = _s();
        deferredInstitutionalReceivableChunk = 0;

        if (offset == 0) {
            providerReceivableChunk = _outstandingProviderReceivable(s, _labId);
        }

        PayoutCandidate[] storage heap = s.payoutHeaps[_labId];
        uint256 heapLength = heap.length;
        if (offset >= heapLength) {
            nextOffset = heapLength;
            totalReceivableChunk = providerReceivableChunk;
            return (
                providerReceivableChunk,
                deferredInstitutionalReceivableChunk,
                totalReceivableChunk,
                eligibleReservationCountChunk,
                nextOffset,
                false
            );
        }

        uint256 end = offset + limit;
        if (end > heapLength) {
            end = heapLength;
        }

        uint256 currentTime = block.timestamp;
        for (uint256 i = offset; i < end;) {
            PayoutCandidate storage candidate = heap[i];
            if (candidate.end <= currentTime) {
                Reservation storage reservation = s.reservations[candidate.key];
                if (
                    reservation.labId == _labId
                        && (reservation.status == _CONFIRMED
                            || reservation.status == _IN_USE
                            || reservation.status == _COMPLETED)
                ) {
                    providerReceivableChunk += reservation.providerShare;
                    eligibleReservationCountChunk++;
                }
            }
            unchecked {
                ++i;
            }
        }

        nextOffset = end;
        hasMore = end < heapLength;
        totalReceivableChunk = providerReceivableChunk + deferredInstitutionalReceivableChunk;
    }

    /// @notice Returns explicit provider receivable lifecycle buckets for a lab.
    function getLabProviderReceivableLifecycle(
        uint256 _labId
    )
        external
        view
        returns (
            uint256 accruedReceivable,
            uint256 settlementQueued,
            uint256 invoicedReceivable,
            uint256 approvedReceivable,
            uint256 paidReceivable,
            uint256 reversedReceivable,
            uint256 disputedReceivable,
            uint256 lastAccruedAt
        )
    {
        AppStorage storage s = _s();
        accruedReceivable = s.providerReceivableAccrued[_labId];
        settlementQueued = s.providerSettlementQueue[_labId];
        invoicedReceivable = s.providerReceivableInvoiced[_labId];
        approvedReceivable = s.providerReceivableApproved[_labId];
        paidReceivable = s.providerReceivablePaid[_labId];
        reversedReceivable = s.providerReceivableReversed[_labId];
        disputedReceivable = s.providerReceivableDisputed[_labId];
        lastAccruedAt = s.providerReceivableLastAccruedAt[_labId];
    }

    /// @notice Moves provider receivable amount between explicit lifecycle buckets.
    /// @dev Writable only by the lab owner, its configured backend, or protocol admin.
    function transitionProviderReceivableState(
        uint256 _labId,
        uint8 fromState,
        uint8 toState,
        uint256 amount,
        bytes32 referenceHash
    ) external nonReentrant {
        require(amount > 0, "Amount required");

        AppStorage storage s = _s();
        _requireSettlementOperator(s, _labId);
        require(_isSupportedReceivableState(fromState) && _isSupportedReceivableState(toState), "Invalid state");
        require(_isValidReceivableTransition(fromState, toState), "Invalid transition");

        _decreaseReceivableBucket(s, _labId, fromState, amount);
        _increaseReceivableBucket(s, _labId, toState, amount);

        emit ProviderReceivableLifecycleTransition(msg.sender, _labId, fromState, toState, amount, referenceHash);
    }

    /// @dev Traverses payout heap with pruning:
    ///      if node.end > currentTime, all descendants are also ineligible.
    function _accumulateEligiblePayoutFromHeap(
        AppStorage storage s,
        PayoutCandidate[] storage heap,
        uint256 heapLength,
        uint256 nodeIndex,
        uint256 currentTime,
        uint256 labId
    ) internal view returns (uint256 providerPayout, uint256 pendingClosures) {
        if (nodeIndex >= heapLength) {
            return (0, 0);
        }

        PayoutCandidate storage candidate = heap[nodeIndex];
        if (candidate.end > currentTime) {
            return (0, 0);
        }

        Reservation storage reservation = s.reservations[candidate.key];
        if (
            reservation.labId == labId
                && (reservation.status == _CONFIRMED
                    || reservation.status == _IN_USE
                    || reservation.status == _COMPLETED)
        ) {
            providerPayout = reservation.providerShare;
            pendingClosures = 1;
        }

        uint256 left = nodeIndex * 2 + 1;
        if (left < heapLength) {
            (uint256 leftPayout, uint256 leftClosures) =
                _accumulateEligiblePayoutFromHeap(s, heap, heapLength, left, currentTime, labId);
            providerPayout += leftPayout;
            pendingClosures += leftClosures;
        }

        uint256 right = left + 1;
        if (right < heapLength) {
            (uint256 rightPayout, uint256 rightClosures) =
                _accumulateEligiblePayoutFromHeap(s, heap, heapLength, right, currentTime, labId);
            providerPayout += rightPayout;
            pendingClosures += rightClosures;
        }
    }

    // -------------------------------------------------------------------------
    // Internal helpers
    // -------------------------------------------------------------------------

    /// @dev Max heap entries to compact in a single call
    uint256 internal constant _MAX_COMPACTION_SIZE = 200;

    function _requestProviderPayout(
        uint256 _labId,
        uint256 maxBatch
    ) internal {
        if (maxBatch == 0 || maxBatch > 100) revert("Invalid batch size");

        AppStorage storage s = _s();

        address labOwner = IERC721(address(this)).ownerOf(_labId);
        address backend = s.institutionalBackends[labOwner];
        if (msg.sender != labOwner && msg.sender != backend) {
            revert("Not authorized");
        }

        uint256 processed;
        uint256 currentTime = block.timestamp;

        while (processed < maxBatch) {
            bytes32 key = _popEligiblePayoutCandidate(s, _labId, currentTime);
            if (key == bytes32(0)) {
                break;
            }
            Reservation storage reservation = s.reservations[key];
            if (_finalizeReservationForPayout(s, key, reservation, _labId)) {
                unchecked {
                    ++processed;
                }
            }
        }

        uint256 providerPayout = s.providerReceivableAccrued[_labId];
        if (providerPayout == 0 && processed == 0) revert("No completed reservations");

        if (providerPayout > 0) {
            _decreaseReceivableBucket(s, _labId, _RECEIVABLE_ACCRUED, providerPayout);
            _increaseReceivableBucket(s, _labId, _RECEIVABLE_QUEUED, providerPayout);
            emit ProviderReceivableLifecycleTransition(
                msg.sender, _labId, _RECEIVABLE_ACCRUED, _RECEIVABLE_QUEUED, providerPayout, bytes32(0)
            );
        }

        emit ProviderPayoutRequested(labOwner, _labId, providerPayout, processed);
    }

    function _requireSettlementOperator(
        AppStorage storage s,
        uint256 labId
    ) internal view {
        bool isAdmin = s.roleMembers[s.DEFAULT_ADMIN_ROLE].contains(msg.sender);
        if (isAdmin) return;

        bool isSettlementOp = s.roleMembers[SETTLEMENT_OPERATOR_ROLE].contains(msg.sender);
        if (isSettlementOp) return;

        address labOwner = IERC721(address(this)).ownerOf(labId);
        address backend = s.institutionalBackends[labOwner];
        if (msg.sender != labOwner && msg.sender != backend) {
            revert("Not authorized");
        }
    }

    function _outstandingProviderReceivable(
        AppStorage storage s,
        uint256 labId
    ) internal view returns (uint256) {
        return s.providerReceivableAccrued[labId] + s.providerSettlementQueue[labId] + s.providerReceivableInvoiced[labId]
            + s.providerReceivableApproved[labId] + s.providerReceivableDisputed[labId];
    }

    function _isSupportedReceivableState(
        uint8 state
    ) internal pure returns (bool) {
        return state >= _RECEIVABLE_ACCRUED && state <= _RECEIVABLE_DISPUTED;
    }

    function _isValidReceivableTransition(
        uint8 fromState,
        uint8 toState
    ) internal pure returns (bool) {
        if (fromState == toState || fromState == _RECEIVABLE_PAID || fromState == _RECEIVABLE_REVERSED) {
            return false;
        }

        if (fromState == _RECEIVABLE_ACCRUED) {
            return toState == _RECEIVABLE_QUEUED || toState == _RECEIVABLE_DISPUTED || toState == _RECEIVABLE_REVERSED;
        }
        if (fromState == _RECEIVABLE_QUEUED) {
            return toState == _RECEIVABLE_INVOICED || toState == _RECEIVABLE_APPROVED || toState == _RECEIVABLE_DISPUTED
                || toState == _RECEIVABLE_REVERSED;
        }
        if (fromState == _RECEIVABLE_INVOICED) {
            return toState == _RECEIVABLE_APPROVED || toState == _RECEIVABLE_DISPUTED
                || toState == _RECEIVABLE_REVERSED;
        }
        if (fromState == _RECEIVABLE_APPROVED) {
            return toState == _RECEIVABLE_PAID || toState == _RECEIVABLE_DISPUTED || toState == _RECEIVABLE_REVERSED;
        }
        if (fromState == _RECEIVABLE_DISPUTED) {
            return toState == _RECEIVABLE_INVOICED || toState == _RECEIVABLE_APPROVED
                || toState == _RECEIVABLE_REVERSED;
        }

        return false;
    }

    function _bucketAmount(
        AppStorage storage s,
        uint256 labId,
        uint8 state
    ) internal view returns (uint256) {
        if (state == _RECEIVABLE_ACCRUED) return s.providerReceivableAccrued[labId];
        if (state == _RECEIVABLE_QUEUED) return s.providerSettlementQueue[labId];
        if (state == _RECEIVABLE_INVOICED) return s.providerReceivableInvoiced[labId];
        if (state == _RECEIVABLE_APPROVED) return s.providerReceivableApproved[labId];
        if (state == _RECEIVABLE_PAID) return s.providerReceivablePaid[labId];
        if (state == _RECEIVABLE_REVERSED) return s.providerReceivableReversed[labId];
        if (state == _RECEIVABLE_DISPUTED) return s.providerReceivableDisputed[labId];
        revert("Invalid state");
    }

    function _decreaseReceivableBucket(
        AppStorage storage s,
        uint256 labId,
        uint8 state,
        uint256 amount
    ) internal {
        uint256 current = _bucketAmount(s, labId, state);
        require(current >= amount, "Insufficient bucket balance");

        if (state == _RECEIVABLE_ACCRUED) {
            s.providerReceivableAccrued[labId] = current - amount;
            return;
        }
        if (state == _RECEIVABLE_QUEUED) {
            s.providerSettlementQueue[labId] = current - amount;
            return;
        }
        if (state == _RECEIVABLE_INVOICED) {
            s.providerReceivableInvoiced[labId] = current - amount;
            return;
        }
        if (state == _RECEIVABLE_APPROVED) {
            s.providerReceivableApproved[labId] = current - amount;
            return;
        }
        if (state == _RECEIVABLE_PAID) {
            s.providerReceivablePaid[labId] = current - amount;
            return;
        }
        if (state == _RECEIVABLE_REVERSED) {
            s.providerReceivableReversed[labId] = current - amount;
            return;
        }

        s.providerReceivableDisputed[labId] = current - amount;
    }

    function _increaseReceivableBucket(
        AppStorage storage s,
        uint256 labId,
        uint8 state,
        uint256 amount
    ) internal {
        if (state == _RECEIVABLE_ACCRUED) {
            s.providerReceivableAccrued[labId] += amount;
            return;
        }
        if (state == _RECEIVABLE_QUEUED) {
            s.providerSettlementQueue[labId] += amount;
            return;
        }
        if (state == _RECEIVABLE_INVOICED) {
            s.providerReceivableInvoiced[labId] += amount;
            return;
        }
        if (state == _RECEIVABLE_APPROVED) {
            s.providerReceivableApproved[labId] += amount;
            return;
        }
        if (state == _RECEIVABLE_PAID) {
            s.providerReceivablePaid[labId] += amount;
            return;
        }
        if (state == _RECEIVABLE_REVERSED) {
            s.providerReceivableReversed[labId] += amount;
            return;
        }
        if (state == _RECEIVABLE_DISPUTED) {
            s.providerReceivableDisputed[labId] += amount;
            return;
        }

        revert("Invalid state");
    }

    /// @dev Pops the first eligible reservation from the heap if its end <= cutoff
    function _popEligiblePayoutCandidate(
        AppStorage storage s,
        uint256 labId,
        uint256 currentTime
    ) internal returns (bytes32) {
        PayoutCandidate[] storage heap = s.payoutHeaps[labId];

        // Lazy cleanup optimization: if >20% of heap is invalid entries, rebuild heap
        uint256 heapSize = heap.length;
        uint256 invalidCount = s.payoutHeapInvalidCount[labId];
        if (heapSize > 0 && invalidCount > heapSize / 5) {
            _compactHeap(s, labId);
            heapSize = heap.length;
        }

        while (heapSize > 0) {
            PayoutCandidate memory root = heap[0];
            if (root.end > currentTime) {
                return bytes32(0);
            }
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

    function _removeHeapRoot(
        PayoutCandidate[] storage heap
    ) internal {
        uint256 lastIndex = heap.length - 1;
        if (lastIndex == 0) {
            heap.pop();
            return;
        }
        heap[0] = heap[lastIndex];
        heap.pop();
        _heapifyDown(heap, 0);
    }

    function _heapifyDown(
        PayoutCandidate[] storage heap,
        uint256 index
    ) internal {
        uint256 length = heap.length;
        while (true) {
            uint256 left = index * 2 + 1;
            if (left >= length) {
                break;
            }
            uint256 right = left + 1;
            uint256 smallest = left;
            if (right < length && heap[right].end < heap[left].end) {
                smallest = right;
            }
            if (heap[index].end <= heap[smallest].end) {
                break;
            }
            PayoutCandidate memory temp = heap[index];
            heap[index] = heap[smallest];
            heap[smallest] = temp;
            index = smallest;
        }
    }

    function _heapifyUp(
        PayoutCandidate[] storage heap,
        uint256 index
    ) internal {
        while (index > 0) {
            uint256 parent = (index - 1) / 2;
            if (heap[index].end >= heap[parent].end) {
                break;
            }
            PayoutCandidate memory temp = heap[index];
            heap[index] = heap[parent];
            heap[parent] = temp;
            index = parent;
        }
    }

    function _removeHeapAt(
        PayoutCandidate[] storage heap,
        uint256 index
    ) internal {
        uint256 lastIndex = heap.length - 1;
        if (index == lastIndex) {
            heap.pop();
            return;
        }

        heap[index] = heap[lastIndex];
        heap.pop();
        _heapifyDown(heap, index);
        if (index < heap.length) {
            _heapifyUp(heap, index);
        }
    }

    /// @dev Compacts the heap by removing all invalid entries in one pass.
    ///      This is O(n) for the compaction + heap rebuild and is triggered lazily
    ///      when invalid density is high, with a size guard (_MAX_COMPACTION_SIZE).
    function _compactHeap(
        AppStorage storage s,
        uint256 labId
    ) internal {
        PayoutCandidate[] storage heap = s.payoutHeaps[labId];
        uint256 originalLength = heap.length;
        if (originalLength > _MAX_COMPACTION_SIZE) {
            return;
        }
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

        while (heap.length > writeIndex) {
            heap.pop();
        }

        if (writeIndex > 1) {
            for (uint256 i = (writeIndex - 1) / 2 + 1; i > 0; i--) {
                _heapifyDown(heap, i - 1);
            }
        }

        s.payoutHeapInvalidCount[labId] = 0;
    }

    /// @dev Finalizes a reservation for settlement processing: marks as _SETTLED, updates counters, accrues shares
    function _finalizeReservationForPayout(
        AppStorage storage s,
        bytes32 key,
        Reservation storage reservation,
        uint256 labId
    ) internal returns (bool) {
        // Skip if wrong lab or already finalized
        if (reservation.labId != labId) return false;
        if (reservation.status != _CONFIRMED && reservation.status != _IN_USE && reservation.status != _COMPLETED) {
            return false;
        }

        // Mark as settled
        uint8 previousStatus = reservation.status;
        reservation.status = _SETTLED;
        if (previousStatus == _IN_USE) {
            LibReputation.recordCompletion(labId);
        }

        // Decrement active reservation counter
        if (s.labActiveReservationCount[labId] > 0) {
            s.labActiveReservationCount[labId]--;
        }

        address labProvider = reservation.labProvider;
        if (s.providerActiveReservationCount[labProvider] > 0) {
            s.providerActiveReservationCount[labProvider]--;
        }

        // Accrue shares to canonical on-chain provider debt buckets.
        LibProviderReceivable.accrueReceivable(labId, reservation.providerShare, key);
        LibProviderReceivable.updateAccruedTimestamp(labId, block.timestamp);

        return true;
    }
}
