// SPDX-License-Identifier: GPL-3.0-or-later
pragma solidity ^0.8.31;

import {EnumerableSet} from "@openzeppelin/contracts/utils/structs/EnumerableSet.sol";
import {ReentrancyGuardTransient} from "@openzeppelin/contracts/utils/ReentrancyGuardTransient.sol";
import {
    AppStorage,
    Reservation,
    PayoutCandidate,
    ProviderSettlementClaim,
    LibAppStorage
} from "../../libraries/LibAppStorage.sol";
import {LibAccessControlEnumerable} from "../../libraries/LibAccessControlEnumerable.sol";
import {LibERC721Storage} from "../../libraries/LibERC721Storage.sol";
import {LibReputation} from "../../libraries/LibReputation.sol";
import {LibProviderReceivable, SETTLEMENT_OPERATOR_ROLE} from "../../libraries/LibProviderReceivable.sol";
import {LibReservationConfig} from "../../libraries/LibReservationConfig.sol";
import {LibReservationIndexCleanup} from "../../libraries/LibReservationIndexCleanup.sol";

/// @title ProviderSettlementFacet
/// @author
/// - Luis de la Torre Cubillo
/// - Juan Luis Ramos Villalón
/// @dev Facet contract to manage provider receivable accrual and settlement requests.
/// Reservation completion accrues provider debt onchain; settlement remains a separate workflow.

