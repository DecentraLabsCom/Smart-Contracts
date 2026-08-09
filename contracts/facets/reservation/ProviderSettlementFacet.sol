// SPDX-License-Identifier: GPL-3.0-or-later
pragma solidity ^0.8.31;

import {EnumerableSet} from "@openzeppelin/contracts/utils/structs/EnumerableSet.sol";
import {ReentrancyGuardTransient} from "@openzeppelin/contracts/utils/ReentrancyGuardTransient.sol";
import {
    AppStorage,
    Reservation,
    PayoutCandidate,
    ProviderSettlementClaim,
    ProviderSettlementBatch,
    LibAppStorage
} from "../../libraries/LibAppStorage.sol";
import {LibAccessControlEnumerable} from "../../libraries/LibAccessControlEnumerable.sol";
import {LibERC721Storage} from "../../libraries/LibERC721Storage.sol";
import {
    LibProviderReceivable,
    SETTLEMENT_APPROVER_ROLE,
    SETTLEMENT_OPERATOR_ROLE,
    SETTLEMENT_PAYER_ROLE
} from "../../libraries/LibProviderReceivable.sol";
import {LibInstitutionalReservationSettlement} from "../../libraries/LibInstitutionalReservationSettlement.sol";
import {LibRevenue} from "../../libraries/LibRevenue.sol";
import {LibHeap} from "../../libraries/LibHeap.sol";
import {LibReservationIdentity} from "../../libraries/LibReservationIdentity.sol";

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
    uint8 internal constant _CLAIM_DISPUTED = 4;
    uint8 internal constant _CLAIM_REVERSED = 5;

    uint8 internal constant _BATCH_QUEUED = 1;
    uint8 internal constant _BATCH_CLAIMED = 2;
    uint8 internal constant _BATCH_DISPUTED = 3;
    uint8 internal constant _BATCH_REVERSED = 4;

    /// @dev Hard bound for the deprecated aggregate preview getter. Production
    ///      consumers must use getLabProviderReceivablePaginated instead.
    uint256 internal constant _LEGACY_RECEIVABLE_PREVIEW_MAX_HEAP = 1000;

    /// @notice Emitted when a provider payout request queues the lab's accrued provider receivable for settlement
    event ProviderPayoutRequested(
        address indexed provider, uint256 indexed labId, uint256 amount, uint256 reservationsProcessed
    );

    /// @notice Emitted when the accrued provider receivable becomes a canonical settlement batch.
    event ProviderSettlementBatchCreated(
        bytes32 indexed batchId, uint256 indexed labId, uint256 amount, bytes32 scopeRoot, address indexed actor
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
        bytes32 batchId,
        bytes32 invoiceReferenceHash,
        address indexed actor
    );

    /// @notice Repeats the immutable batch scope on every claim transition.
    /// @dev Kept separate from the legacy-shaped lifecycle events so indexers
    ///      can obtain the root without reconstructing the batch getter state.
    event ProviderSettlementScopeReferenced(
        bytes32 indexed batchId, uint256 indexed labId, uint256 amount, bytes32 scopeRoot, bytes32 indexed claimId
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

    event ProviderSettlementBatchInvalidated(
        bytes32 indexed batchId,
        uint256 indexed labId,
        uint256 amount,
        uint8 fromStatus,
        uint8 toStatus,
        bytes32 referenceHash,
        address indexed actor,
        uint64 timestamp
    );

    event ProviderSettlementClaimInvalidated(
        bytes32 indexed claimId,
        bytes32 indexed batchId,
        uint256 indexed labId,
        uint256 amount,
        uint8 fromStatus,
        uint8 toStatus,
        bytes32 referenceHash,
        address actor,
        uint64 timestamp
    );

    /// @dev Returns the AppStorage struct from the diamond storage slot.
    function _s() internal pure returns (AppStorage storage s) {
        s = LibAppStorage.diamondStorage();
    }

    /// @notice Finalizes economically expired reservations and queues all accrued receivable for a lab
    function requestProviderPayout(
        uint256 _labId,
        uint256 maxBatch
    ) external nonReentrant {
        _requestProviderPayout(_labId, maxBatch);
    }

    /// @notice Deprecated bounded preview of provider receivables affected by the next payout request.
    /// @dev Kept for compatibility with already deployed consumers. Production
    ///      consumers must use getLabProviderReceivablePaginated. This selector
    ///      reverts once the payout heap exceeds the legacy bound so an eth_call
    ///      cannot scale with an unbounded reservation history. The fourth value
    ///      includes all currently outstanding receivable lifecycle buckets.
    ///      Pending grace reservations are intentionally a count, not a receivable
    ///      amount, because they cannot be finalized by payout yet.
    function getLabProviderReceivable(
        uint256 _labId
    )
        external
        view
        returns (
            uint256 attestedSessionPayout,
            uint256 potentialNoShowFee,
            uint256 pendingGraceReservationCount,
            uint256 accruedReceivable
        )
    {
        AppStorage storage s = _s();

        accruedReceivable = _outstandingProviderReceivable(s, _labId);

        uint256 currentTime = block.timestamp;
        PayoutCandidate[] storage heap = s.payoutHeaps[_labId];
        uint256 heapLength = heap.length;

        if (heapLength > 0) {
            require(heapLength <= _LEGACY_RECEIVABLE_PREVIEW_MAX_HEAP, "Use paginated receivable getter");
            (uint256 pendingAttestedSessionPayout, uint256 pendingNoShowFee, uint256 pendingGraceReservations) =
                _accumulatePayoutPreviewFromHeap(s, heap, heapLength, 0, currentTime, _labId);
            attestedSessionPayout += pendingAttestedSessionPayout;
            potentialNoShowFee += pendingNoShowFee;
            pendingGraceReservationCount = pendingGraceReservations;
        }
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
    /// @return attestedSessionPayoutChunk Provider payout from attested sessions in this chunk
    /// @return potentialNoShowFeeChunk Provider fee from finalizable no-shows in this chunk
    /// @return pendingGraceReservationCountChunk Access-authorized reservations still in attestation grace
    /// @return accruedReceivableChunk Existing outstanding receivable (+only when offset==0)
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
            uint256 attestedSessionPayoutChunk,
            uint256 potentialNoShowFeeChunk,
            uint256 pendingGraceReservationCountChunk,
            uint256 accruedReceivableChunk,
            uint256 nextOffset,
            bool hasMore
        )
    {
        require(limit > 0 && limit <= 1000, "Invalid limit");

        AppStorage storage s = _s();
        if (offset == 0) {
            accruedReceivableChunk = _outstandingProviderReceivable(s, _labId);
        }

        PayoutCandidate[] storage heap = s.payoutHeaps[_labId];
        uint256 heapLength = heap.length;
        if (offset >= heapLength) {
            nextOffset = heapLength;
            return (
                attestedSessionPayoutChunk,
                potentialNoShowFeeChunk,
                pendingGraceReservationCountChunk,
                accruedReceivableChunk,
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
            // Settlement eligibility is intentionally evaluated against chain time.
            // slither-disable-next-line timestamp
            if (candidate.end < currentTime) {
                Reservation storage reservation =
                    s.reservations[LibReservationIdentity.reservationKeyForId(s, candidate.key)];
                (uint256 attestedSessionPayout, uint256 potentialNoShowFee, uint256 pendingGraceReservations) =
                    _previewPayoutCandidate(s, candidate, reservation, _labId, currentTime);
                attestedSessionPayoutChunk += attestedSessionPayout;
                potentialNoShowFeeChunk += potentialNoShowFee;
                pendingGraceReservationCountChunk += pendingGraceReservations;
            }
            unchecked {
                ++i;
            }
        }

        nextOffset = end;
        hasMore = end < heapLength;
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

    /// @notice Returns the most recently queued settlement batch for a lab.
    function getLatestProviderSettlementBatch(
        uint256 _labId
    ) external view returns (bytes32 batchId) {
        return _s().providerSettlementLatestBatchId[_labId];
    }

    /// @notice Returns the canonical scope and remaining amount of a settlement batch.
    function getProviderSettlementBatch(
        bytes32 batchId
    )
        external
        view
        returns (
            uint256 labId,
            uint256 totalAmount,
            uint256 remainingAmount,
            bytes32 scopeRoot,
            uint64 createdAt,
            uint64 claimedAt,
            uint8 status
        )
    {
        ProviderSettlementBatch storage batch = _s().providerSettlementBatches[batchId];
        return (
            batch.labId,
            batch.totalAmount,
            batch.remainingAmount,
            batch.scopeRoot,
            batch.createdAt,
            batch.claimedAt,
            batch.status
        );
    }

    /// @notice Returns the audit data for a batch dispute or reversal.
    function getProviderSettlementBatchResolution(
        bytes32 batchId
    ) external view returns (bytes32 referenceHash, address actor, uint64 timestamp) {
        ProviderSettlementBatch storage batch = _s().providerSettlementBatches[batchId];
        return (batch.resolutionReferenceHash, batch.resolutionActor, batch.resolutionAt);
    }

    /// @notice Creates a claim for a bounded amount already queued for settlement.
    /// @dev The batch is the canonical reservation scope. Claims consume one
    ///      complete batch so a partial amount cannot be paired with an
    ///      unverified reservation subset.
    function submitProviderSettlementClaim(
        bytes32 claimId,
        uint256 labId,
        uint256 amount,
        bytes32 batchId,
        bytes32 invoiceReferenceHash
    ) external nonReentrant {
        // These timestamps are audit fields; authorization is enforced by claim and batch state.
        // slither-disable-start timestamp
        require(claimId != bytes32(0), "Claim ID required");
        require(amount > 0, "Amount required");
        require(batchId != bytes32(0), "Settlement batch required");
        require(invoiceReferenceHash != bytes32(0), "Invoice reference required");

        AppStorage storage s = _s();
        ProviderSettlementBatch storage batch = s.providerSettlementBatches[batchId];
        require(batch.createdAt != 0, "Settlement batch not found");
        require(batch.labId == labId, "Settlement batch lab mismatch");
        require(batch.status == _BATCH_QUEUED, "Settlement batch not claimable");
        require(batch.remainingAmount == amount, "Claim amount must match batch remaining amount");
        require(s.providerSettlementClaims[claimId].submittedBy == address(0), "Claim already exists");
        require(!s.providerSettlementInvoiceReferenceUsed[invoiceReferenceHash], "Invoice reference already used");
        _requireSettlementOperator(s, labId);
        require(s.providerSettlementQueue[labId] >= amount, "Insufficient queued receivable");

        ProviderSettlementClaim storage claim = s.providerSettlementClaims[claimId];
        claim.labId = labId;
        claim.amount = amount;
        claim.batchId = batchId;
        claim.invoiceReferenceHash = invoiceReferenceHash;
        claim.submittedBy = msg.sender;
        claim.submittedAt = uint64(block.timestamp);
        claim.status = _CLAIM_SUBMITTED;
        s.providerSettlementInvoiceReferenceUsed[invoiceReferenceHash] = true;

        batch.remainingAmount = 0;
        batch.claimedAt = uint64(block.timestamp);
        batch.status = _BATCH_CLAIMED;

        _decreaseReceivableBucket(s, labId, _RECEIVABLE_QUEUED, amount);
        _increaseReceivableBucket(s, labId, _RECEIVABLE_INVOICED, amount);
        emit ProviderReceivableLifecycleTransition(
            msg.sender, labId, _RECEIVABLE_QUEUED, _RECEIVABLE_INVOICED, amount, claimId
        );
        emit ProviderSettlementClaimSubmitted(claimId, labId, amount, batchId, invoiceReferenceHash, msg.sender);
        emit ProviderSettlementScopeReferenced(batchId, labId, amount, batch.scopeRoot, claimId);
        // slither-disable-end timestamp
    }

    /// @notice Approves a submitted claim with a non-empty external approval reference hash.
    /// @dev Only an account with SETTLEMENT_APPROVER_ROLE may approve.
    function approveProviderSettlementClaim(
        bytes32 claimId,
        bytes32 approvalReferenceHash
    ) external nonReentrant {
        // The approval timestamp is an audit field; claim state controls this transition.
        // slither-disable-start timestamp
        require(approvalReferenceHash != bytes32(0), "Approval reference required");
        AppStorage storage s = _s();
        ProviderSettlementClaim storage claim = s.providerSettlementClaims[claimId];
        require(claim.status == _CLAIM_SUBMITTED, "Claim is not submitted");
        require(s.providerSettlementBatches[claim.batchId].status == _BATCH_CLAIMED, "Settlement batch invalidated");
        require(!s.providerSettlementApprovalReferenceUsed[approvalReferenceHash], "Approval reference already used");
        _requireSettlementApprover(s);
        require(claim.approvedBy == address(0), "Claim already approved");

        s.providerSettlementApprovalReferenceUsed[approvalReferenceHash] = true;
        claim.approvalReferenceHash = approvalReferenceHash;
        claim.approvedBy = msg.sender;
        claim.approvedAt = uint64(block.timestamp);
        claim.status = _CLAIM_APPROVED;
        _decreaseReceivableBucket(s, claim.labId, _RECEIVABLE_INVOICED, claim.amount);
        _increaseReceivableBucket(s, claim.labId, _RECEIVABLE_APPROVED, claim.amount);
        emit ProviderReceivableLifecycleTransition(
            msg.sender, claim.labId, _RECEIVABLE_INVOICED, _RECEIVABLE_APPROVED, claim.amount, claimId
        );
        emit ProviderSettlementClaimApproved(claimId, approvalReferenceHash, msg.sender);
        emit ProviderSettlementScopeReferenced(
            claim.batchId, claim.labId, claim.amount, s.providerSettlementBatches[claim.batchId].scopeRoot, claimId
        );
        // slither-disable-end timestamp
    }

    /// @notice Records a paid claim only with a unique payment reference and proof hash.
    /// @dev Only an account with SETTLEMENT_PAYER_ROLE may pay, and it must differ from approvedBy.
    function recordProviderSettlementClaimPayment(
        bytes32 claimId,
        bytes32 paymentReferenceHash,
        bytes32 paymentAttestationHash
    ) external nonReentrant {
        // The payment timestamp is an audit field; claim state controls this transition.
        // slither-disable-start timestamp
        require(paymentReferenceHash != bytes32(0), "Payment reference required");
        require(paymentAttestationHash != bytes32(0), "Payment attestation required");

        AppStorage storage s = _s();
        ProviderSettlementClaim storage claim = s.providerSettlementClaims[claimId];
        require(claim.status == _CLAIM_APPROVED, "Claim is not approved");
        require(s.providerSettlementBatches[claim.batchId].status == _BATCH_CLAIMED, "Settlement batch invalidated");
        require(!s.providerSettlementPaymentReferenceUsed[paymentReferenceHash], "Payment reference already used");
        _requireSettlementPayer(s);
        require(claim.approvedBy != msg.sender, "Approver cannot pay");

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
        emit ProviderSettlementScopeReferenced(
            claim.batchId, claim.labId, claim.amount, s.providerSettlementBatches[claim.batchId].scopeRoot, claimId
        );
        // slither-disable-end timestamp
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
            bytes32 batchId,
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
            claim.batchId,
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

    /// @notice Returns the approval reference retained with a claim.
    /// @dev Kept as a separate getter so the original audit getter ABI remains
    ///      compatible with already generated clients.
    function getProviderSettlementClaimApprovalReferenceHash(
        bytes32 claimId
    ) external view returns (bytes32) {
        return _s().providerSettlementClaims[claimId].approvalReferenceHash;
    }

    /// @notice Returns the audit data for a claim dispute or reversal.
    function getProviderSettlementClaimResolution(
        bytes32 claimId
    ) external view returns (bytes32 referenceHash, address actor, uint64 timestamp) {
        ProviderSettlementClaim storage claim = _s().providerSettlementClaims[claimId];
        return (claim.resolutionReferenceHash, claim.resolutionActor, claim.resolutionAt);
    }

    /// @notice Disputes one queued settlement batch and invalidates its claim scope.
    /// @dev A disputed batch cannot be claimed. Resolution to REVERSED must use
    ///      reverseSettlementBatch with a new audit reference.
    function disputeSettlementBatch(
        bytes32 batchId,
        bytes32 referenceHash
    ) external nonReentrant {
        _invalidateSettlementBatch(batchId, _BATCH_DISPUTED, referenceHash);
    }

    /// @notice Reverses one queued or previously disputed settlement batch.
    function reverseSettlementBatch(
        bytes32 batchId,
        bytes32 referenceHash
    ) external nonReentrant {
        _invalidateSettlementBatch(batchId, _BATCH_REVERSED, referenceHash);
    }

    /// @notice Disputes one submitted or approved settlement claim.
    function disputeSettlementClaim(
        bytes32 claimId,
        bytes32 referenceHash
    ) external nonReentrant {
        _invalidateSettlementClaim(claimId, _CLAIM_DISPUTED, referenceHash);
    }

    /// @notice Reverses one submitted, approved, or disputed settlement claim.
    function reverseSettlementClaim(
        bytes32 claimId,
        bytes32 referenceHash
    ) external nonReentrant {
        _invalidateSettlementClaim(claimId, _CLAIM_REVERSED, referenceHash);
    }

    /// @notice Moves provider receivable amount between explicit lifecycle buckets.
    /// @dev Retained as a fail-closed selector for stale integrations. Object-bound
    ///      dispute and reversal must use the settlement batch/claim selectors.
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

        // An accrued balance is only queueable through requestProviderPayout,
        // which creates the immutable batch and captures its scope root.
        require(fromState != _RECEIVABLE_ACCRUED, "Use requestProviderPayout");

        if (toState == _RECEIVABLE_INVOICED || toState == _RECEIVABLE_APPROVED || toState == _RECEIVABLE_PAID) {
            if (toState == _RECEIVABLE_APPROVED || toState == _RECEIVABLE_PAID) {
                _requireSettlementOperatorForFinancialTransition(s);
            } else {
                _requireSettlementOperator(s, _labId);
            }
            revert("Claim required");
        }

        if (toState == _RECEIVABLE_REVERSED || toState == _RECEIVABLE_DISPUTED) {
            _requireSettlementOperatorForFinancialTransition(s);
            revert("Use settlement object");
        }

        revert("Invalid transition");
    }

    function _invalidateSettlementBatch(
        bytes32 batchId,
        uint8 targetStatus,
        bytes32 referenceHash
    ) internal {
        // Resolution timestamps are audit fields; authorization is state-based.
        // slither-disable-start timestamp
        require(referenceHash != bytes32(0), "Reference required");

        AppStorage storage s = _s();
        ProviderSettlementBatch storage batch = s.providerSettlementBatches[batchId];
        require(batch.createdAt != 0, "Settlement batch not found");

        uint8 fromStatus = batch.status;
        uint8 fromBucket;
        if (targetStatus == _BATCH_DISPUTED) {
            require(fromStatus == _BATCH_QUEUED, "Batch is not queued");
            fromBucket = _RECEIVABLE_QUEUED;
        } else {
            require(targetStatus == _BATCH_REVERSED, "Invalid batch resolution");
            require(fromStatus == _BATCH_QUEUED || fromStatus == _BATCH_DISPUTED, "Batch cannot be reversed");
            fromBucket = fromStatus == _BATCH_DISPUTED ? _RECEIVABLE_DISPUTED : _RECEIVABLE_QUEUED;
        }

        _requireSettlementOperatorForFinancialTransition(s);
        require(!s.providerSettlementResolutionReferenceUsed[referenceHash], "Resolution reference already used");
        s.providerSettlementResolutionReferenceUsed[referenceHash] = true;

        uint256 amount = batch.totalAmount;
        _decreaseReceivableBucket(s, batch.labId, fromBucket, amount);
        _increaseReceivableBucket(
            s, batch.labId, targetStatus == _BATCH_DISPUTED ? _RECEIVABLE_DISPUTED : _RECEIVABLE_REVERSED, amount
        );

        uint64 timestamp = uint64(block.timestamp);
        batch.remainingAmount = 0;
        batch.status = targetStatus;
        batch.resolutionReferenceHash = referenceHash;
        batch.resolutionActor = msg.sender;
        batch.resolutionAt = timestamp;

        emit ProviderReceivableLifecycleTransition(
            msg.sender,
            batch.labId,
            fromBucket,
            targetStatus == _BATCH_DISPUTED ? _RECEIVABLE_DISPUTED : _RECEIVABLE_REVERSED,
            amount,
            referenceHash
        );
        emit ProviderSettlementBatchInvalidated(
            batchId, batch.labId, amount, fromStatus, targetStatus, referenceHash, msg.sender, timestamp
        );
        // slither-disable-end timestamp
    }

    function _invalidateSettlementClaim(
        bytes32 claimId,
        uint8 targetStatus,
        bytes32 referenceHash
    ) internal {
        // Resolution timestamps are audit fields; authorization is state-based.
        // slither-disable-start timestamp
        require(referenceHash != bytes32(0), "Reference required");

        AppStorage storage s = _s();
        ProviderSettlementClaim storage claim = s.providerSettlementClaims[claimId];
        require(claim.submittedBy != address(0), "Settlement claim not found");

        uint8 fromBucket = _RECEIVABLE_INVOICED;
        if (claim.status == _CLAIM_SUBMITTED) {
            fromBucket = _RECEIVABLE_INVOICED;
        } else if (claim.status == _CLAIM_APPROVED) {
            fromBucket = _RECEIVABLE_APPROVED;
        } else if (claim.status == _CLAIM_DISPUTED) {
            require(targetStatus == _CLAIM_REVERSED, "Claim already disputed");
            fromBucket = _RECEIVABLE_DISPUTED;
        } else {
            revert("Claim cannot be invalidated");
        }

        if (targetStatus == _CLAIM_DISPUTED) {
            require(claim.status == _CLAIM_SUBMITTED || claim.status == _CLAIM_APPROVED, "Claim cannot be disputed");
        } else {
            require(targetStatus == _CLAIM_REVERSED, "Invalid claim resolution");
        }

        ProviderSettlementBatch storage batch = s.providerSettlementBatches[claim.batchId];
        require(
            batch.status == (claim.status == _CLAIM_DISPUTED ? _BATCH_DISPUTED : _BATCH_CLAIMED),
            "Settlement batch invalidated"
        );

        _requireSettlementOperatorForFinancialTransition(s);
        require(!s.providerSettlementResolutionReferenceUsed[referenceHash], "Resolution reference already used");
        s.providerSettlementResolutionReferenceUsed[referenceHash] = true;

        uint8 toBucket = targetStatus == _CLAIM_DISPUTED ? _RECEIVABLE_DISPUTED : _RECEIVABLE_REVERSED;
        _decreaseReceivableBucket(s, claim.labId, fromBucket, claim.amount);
        _increaseReceivableBucket(s, claim.labId, toBucket, claim.amount);

        uint8 fromStatus = claim.status;
        uint64 timestamp = uint64(block.timestamp);
        claim.status = targetStatus;
        claim.resolutionReferenceHash = referenceHash;
        claim.resolutionActor = msg.sender;
        claim.resolutionAt = timestamp;
        batch.status = targetStatus == _CLAIM_DISPUTED ? _BATCH_DISPUTED : _BATCH_REVERSED;
        batch.resolutionReferenceHash = referenceHash;
        batch.resolutionActor = msg.sender;
        batch.resolutionAt = timestamp;

        emit ProviderReceivableLifecycleTransition(
            msg.sender, claim.labId, fromBucket, toBucket, claim.amount, referenceHash
        );
        emit ProviderSettlementClaimInvalidated(
            claimId,
            claim.batchId,
            claim.labId,
            claim.amount,
            fromStatus,
            targetStatus,
            referenceHash,
            msg.sender,
            timestamp
        );
        emit ProviderSettlementScopeReferenced(claim.batchId, claim.labId, claim.amount, batch.scopeRoot, claimId);
        // slither-disable-end timestamp
    }

    /// @dev Traverses payout heap with pruning under a strict invariant:
    ///      `heap` must be a strict min-heap ordered by `end` for all active nodes.
    ///      Under that invariant, if `node.end > currentTime`, all descendants are also ineligible.
    ///      Any heap rebuild, compaction, or update path must preserve this ordering assumption.
    function _accumulatePayoutPreviewFromHeap(
        AppStorage storage s,
        PayoutCandidate[] storage heap,
        uint256 heapLength,
        uint256 nodeIndex,
        uint256 currentTime,
        uint256 labId
    )
        internal
        view
        returns (uint256 attestedSessionPayout, uint256 potentialNoShowFee, uint256 pendingGraceReservationCount)
    {
        if (nodeIndex >= heapLength) {
            return (0, 0, 0);
        }

        PayoutCandidate storage candidate = heap[nodeIndex];
        // Settlement eligibility is intentionally evaluated against chain time.
        // slither-disable-next-line timestamp
        if (candidate.end >= currentTime) {
            return (0, 0, 0);
        }

        Reservation storage reservation = s.reservations[LibReservationIdentity.reservationKeyForId(s, candidate.key)];
        (attestedSessionPayout, potentialNoShowFee, pendingGraceReservationCount) =
            _previewPayoutCandidate(s, candidate, reservation, labId, currentTime);

        uint256 left = nodeIndex * 2 + 1;
        if (left < heapLength) {
            (uint256 leftAttestedSessionPayout, uint256 leftPotentialNoShowFee, uint256 leftPendingGraceReservations) =
                _accumulatePayoutPreviewFromHeap(s, heap, heapLength, left, currentTime, labId);
            attestedSessionPayout += leftAttestedSessionPayout;
            potentialNoShowFee += leftPotentialNoShowFee;
            pendingGraceReservationCount += leftPendingGraceReservations;
        }

        uint256 right = left + 1;
        if (right < heapLength) {
            (
                uint256 rightAttestedSessionPayout,
                uint256 rightPotentialNoShowFee,
                uint256 rightPendingGraceReservations
            ) = _accumulatePayoutPreviewFromHeap(s, heap, heapLength, right, currentTime, labId);
            attestedSessionPayout += rightAttestedSessionPayout;
            potentialNoShowFee += rightPotentialNoShowFee;
            pendingGraceReservationCount += rightPendingGraceReservations;
        }
    }

    function _previewPayoutCandidate(
        AppStorage storage s,
        PayoutCandidate storage candidate,
        Reservation storage reservation,
        uint256 labId,
        uint256 currentTime
    )
        internal
        view
        returns (uint256 attestedSessionPayout, uint256 potentialNoShowFee, uint256 pendingGraceReservationCount)
    {
        if (
            reservation.labId != labId || (reservation.end != 0 && reservation.end != candidate.end)
                || (reservation.status != _CONFIRMED && reservation.status != _ACCESS_AUTHORIZED)
        ) {
            return (0, 0, 0);
        }

        if (s.emergencyCheckInReviews[candidate.key].settlementExcluded) {
            return (0, 0, 0);
        }

        if (s.reservationSessionStartedRecorded[candidate.key]) {
            return (reservation.providerShare, 0, 0);
        }

        if (!LibInstitutionalReservationSettlement.isEconomicallyExpired(s, reservation, candidate.key, currentTime)) {
            return (0, 0, 1);
        }

        if (s.labs[labId].resourceType != 0) {
            return (0, 0, 0);
        }

        // Only the provider fee is part of this preview category; the payer refund is
        // intentionally omitted because it is not an outstanding provider receivable.
        // slither-disable-next-line unused-return
        (uint96 providerFee,) = LibRevenue.computeNoShowSettlement(reservation.price);
        return (0, providerFee, 0);
    }

    // -------------------------------------------------------------------------
    // Internal helpers
    // -------------------------------------------------------------------------

    function _requestProviderPayout(
        uint256 _labId,
        uint256 maxBatch
    ) internal {
        // Candidate eligibility intentionally uses the current chain time for expiry and grace checks.
        // slither-disable-start timestamp
        if (maxBatch == 0 || maxBatch > 100) revert("Invalid batch size");

        AppStorage storage s = _s();

        address labOwner = LibERC721Storage.ownerOf(_labId);
        address backend = s.institutionalBackends[labOwner];
        if (msg.sender != labOwner && msg.sender != backend) {
            revert("Not authorized");
        }

        uint256 processed = 0;
        uint256 currentTime = block.timestamp;
        bool pendingGraceEncountered;
        bool scanLimitReached;
        while (processed < maxBatch) {
            (bytes32 key, bool pendingGrace, bool scanLimitReachedThisScan) =
                _popExpiredReservationCandidate(s, _labId, currentTime);
            // bytes32(0) is the explicit no-candidate sentinel returned by the heap.
            // slither-disable-next-line incorrect-equality
            if (key == bytes32(0)) {
                pendingGraceEncountered = pendingGraceEncountered || (pendingGrace && scanLimitReachedThisScan);
                scanLimitReached = scanLimitReached || scanLimitReachedThisScan;
                break;
            }
            pendingGraceEncountered = pendingGraceEncountered || pendingGrace;
            Reservation storage reservation = s.reservations[key];
            if (_finalizeReservationFromPayoutHeap(s, key, reservation, _labId)) {
                unchecked {
                    ++processed;
                }
            }
        }

        // A prior finalizer may have already removed the reservation from the heap while
        // leaving its legitimate provider receivable in ACCRUED. Queue the whole bucket
        // so provider collection does not depend on this call having finalized a row.
        uint256 providerPayout = s.providerReceivableAccrued[_labId];
        if (providerPayout == 0 && processed == 0) {
            if (!scanLimitReached && !pendingGraceEncountered) revert("No settleable reservations");
            emit ProviderPayoutRequested(labOwner, _labId, 0, 0);
            return;
        }

        if (providerPayout > 0) {
            bytes32 batchId = _createProviderSettlementBatch(s, _labId, providerPayout);
            _decreaseReceivableBucket(s, _labId, _RECEIVABLE_ACCRUED, providerPayout);
            _increaseReceivableBucket(s, _labId, _RECEIVABLE_QUEUED, providerPayout);
            emit ProviderReceivableLifecycleTransition(
                msg.sender, _labId, _RECEIVABLE_ACCRUED, _RECEIVABLE_QUEUED, providerPayout, batchId
            );
        }

        emit ProviderPayoutRequested(labOwner, _labId, providerPayout, processed);
        // slither-disable-end timestamp
    }

    function _createProviderSettlementBatch(
        AppStorage storage s,
        uint256 labId,
        uint256 amount
    ) internal returns (bytes32 batchId) {
        bytes32 scopeRoot = s.providerReceivableAccruedScopeRoot[labId];
        require(scopeRoot != bytes32(0), "Accrual scope required");

        uint256 nonce = ++s.providerSettlementBatchNextNonce;
        batchId = keccak256(
            abi.encode("DECENTRALABS_PROVIDER_SETTLEMENT_BATCH_V1", address(this), nonce, labId, amount, scopeRoot)
        );

        ProviderSettlementBatch storage batch = s.providerSettlementBatches[batchId];
        batch.labId = labId;
        batch.totalAmount = amount;
        batch.remainingAmount = amount;
        batch.scopeRoot = scopeRoot;
        batch.createdAt = uint64(block.timestamp);
        batch.status = _BATCH_QUEUED;
        s.providerSettlementLatestBatchId[labId] = batchId;
        s.providerReceivableAccruedScopeRoot[labId] = bytes32(0);

        emit ProviderSettlementBatchCreated(batchId, labId, amount, scopeRoot, msg.sender);
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

    function _requireSettlementApprover(
        AppStorage storage s
    ) internal view {
        require(s.roleMembers[SETTLEMENT_APPROVER_ROLE].contains(msg.sender), "Not authorized");
    }

    function _requireSettlementPayer(
        AppStorage storage s
    ) internal view {
        require(s.roleMembers[SETTLEMENT_PAYER_ROLE].contains(msg.sender), "Not authorized");
    }

    function _outstandingProviderReceivable(
        AppStorage storage s,
        uint256 labId
    ) internal view returns (uint256) {
        return s.providerReceivableAccrued[labId] + s.providerSettlementQueue[labId]
            + s.providerReceivableInvoiced[labId] + s.providerReceivableApproved[labId]
            + s.providerReceivableDisputed[labId];
    }

    function _isSupportedReceivableState(
        uint8 state
    ) internal pure returns (bool) {
        return state >= _RECEIVABLE_ACCRUED && state <= _RECEIVABLE_DISPUTED;
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
        // This helper only moves balances; timestamp detection is propagated from its callers.
        // slither-disable-start timestamp
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
        // slither-disable-end timestamp
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

    /// @dev Finds one economically expired reservation without allowing a
    ///      grace-pending candidate to block later attested sessions.
    function _popExpiredReservationCandidate(
        AppStorage storage s,
        uint256 labId,
        uint256 currentTime
    ) internal returns (bytes32, bool, bool) {
        (bytes32 reservationKey, bool pendingGraceEncountered, bool scanLimitReached) =
            LibHeap.popEligiblePayoutCandidate(s, labId, currentTime);
        return (reservationKey, pendingGraceEncountered, scanLimitReached);
    }

    /// @dev Delegates finalization to the shared institutional settlement path.
    function _finalizeReservationFromPayoutHeap(
        AppStorage storage s,
        bytes32 key,
        Reservation storage reservation,
        uint256 labId
    ) internal returns (bool) {
        uint256 currentTime = block.timestamp;
        if (LibInstitutionalReservationSettlement.finalizeProviderPayoutReservation(
                s, key, reservation, labId, currentTime
            )) {
            return true;
        }
        return LibInstitutionalReservationSettlement.finalizeExpiredReservation(s, key, reservation, labId, currentTime);
    }
}