contract ProviderSettlementFacet is ReentrancyGuardTransient {
    using EnumerableSet for EnumerableSet.AddressSet;
    using LibAccessControlEnumerable for AppStorage;

    /// @dev Reservation status constants (must match reservation facets)
    uint8 internal constant _CONFIRMED = 1;
    uint8 internal constant _ACCESS_AUTHORIZED = 2;
    uint8 internal constant _SETTLED = 3;

    /// @dev Provider receivable lifecycle buckets
    uint8 internal constant _RECEIVABLE_ACCRUED = 1;
    uint8 internal constant _RECEIVABLE_QUEUED = 2;
    uint8 internal constant _RECEIVABLE_INVOICED = 3;
    uint8 internal constant _RECEIVABLE_APPROVED = 4;
    uint8 internal constant _RECEIVABLE_PAID = 5;
    uint8 internal constant _RECEIVABLE_REVERSED = 6;
    uint8 internal constant _RECEIVABLE_DISPUTED = 7;

    uint8 internal constant _CLAIM_SUBMITTED = 1;
    uint8 internal constant _CLAIM_APPROVED = 2;
    uint8 internal constant _CLAIM_PAID = 3;

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

    event ProviderSettlementClaimSubmitted(
        bytes32 indexed claimId,
        uint256 indexed labId,
        uint256 amount,
        bytes32 reservationsHash,
        bytes32 invoiceReferenceHash,
        address indexed actor
    );

    event ProviderSettlementClaimApproved(
        bytes32 indexed claimId, bytes32 approvalReferenceHash, address indexed actor
    );

    event ProviderSettlementClaimPaid(
        bytes32 indexed claimId,
        bytes32 indexed paymentReferenceHash,
        bytes32 paymentAttestationHash,
        address indexed actor
    );

    /// @dev Returns the AppStorage struct from the diamond storage slot.
    function _s() internal pure returns (AppStorage storage s) {
        s = LibAppStorage.diamondStorage();
    }

    /// @notice Processes eligible reservations and queues receivable accrued by this batch for a lab
    function requestProviderPayout(
        uint256 _labId,
        uint256 maxBatch
    ) external nonReentrant {
        _requestProviderPayout(_labId, maxBatch);
    }

    /// @notice Returns the provider receivable currently accrued or immediately settleable for a lab
    function getLabProviderReceivable(
        uint256 _labId
    ) external view returns (uint256 providerReceivable, uint256 totalReceivable, uint256 eligibleReservationCount) {
        AppStorage storage s = _s();

        providerReceivable = _outstandingProviderReceivable(s, _labId);
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

        totalReceivable = providerReceivable;
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
    /// @return totalReceivableChunk Sum of provider receivable outputs
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
            uint256 totalReceivableChunk,
            uint256 eligibleReservationCountChunk,
            uint256 nextOffset,
            bool hasMore
        )
    {
        require(limit > 0 && limit <= 1000, "Invalid limit");

        AppStorage storage s = _s();
        if (offset == 0) {
            providerReceivableChunk = _outstandingProviderReceivable(s, _labId);
        }

        PayoutCandidate[] storage heap = s.payoutHeaps[_labId];
        uint256 heapLength = heap.length;
        if (offset >= heapLength) {
            nextOffset = heapLength;
            totalReceivableChunk = providerReceivableChunk;
            return (providerReceivableChunk, totalReceivableChunk, eligibleReservationCountChunk, nextOffset, false);
        }

        uint256 end = offset + limit;
        if (end > heapLength) {
            end = heapLength;
        }

        uint256 currentTime = block.timestamp;
        for (uint256 i = offset; i < end;) {
            PayoutCandidate storage candidate = heap[i];
            // Settlement eligibility is intentionally evaluated against chain time.
            // slither-disable-next-line timestamp
            if (candidate.end <= currentTime) {
                Reservation storage reservation = s.reservations[candidate.key];
                if (
                    (reservation.end == 0 || reservation.end == candidate.end)
                        && _isProviderSettleableSession(s, candidate.key, reservation, _labId)
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
        totalReceivableChunk = providerReceivableChunk;
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

    /// @notice Creates a claim for a bounded amount already queued for settlement.
    /// @dev The claim atomically moves the amount QUEUED -> INVOICED so a later
    ///      batch cannot silently absorb unrelated receivables.
    function submitProviderSettlementClaim(
        bytes32 claimId,
        uint256 labId,
        uint256 amount,
        bytes32 reservationsHash,
        bytes32 invoiceReferenceHash
    ) external nonReentrant {
        require(claimId != bytes32(0), "Claim ID required");
        require(amount > 0, "Amount required");
        require(reservationsHash != bytes32(0), "Reservations reference required");
        require(invoiceReferenceHash != bytes32(0), "Invoice reference required");

        AppStorage storage s = _s();
        require(s.providerSettlementClaims[claimId].submittedBy == address(0), "Claim already exists");
        _requireSettlementOperator(s, labId);
        require(s.providerSettlementQueue[labId] >= amount, "Insufficient queued receivable");

        ProviderSettlementClaim storage claim = s.providerSettlementClaims[claimId];
        claim.labId = labId;
        claim.amount = amount;
        claim.reservationsHash = reservationsHash;
        claim.invoiceReferenceHash = invoiceReferenceHash;
        claim.submittedBy = msg.sender;
        claim.submittedAt = uint64(block.timestamp);
        claim.status = _CLAIM_SUBMITTED;

        _decreaseReceivableBucket(s, labId, _RECEIVABLE_QUEUED, amount);
        _increaseReceivableBucket(s, labId, _RECEIVABLE_INVOICED, amount);
        emit ProviderReceivableLifecycleTransition(
            msg.sender, labId, _RECEIVABLE_QUEUED, _RECEIVABLE_INVOICED, amount, claimId
        );
        emit ProviderSettlementClaimSubmitted(
            claimId, labId, amount, reservationsHash, invoiceReferenceHash, msg.sender
        );
    }

    /// @notice Approves a submitted claim with a non-empty external approval reference hash.
    function approveProviderSettlementClaim(
        bytes32 claimId,
        bytes32 approvalReferenceHash
    ) external nonReentrant {
        require(approvalReferenceHash != bytes32(0), "Approval reference required");
        AppStorage storage s = _s();
        ProviderSettlementClaim storage claim = s.providerSettlementClaims[claimId];
        require(claim.status == _CLAIM_SUBMITTED, "Claim is not submitted");
        _requireSettlementOperatorForFinancialTransition(s);

        claim.approvedBy = msg.sender;
        claim.approvedAt = uint64(block.timestamp);
        claim.status = _CLAIM_APPROVED;
        _decreaseReceivableBucket(s, claim.labId, _RECEIVABLE_INVOICED, claim.amount);
        _increaseReceivableBucket(s, claim.labId, _RECEIVABLE_APPROVED, claim.amount);
        emit ProviderReceivableLifecycleTransition(
            msg.sender, claim.labId, _RECEIVABLE_INVOICED, _RECEIVABLE_APPROVED, claim.amount, claimId
        );
        emit ProviderSettlementClaimApproved(claimId, approvalReferenceHash, msg.sender);
    }

    /// @notice Records a paid claim only with a unique payment reference and proof hash.
    function recordProviderSettlementClaimPayment(
        bytes32 claimId,
        bytes32 paymentReferenceHash,
        bytes32 paymentAttestationHash
    ) external nonReentrant {
        require(paymentReferenceHash != bytes32(0), "Payment reference required");
        require(paymentAttestationHash != bytes32(0), "Payment attestation required");

        AppStorage storage s = _s();
        ProviderSettlementClaim storage claim = s.providerSettlementClaims[claimId];
        require(claim.status == _CLAIM_APPROVED, "Claim is not approved");
        require(!s.providerSettlementPaymentReferenceUsed[paymentReferenceHash], "Payment reference already used");
        _requireSettlementOperatorForFinancialTransition(s);

        s.providerSettlementPaymentReferenceUsed[paymentReferenceHash] = true;
        claim.paymentReferenceHash = paymentReferenceHash;
        claim.paymentAttestationHash = paymentAttestationHash;
        claim.paidBy = msg.sender;
        claim.paidAt = uint64(block.timestamp);
        claim.status = _CLAIM_PAID;
        _decreaseReceivableBucket(s, claim.labId, _RECEIVABLE_APPROVED, claim.amount);
        _increaseReceivableBucket(s, claim.labId, _RECEIVABLE_PAID, claim.amount);
        emit ProviderReceivableLifecycleTransition(
            msg.sender, claim.labId, _RECEIVABLE_APPROVED, _RECEIVABLE_PAID, claim.amount, claimId
        );
        emit ProviderSettlementClaimPaid(claimId, paymentReferenceHash, paymentAttestationHash, msg.sender);
    }

    /// @notice Returns the complete claim audit record.
    function getProviderSettlementClaim(
        bytes32 claimId
    )
        external
        view
        returns (
            uint256 labId,
            uint256 amount,
            uint8 status,
            bytes32 reservationsHash,
            bytes32 invoiceReferenceHash,
            bytes32 paymentReferenceHash,
            bytes32 paymentAttestationHash,
            address submittedBy,
            address approvedBy,
            address paidBy,
            uint64 submittedAt,
            uint64 approvedAt,
            uint64 paidAt
        )
    {
        ProviderSettlementClaim storage claim = _s().providerSettlementClaims[claimId];
        return (
            claim.labId,
            claim.amount,
            claim.status,
            claim.reservationsHash,
            claim.invoiceReferenceHash,
            claim.paymentReferenceHash,
            claim.paymentAttestationHash,
            claim.submittedBy,
            claim.approvedBy,
            claim.paidBy,
            claim.submittedAt,
            claim.approvedAt,
            claim.paidAt
        );
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
        require(referenceHash != bytes32(0), "Reference required");

        AppStorage storage s = _s();
        require(_isSupportedReceivableState(fromState) && _isSupportedReceivableState(toState), "Invalid state");
        require(_isValidReceivableTransition(fromState, toState), "Invalid transition");
        if (
            toState == _RECEIVABLE_APPROVED || toState == _RECEIVABLE_PAID || toState == _RECEIVABLE_REVERSED
                || toState == _RECEIVABLE_DISPUTED
        ) {
            _requireSettlementOperatorForFinancialTransition(s);
        } else {
            _requireSettlementOperator(s, _labId);
        }

        _decreaseReceivableBucket(s, _labId, fromState, amount);
        _increaseReceivableBucket(s, _labId, toState, amount);

        emit ProviderReceivableLifecycleTransition(msg.sender, _labId, fromState, toState, amount, referenceHash);
    }

    /// @dev Traverses payout heap with pruning under a strict invariant:
    ///      `heap` must be a strict min-heap ordered by `end` for all active nodes.
    ///      Under that invariant, if `node.end > currentTime`, all descendants are also ineligible.
    ///      Any heap rebuild, compaction, or update path must preserve this ordering assumption.
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
        // Settlement eligibility is intentionally evaluated against chain time.
        // slither-disable-next-line timestamp
        if (candidate.end > currentTime) {
            return (0, 0);
        }

        Reservation storage reservation = s.reservations[candidate.key];
        if (_isProviderSettleableSession(s, candidate.key, reservation, labId)) {
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

        address labOwner = LibERC721Storage.ownerOf(_labId);
        address backend = s.institutionalBackends[labOwner];
        if (msg.sender != labOwner && msg.sender != backend) {
            revert("Not authorized");
        }

        uint256 processed = 0;
        uint256 currentTime = block.timestamp;
        uint256 accruedBefore = s.providerReceivableAccrued[_labId];

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

        uint256 accruedAfter = s.providerReceivableAccrued[_labId];
        uint256 providerPayout = accruedAfter - accruedBefore;
        if (providerPayout == 0 && processed == 0) revert("No settleable reservations");

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

        address labOwner = LibERC721Storage.ownerOf(labId);
        address backend = s.institutionalBackends[labOwner];
        if (msg.sender != labOwner && msg.sender != backend) {
            revert("Not authorized");
        }
    }

    function _requireSettlementOperatorForFinancialTransition(
        AppStorage storage s
    ) internal view {
        bool isAdmin = s.roleMembers[s.DEFAULT_ADMIN_ROLE].contains(msg.sender);
        bool isSettlementOp = s.roleMembers[SETTLEMENT_OPERATOR_ROLE].contains(msg.sender);
        require(isAdmin || isSettlementOp, "Not authorized");
    }

    function _outstandingProviderReceivable(
        AppStorage storage s,
        uint256 labId
    ) internal view returns (uint256) {
        return s.providerReceivableAccrued[labId] + s.providerSettlementQueue[labId]
            + s.providerReceivableInvoiced[labId] + s.providerReceivableApproved[labId]
            + s.providerReceivableDisputed[labId];
    }

    function _isProviderSettleableSession(
        AppStorage storage s,
        bytes32 key,
        Reservation storage reservation,
        uint256 labId
    ) internal view returns (bool) {
        // Provider settlement requires AccessAuthorized (_ACCESS_AUTHORIZED) plus observed SessionStarted.
        bool sessionStartedRecorded = s.reservationSessionStartedRecorded[key];
        return reservation.labId == labId && reservation.status == _ACCESS_AUTHORIZED && sessionStartedRecorded;
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
            return toState == _RECEIVABLE_APPROVED || toState == _RECEIVABLE_DISPUTED || toState == _RECEIVABLE_REVERSED;
        }
        if (fromState == _RECEIVABLE_APPROVED) {
            return toState == _RECEIVABLE_PAID || toState == _RECEIVABLE_DISPUTED || toState == _RECEIVABLE_REVERSED;
        }
        if (fromState == _RECEIVABLE_DISPUTED) {
            return toState == _RECEIVABLE_INVOICED || toState == _RECEIVABLE_APPROVED || toState == _RECEIVABLE_REVERSED;
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
            invalidCount = s.payoutHeapInvalidCount[labId];
        }

        while (heapSize > 0) {
            PayoutCandidate memory root = heap[0];
            // Settlement eligibility is intentionally evaluated against chain time.
            // slither-disable-next-line timestamp
            if (root.end > currentTime) {
                return bytes32(0);
            }
            Reservation storage reservation = s.reservations[root.key];
            bool isCurrent = reservation.labId == labId && (reservation.end == 0 || reservation.end == root.end);
            if (
                isCurrent && reservation.status == _ACCESS_AUTHORIZED && !s.reservationSessionStartedRecorded[root.key]
                    && LibReservationConfig.isWithinSessionAttestationGrace(reservation.end, currentTime)
            ) {
                return bytes32(0);
            }

            _removeHeapRoot(s, heap);
            if (isCurrent && _isProviderSettleableSession(s, root.key, reservation, labId)) {
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
        AppStorage storage s,
        PayoutCandidate[] storage heap
    ) internal {
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

            if (_isCurrentPayoutCandidate(reservation, heap[readIndex], labId)) {
                if (writeIndex != readIndex) {
                    heap[writeIndex] = heap[readIndex];
                }
                s.payoutHeapContains[key] = true;
                s.payoutHeapIndexPlusOne[key] = writeIndex + 1;
                writeIndex++;
            } else {
                s.payoutHeapContains[key] = false;
                s.payoutHeapIndexPlusOne[key] = 0;
            }
        }

        while (heap.length > writeIndex) {
            heap.pop();
        }

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

    /// @dev Finalizes a reservation for settlement processing: marks as _SETTLED, updates counters, accrues shares
    function _finalizeReservationForPayout(
        AppStorage storage s,
        bytes32 key,
        Reservation storage reservation,
        uint256 labId
    ) internal returns (bool) {
        // Skip if wrong lab or already finalized
        if (!_isProviderSettleableSession(s, key, reservation, labId)) return false;

        // Mark as settled
        uint8 previousStatus = reservation.status;
        reservation.status = _SETTLED;
        if (previousStatus == _ACCESS_AUTHORIZED) {
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

        LibReservationIndexCleanup.removeFinalizedReservationIndexes(s, key, reservation);
        if (s.totalReservationsCount > 0) {
            s.totalReservationsCount--;
        }
        // `_popEligiblePayoutCandidate` already removed this exact heap root.
        // Do not scan the remaining heap for the same key: doing so once per
        // reservation would turn a batch settlement into O(n^2).

        // Accrue shares to canonical on-chain provider debt buckets.
        LibProviderReceivable.accrueReceivable(labId, reservation.providerShare, key);
        LibProviderReceivable.updateAccruedTimestamp(labId, block.timestamp);

        return true;
    }
}
