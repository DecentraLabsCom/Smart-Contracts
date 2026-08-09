// SPDX-License-Identifier: GPL-3.0-or-later
pragma solidity ^0.8.33;

import {
    AppStorage,
    LibAppStorage,
    CreditLot,
    CreditMovement,
    CreditMovementKind,
    CreditReservationAllocation
} from "./LibAppStorage.sol";
import {LibReservationIdentity} from "./LibReservationIdentity.sol";

/// @title LibCreditLedger
/// @notice Lot-based credit ledger with lock/capture/release semantics for MiCA 4.3.d compliance
/// @dev All write operations record a CreditMovement entry for audit traceability.
///      Lot consumption follows FIFO order (oldest non-expired lot first).
///      Available balance is the unexpired lot-backed balance minus locked credits.
library LibCreditLedger {
    uint256 internal constant MAX_ACTIVE_CREDIT_LOTS = 128;
    // Terminal reservation paths refund and release allocation provenance in
    // the same transaction. Keep new reservations below the measured bound
    // that fits the production contract gas limit with headroom for the
    // surrounding reservation transition. The physical ledger may still hold
    // 128 lots, and legacy allocations remain recoverable in batches.
    uint256 internal constant MAX_RESERVATION_ALLOCATIONS = 4;
    uint256 internal constant MAX_REFUND_ALLOCATIONS_PER_BATCH = 32;

    error ZeroAccount();
    error ZeroAmount();
    error InsufficientAvailableCredits();
    error InsufficientLockedCredits();
    error LotExpired();
    error LotAlreadyExpired();
    error LotNotExpired();
    error ExpiryInPast();
    error UnbackedCreditBalance();
    error NoReservationAllocation();
    error RefundExceedsReservationAllocation();
    error CreditLotLimitExceeded();
    error ReservationAllocationLimitExceeded();
    error InvalidRefundBatchSize();
    error SourceLotNotFound();
    error ReservationAllocationsFinalized();

    /// @notice Available (unlocked) credits for an account
    function availableBalanceOf(
        address account
    ) internal view returns (uint256) {
        AppStorage storage s = LibAppStorage.diamondStorage();
        uint256 effectiveBalance = _effectiveBalance(s.creditLots[account]);
        uint256 locked = s.creditLockedBalance[account];
        return effectiveBalance > locked ? effectiveBalance - locked : 0;
    }

    /// @notice Locked credits for an account (reserved for pending reservations)
    function lockedBalanceOf(
        address account
    ) internal view returns (uint256) {
        return LibAppStorage.diamondStorage().creditLockedBalance[account];
    }

    /// @notice Total credits for an account (available + locked)
    function totalBalanceOf(
        address account
    ) internal view returns (uint256) {
        return LibAppStorage.diamondStorage().serviceCreditBalance[account];
    }

    /// @notice Mint credits into a new funding lot
    function mintCredits(
        address account,
        uint256 creditAmount,
        bytes32 fundingOrderId,
        uint256 eurGrossAmount,
        uint48 expiresAt
    ) internal returns (uint256 lotId) {
        if (account == address(0)) revert ZeroAccount();
        if (creditAmount == 0) revert ZeroAmount();
        if (expiresAt != 0 && expiresAt <= block.timestamp) revert ExpiryInPast();

        AppStorage storage s = LibAppStorage.diamondStorage();

        lotId = _appendLot(s, account, creditAmount, fundingOrderId, eurGrossAmount, expiresAt);

        s.serviceCreditBalance[account] += creditAmount;

        _recordMovement(s, account, CreditMovementKind.MINT, creditAmount, fundingOrderId);
    }

    /// @notice Lock credits for a pending reservation (not yet captured)
    function lockCredits(
        address account,
        uint256 amount,
        bytes32 reservationRef
    ) internal {
        if (account == address(0)) revert ZeroAccount();
        if (amount == 0) revert ZeroAmount();

        AppStorage storage s = LibAppStorage.diamondStorage();
        reservationRef = LibReservationIdentity.resolveReservationRef(s, reservationRef);
        _requireReservationAllocationsOpen(s, account, reservationRef);

        uint256 available = availableBalanceOf(account);
        if (available < amount) revert InsufficientAvailableCredits();

        uint48 lockedExpiry = _earliestExpiryForAmount(s.creditLots[account], s.creditLotCursor[account], amount);
        uint48 existingExpiry = s.creditReservationExpiry[account][reservationRef];
        if (existingExpiry == 0 || (lockedExpiry != 0 && lockedExpiry < existingExpiry)) {
            s.creditReservationExpiry[account][reservationRef] = lockedExpiry;
        }

        s.creditLockedBalance[account] += amount;

        _recordMovement(s, account, CreditMovementKind.LOCK, amount, reservationRef);
    }

    /// @notice Capture previously locked credits (consume from lots FIFO)
    function captureLockedCredits(
        address account,
        uint256 amount,
        bytes32 reservationRef
    ) internal {
        if (account == address(0)) revert ZeroAccount();
        if (amount == 0) revert ZeroAmount();

        AppStorage storage s = LibAppStorage.diamondStorage();
        reservationRef = LibReservationIdentity.resolveReservationRef(s, reservationRef);
        _requireReservationAllocationsOpen(s, account, reservationRef);

        if (s.creditLockedBalance[account] < amount) revert InsufficientLockedCredits();

        s.creditLockedBalance[account] -= amount;
        s.serviceCreditBalance[account] -= amount;

        _consumeFromLots(s, account, amount, reservationRef, true);

        _recordMovement(s, account, CreditMovementKind.CAPTURE, amount, reservationRef);
    }

    /// @notice Release previously locked credits back to available (e.g. reservation denied)
    function releaseLockedCredits(
        address account,
        uint256 amount,
        bytes32 reservationRef
    ) internal {
        if (account == address(0)) revert ZeroAccount();
        if (amount == 0) revert ZeroAmount();

        AppStorage storage s = LibAppStorage.diamondStorage();
        reservationRef = LibReservationIdentity.resolveReservationRef(s, reservationRef);

        if (s.creditLockedBalance[account] < amount) revert InsufficientLockedCredits();

        s.creditLockedBalance[account] -= amount;

        _recordMovement(s, account, CreditMovementKind.RELEASE, amount, reservationRef);
    }

    /// @notice Cancel/refund credits back to an account (e.g. post-confirmation cancellation)
    function cancelCredits(
        address account,
        uint256 amount,
        bytes32 reservationRef
    ) internal {
        (,, bool complete) = cancelCreditsBatch(account, amount, reservationRef, type(uint256).max);
        if (!complete) revert RefundExceedsReservationAllocation();
    }

    /// @notice Refund credits using a bounded number of source allocations.
    /// @dev The cursor is persisted only when the requested amount still has
    ///      refundable allocations remaining. Legacy reservations can therefore
    ///      be recovered in several transactions without copying or scanning
    ///      their complete allocation list in one transaction.
    function cancelCreditsBatch(
        address account,
        uint256 amount,
        bytes32 reservationRef,
        uint256 maxAllocations
    ) internal returns (uint256 refundedAmount, uint256 nextCursor, bool complete) {
        if (account == address(0)) revert ZeroAccount();
        if (amount == 0) revert ZeroAmount();
        if (maxAllocations == 0) revert InvalidRefundBatchSize();
        if (maxAllocations != type(uint256).max && maxAllocations > MAX_REFUND_ALLOCATIONS_PER_BATCH) {
            revert InvalidRefundBatchSize();
        }

        AppStorage storage s = LibAppStorage.diamondStorage();
        reservationRef = LibReservationIdentity.resolveReservationRef(s, reservationRef);
        if (s.creditReservationAllocationsFinalized[account][reservationRef]) {
            revert ReservationAllocationsFinalized();
        }

        CreditReservationAllocation[] storage allocations = s.creditReservationAllocations[account][reservationRef];
        if (allocations.length == 0) revert NoReservationAllocation();
        uint256 remainingToRefund = amount;
        uint256 i = s.creditReservationRefundCursor[account][reservationRef];
        uint256 processed;
        for (; i < allocations.length && remainingToRefund > 0 && processed < maxAllocations;) {
            CreditReservationAllocation storage allocation = allocations[i];
            uint256 refundableAmount = allocation.amount - allocation.refundedAmount;
            if (refundableAmount > 0) {
                uint256 refundAmount = refundableAmount < remainingToRefund ? refundableAmount : remainingToRefund;
                uint256 refundableEur = allocation.eurGrossAmount - allocation.refundedEurGrossAmount;
                uint256 refundEur = refundAmount == refundableAmount
                    ? refundableEur
                    : (refundableEur * refundAmount) / refundableAmount;

                allocation.refundedAmount += refundAmount;
                allocation.refundedEurGrossAmount += refundEur;
                if (s.creditReservationAllocationLotIdSet[account][reservationRef][i]) {
                    if (!_restoreRefundToSourceLot(s, account, allocation.lotId, refundAmount, refundEur)) {
                        revert SourceLotNotFound();
                    }
                    if (allocation.refundedAmount == allocation.amount) {
                        _releaseRefundReference(s, account, reservationRef, i, allocation.lotId);
                    }
                } else {
                    // Allocations written before lot IDs were recorded retain
                    // the former provenance-based fallback for storage upgrade
                    // compatibility. New allocations never use this branch.
                    bool restored;
                    if (s.creditLots[account].length >= MAX_ACTIVE_CREDIT_LOTS) {
                        restored = _restoreLegacyRefundToExistingLot(
                            s, account, refundAmount, allocation.fundingOrderId, refundEur, allocation.expiresAt
                        );
                    }
                    if (!restored) {
                        _appendLot(s, account, refundAmount, allocation.fundingOrderId, refundEur, allocation.expiresAt);
                    }
                }
                s.serviceCreditBalance[account] += refundAmount;
                remainingToRefund -= refundAmount;
                refundedAmount += refundAmount;
            }
            unchecked {
                ++i;
                ++processed;
            }
        }

        if (remainingToRefund != 0) {
            if (i >= allocations.length) revert RefundExceedsReservationAllocation();
            s.creditReservationRefundCursor[account][reservationRef] = i;
            if (refundedAmount > 0) {
                _recordMovement(s, account, CreditMovementKind.CANCEL, refundedAmount, reservationRef);
            }
            return (refundedAmount, i, false);
        }

        delete s.creditReservationRefundCursor[account][reservationRef];
        delete s.creditReservationExpiry[account][reservationRef];

        _recordMovement(s, account, CreditMovementKind.CANCEL, refundedAmount, reservationRef);
        return (refundedAmount, i, true);
    }

    /// @notice Close the refund entitlement of a terminal reservation.
    /// @dev Allocation provenance remains readable forever. Only the
    ///      refundable-reference sidecar is released, and each allocation is
    ///      marked before the reservation-level flag makes this operation
    ///      idempotent across repeated maintenance calls.
    function finalizeReservationCreditAllocations(
        address account,
        bytes32 reservationRef
    ) internal returns (uint256 releasedReferences) {
        if (account == address(0)) revert ZeroAccount();

        AppStorage storage s = LibAppStorage.diamondStorage();
        reservationRef = LibReservationIdentity.resolveReservationRef(s, reservationRef);
        if (s.creditReservationAllocationsFinalized[account][reservationRef]) return 0;

        CreditReservationAllocation[] storage allocations = s.creditReservationAllocations[account][reservationRef];
        if (allocations.length == 0) return 0;

        for (uint256 i; i < allocations.length;) {
            if (!s.creditReservationAllocationReferenceReleased[account][reservationRef][i]) {
                CreditReservationAllocation storage allocation = allocations[i];
                if (
                    s.creditReservationAllocationLotIdSet[account][reservationRef][i]
                        && allocation.refundedAmount < allocation.amount
                ) {
                    uint256 referenceCount = s.creditLotRefundReferences[allocation.lotId];
                    if (referenceCount > 0) {
                        unchecked {
                            --s.creditLotRefundReferences[allocation.lotId];
                        }
                        ++releasedReferences;
                    }
                }
                s.creditReservationAllocationReferenceReleased[account][reservationRef][i] = true;
            }
            unchecked {
                ++i;
            }
        }

        delete s.creditReservationRefundCursor[account][reservationRef];
        delete s.creditReservationExpiry[account][reservationRef];
        s.creditReservationAllocationsFinalized[account][reservationRef] = true;
    }

    /// @notice Debit available credits for an identified reservation.
    /// @dev Unlike a generic administrative adjustment, this records the
    ///      earliest source-lot expiry so a later reservation refund cannot
    ///      create credits that outlive the credits originally spent.
    function debitCredits(
        address account,
        uint256 amount,
        bytes32 reservationRef
    ) internal {
        if (account == address(0)) revert ZeroAccount();
        if (amount == 0) revert ZeroAmount();

        AppStorage storage s = LibAppStorage.diamondStorage();
        reservationRef = LibReservationIdentity.resolveReservationRef(s, reservationRef);
        uint256 available = availableBalanceOf(account);
        if (available < amount) revert InsufficientAvailableCredits();

        uint48 spentExpiry = _earliestExpiryForAmount(s.creditLots[account], s.creditLotCursor[account], amount);
        uint48 existingExpiry = s.creditReservationExpiry[account][reservationRef];
        if (existingExpiry == 0 || (spentExpiry != 0 && spentExpiry < existingExpiry)) {
            s.creditReservationExpiry[account][reservationRef] = spentExpiry;
        }

        s.serviceCreditBalance[account] -= amount;
        _consumeFromLots(s, account, amount, reservationRef, true);
        _recordMovement(s, account, CreditMovementKind.ADJUST, amount, reservationRef);
    }

    /// @notice Expire a specific lot and deduct its remaining balance
    function expireLot(
        address account,
        uint256 lotIndex
    ) internal returns (uint256 expiredAmount) {
        if (account == address(0)) revert ZeroAccount();

        AppStorage storage s = LibAppStorage.diamondStorage();
        CreditLot storage lot = s.creditLots[account][lotIndex];

        if (lot.expired) revert LotAlreadyExpired();
        if (lot.expiresAt == 0 || block.timestamp < lot.expiresAt) revert LotNotExpired();

        expiredAmount = lot.remaining;
        if (expiredAmount == 0) return 0;

        uint256 totalBalance = s.serviceCreditBalance[account];
        uint256 lockedBalance = s.creditLockedBalance[account];
        if (totalBalance < lockedBalance) revert InsufficientAvailableCredits();

        uint256 available = totalBalance - lockedBalance;
        if (available < expiredAmount) revert InsufficientAvailableCredits();

        lot.remaining = 0;
        lot.expired = true;
        s.serviceCreditBalance[account] -= expiredAmount;
        _advanceLotCursor(s, account);

        _recordMovement(s, account, CreditMovementKind.EXPIRE, expiredAmount, lot.fundingOrderId);
    }

    /// @notice Administrative credit adjustment (positive = add, negative = subtract)
    function adjustCredits(
        address account,
        int256 delta,
        bytes32 adjustmentRef
    ) internal returns (uint256 newBalance) {
        if (account == address(0)) revert ZeroAccount();
        if (delta == 0) revert ZeroAmount();

        AppStorage storage s = LibAppStorage.diamondStorage();

        if (delta > 0) {
            uint256 amount = uint256(delta);
            s.serviceCreditBalance[account] += amount;

            _appendLot(s, account, amount, adjustmentRef, 0, 0);

            _recordMovement(s, account, CreditMovementKind.ADJUST, amount, adjustmentRef);
            newBalance = s.serviceCreditBalance[account];
        } else {
            uint256 amount = uint256(-delta);
            if (s.serviceCreditBalance[account] < s.creditLockedBalance[account]) {
                revert InsufficientAvailableCredits();
            }
            uint256 available = s.serviceCreditBalance[account] - s.creditLockedBalance[account];
            if (available < amount) revert InsufficientAvailableCredits();

            s.serviceCreditBalance[account] -= amount;
            _consumeFromLots(s, account, amount, adjustmentRef, false);

            _recordMovement(s, account, CreditMovementKind.ADJUST, amount, adjustmentRef);
            newBalance = s.serviceCreditBalance[account];
        }
    }

    /// @notice Get the number of lots for an account
    function lotCount(
        address account
    ) internal view returns (uint256) {
        return LibAppStorage.diamondStorage().creditLots[account].length;
    }

    /// @notice Get a specific lot by index
    function getLot(
        address account,
        uint256 index
    ) internal view returns (CreditLot memory) {
        return LibAppStorage.diamondStorage().creditLots[account][index];
    }

    /// @notice Get the number of credit movements for an account
    function movementCount(
        address account
    ) internal view returns (uint256) {
        return LibAppStorage.diamondStorage().creditMovements[account].length;
    }

    /// @notice Get a specific credit movement by index
    function getMovement(
        address account,
        uint256 index
    ) internal view returns (CreditMovement memory) {
        return LibAppStorage.diamondStorage().creditMovements[account][index];
    }

    /// @notice Get the number of source-lot allocations recorded for a reservation.
    function reservationAllocationCount(
        address account,
        bytes32 reservationRef
    ) internal view returns (uint256) {
        AppStorage storage s = LibAppStorage.diamondStorage();
        reservationRef = LibReservationIdentity.resolveReservationRef(s, reservationRef);
        return s.creditReservationAllocations[account][reservationRef].length;
    }

    /// @notice Get one source-lot allocation recorded for a reservation.
    function getReservationAllocation(
        address account,
        bytes32 reservationRef,
        uint256 index
    ) internal view returns (CreditReservationAllocation memory) {
        AppStorage storage s = LibAppStorage.diamondStorage();
        reservationRef = LibReservationIdentity.resolveReservationRef(s, reservationRef);
        return s.creditReservationAllocations[account][reservationRef][index];
    }

    /// @notice Remove spent/expired lots and merge compatible active lots.
    /// @dev A lot with a refundable source allocation is retained as a logical
    ///      tombstone until that allocation is fully refunded. This prevents
    ///      compaction from destroying the source identity needed by a terminal
    ///      reservation transition.
    function compactCreditLots(
        address account
    ) internal returns (uint256 previousLength, uint256 compactedLength) {
        if (account == address(0)) revert ZeroAccount();

        AppStorage storage s = LibAppStorage.diamondStorage();
        previousLength = s.creditLots[account].length;
        _compactLots(s, account);
        compactedLength = s.creditLots[account].length;
    }

    /// @dev Consume `amount` credits from lots FIFO (oldest first, skip expired)
    function _consumeFromLots(
        AppStorage storage s,
        address account,
        uint256 amount,
        bytes32 reservationRef,
        bool recordAllocation
    ) private {
        CreditLot[] storage lots = s.creditLots[account];
        uint256 remaining = amount;
        uint256 len = lots.length;
        uint256 cursor = s.creditLotCursor[account];
        CreditReservationAllocation[] storage allocations = s.creditReservationAllocations[account][reservationRef];

        if (recordAllocation) {
            _requireReservationAllocationsOpen(s, account, reservationRef);
            uint256 requiredAllocations = _sourceLotCountForAmount(lots, cursor, amount);
            if (
                allocations.length > MAX_RESERVATION_ALLOCATIONS
                    || requiredAllocations > MAX_RESERVATION_ALLOCATIONS - allocations.length
            ) {
                revert ReservationAllocationLimitExceeded();
            }
        }

        for (uint256 i = cursor; i < len && remaining > 0;) {
            CreditLot storage lot = lots[i];
            if (!lot.expired && lot.remaining > 0) {
                if (lot.expiresAt != 0 && lot.expiresAt <= block.timestamp) {
                    unchecked {
                        ++i;
                    }
                    continue;
                }
                uint256 take = lot.remaining < remaining ? lot.remaining : remaining;
                uint256 lotRemainingBefore = lot.remaining;
                uint256 eurRemaining = _remainingEurGrossAmount(s, lot);
                // Initialize the appended sidecar lazily for lots created before
                // this provenance mapping was introduced. The explicit marker
                // distinguishes an initialized zero from legacy zero storage.
                s.creditLotRemainingEurGrossAmount[lot.lotId] = eurRemaining;
                s.creditLotRemainingEurGrossAmountInitialized[lot.lotId] = true;
                uint256 eurTake = take == lotRemainingBefore ? eurRemaining : (eurRemaining * take) / lotRemainingBefore;

                lot.remaining -= take;
                s.creditLotRemainingEurGrossAmount[lot.lotId] = eurRemaining - eurTake;
                if (recordAllocation) {
                    uint256 allocationIndex = allocations.length;
                    allocations.push(
                        CreditReservationAllocation({
                            fundingOrderId: lot.fundingOrderId,
                            amount: take,
                            refundedAmount: 0,
                            eurGrossAmount: eurTake,
                            refundedEurGrossAmount: 0,
                            expiresAt: lot.expiresAt,
                            lotId: lot.lotId
                        })
                    );
                    s.creditReservationAllocationLotIdSet[account][reservationRef][allocationIndex] = true;
                    ++s.creditLotRefundReferences[lot.lotId];
                }
                remaining -= take;
            }
            unchecked {
                ++i;
            }
        }

        if (remaining != 0) revert UnbackedCreditBalance();

        s.creditLotCursor[account] = _nextActiveLotIndex(lots, cursor, len);
    }

    function _sourceLotCountForAmount(
        CreditLot[] storage lots,
        uint256 cursor,
        uint256 amount
    ) private view returns (uint256 count) {
        uint256 remaining = amount;
        for (uint256 i = cursor; i < lots.length && remaining > 0;) {
            CreditLot storage lot = lots[i];
            if (!lot.expired && lot.remaining > 0 && (lot.expiresAt == 0 || lot.expiresAt > block.timestamp)) {
                remaining -= lot.remaining < remaining ? lot.remaining : remaining;
                ++count;
            }
            unchecked {
                ++i;
            }
        }
    }

    function _appendLot(
        AppStorage storage s,
        address account,
        uint256 creditAmount,
        bytes32 fundingOrderId,
        uint256 eurGrossAmount,
        uint48 expiresAt
    ) private returns (uint256 lotId) {
        CreditLot[] storage lots = s.creditLots[account];
        if (lots.length >= MAX_ACTIVE_CREDIT_LOTS) {
            _compactLots(s, account);
            if (lots.length >= MAX_ACTIVE_CREDIT_LOTS) revert CreditLotLimitExceeded();
        }

        lotId = _appendLotUnchecked(s, account, creditAmount, fundingOrderId, eurGrossAmount, expiresAt);
    }

    /// @dev Restore a refund into the exact source lot recorded by the allocation.
    ///      The lot ID remains stable even when compaction moves the array entry.
    function _restoreRefundToSourceLot(
        AppStorage storage s,
        address account,
        uint256 sourceLotId,
        uint256 refundAmount,
        uint256 refundEurGrossAmount
    ) private returns (bool restored) {
        CreditLot[] storage lots = s.creditLots[account];
        for (uint256 i; i < lots.length;) {
            CreditLot storage lot = lots[i];
            if (lot.lotId == sourceLotId) {
                uint256 eurRemaining = _remainingEurGrossAmount(s, lot);
                lot.remaining += refundAmount;
                s.creditLotRemainingEurGrossAmount[sourceLotId] = eurRemaining + refundEurGrossAmount;
                s.creditLotRemainingEurGrossAmountInitialized[sourceLotId] = true;
                if (i < s.creditLotCursor[account]) s.creditLotCursor[account] = i;
                return true;
            }
            unchecked {
                ++i;
            }
        }
    }

    /// @dev Legacy fallback for allocations written before source lot IDs were
    /// recorded. It is intentionally isolated from the current refund path.
    function _restoreLegacyRefundToExistingLot(
        AppStorage storage s,
        address account,
        uint256 refundAmount,
        bytes32 fundingOrderId,
        uint256 refundEurGrossAmount,
        uint48 expiresAt
    ) private returns (bool restored) {
        CreditLot[] storage lots = s.creditLots[account];
        for (uint256 i; i < lots.length;) {
            CreditLot storage lot = lots[i];
            uint256 lotEurGrossAmount = _remainingEurGrossAmount(s, lot);
            if (_lotCanMergeRefund(
                    lot, lotEurGrossAmount, refundAmount, fundingOrderId, refundEurGrossAmount, expiresAt
                )) {
                lot.remaining += refundAmount;
                lot.creditAmount += refundAmount;
                lot.eurGrossAmount += refundEurGrossAmount;
                s.creditLotRemainingEurGrossAmount[lot.lotId] = lotEurGrossAmount + refundEurGrossAmount;
                s.creditLotRemainingEurGrossAmountInitialized[lot.lotId] = true;
                return true;
            }
            unchecked {
                ++i;
            }
        }
    }

    function _lotCanMergeRefund(
        CreditLot storage lot,
        uint256 lotEurGrossAmount,
        uint256 refundAmount,
        bytes32 fundingOrderId,
        uint256 refundEurGrossAmount,
        uint48 expiresAt
    ) private view returns (bool) {
        if (
            lot.expired || lot.remaining == 0 || lot.fundingOrderId != fundingOrderId || lot.expiresAt != expiresAt
                || (lot.expiresAt != 0 && lot.expiresAt <= block.timestamp)
        ) {
            return false;
        }
        if (lotEurGrossAmount == 0 || refundEurGrossAmount == 0) {
            return lotEurGrossAmount == refundEurGrossAmount;
        }

        uint256 gcdLot = _gcd(lotEurGrossAmount, lot.remaining);
        uint256 gcdRefund = _gcd(refundEurGrossAmount, refundAmount);
        return lotEurGrossAmount / gcdLot == refundEurGrossAmount / gcdRefund
            && lot.remaining / gcdLot == refundAmount / gcdRefund;
    }

    function _releaseRefundReference(
        AppStorage storage s,
        address account,
        bytes32 reservationRef,
        uint256 allocationIndex,
        uint256 lotId
    ) private returns (bool released) {
        if (s.creditReservationAllocationReferenceReleased[account][reservationRef][allocationIndex]) return false;

        s.creditReservationAllocationReferenceReleased[account][reservationRef][allocationIndex] = true;
        uint256 referenceCount = s.creditLotRefundReferences[lotId];
        if (referenceCount == 0) return false;

        unchecked {
            --s.creditLotRefundReferences[lotId];
        }
        return true;
    }

    function _requireReservationAllocationsOpen(
        AppStorage storage s,
        address account,
        bytes32 reservationRef
    ) private view {
        if (s.creditReservationAllocationsFinalized[account][reservationRef]) {
            revert ReservationAllocationsFinalized();
        }
    }

    function _appendLotUnchecked(
        AppStorage storage s,
        address account,
        uint256 creditAmount,
        bytes32 fundingOrderId,
        uint256 eurGrossAmount,
        uint48 expiresAt
    ) private returns (uint256 lotId) {
        if (s.creditLots[account].length >= MAX_ACTIVE_CREDIT_LOTS) revert CreditLotLimitExceeded();

        lotId = s.creditLotNextId++;
        s.creditLots[account].push(
            CreditLot({
                lotId: lotId,
                fundingOrderId: fundingOrderId,
                creditAmount: creditAmount,
                remaining: creditAmount,
                eurGrossAmount: eurGrossAmount,
                issuedAt: uint48(block.timestamp),
                expiresAt: expiresAt,
                expired: false
            })
        );
        s.creditLotRemainingEurGrossAmount[lotId] = eurGrossAmount;
        s.creditLotRemainingEurGrossAmountInitialized[lotId] = true;
    }

    function _compactLots(
        AppStorage storage s,
        address account
    ) private {
        CreditLot[] storage lots = s.creditLots[account];
        uint256 writeIndex;
        uint256 totalBalance = s.serviceCreditBalance[account];
        uint256 lockedBalance = s.creditLockedBalance[account];
        uint256 availableBalance = totalBalance >= lockedBalance ? totalBalance - lockedBalance : 0;

        for (uint256 i; i < lots.length;) {
            CreditLot storage lot = lots[i];
            uint256 remaining = lot.remaining;
            bool expired = lot.expired || (lot.expiresAt != 0 && lot.expiresAt <= block.timestamp);
            bool hasPendingRefund = s.creditLotRefundReferences[lot.lotId] > 0;

            if (remaining == 0) {
                if (hasPendingRefund) {
                    if (writeIndex != i) lots[writeIndex] = lots[i];
                    uint256 preservedEur = _remainingEurGrossAmount(s, lots[writeIndex]);
                    s.creditLotRemainingEurGrossAmount[lots[writeIndex].lotId] = preservedEur;
                    s.creditLotRemainingEurGrossAmountInitialized[lots[writeIndex].lotId] = true;
                    unchecked {
                        ++writeIndex;
                    }
                }
                unchecked {
                    ++i;
                }
                continue;
            }

            if (expired && availableBalance >= remaining) {
                availableBalance -= remaining;
                totalBalance -= remaining;
                s.serviceCreditBalance[account] = totalBalance;
                lot.remaining = 0;
                lot.expired = true;
                s.creditLotRemainingEurGrossAmount[lot.lotId] = 0;
                s.creditLotRemainingEurGrossAmountInitialized[lot.lotId] = true;
                _recordMovement(s, account, CreditMovementKind.EXPIRE, remaining, lot.fundingOrderId);
                if (hasPendingRefund) {
                    if (writeIndex != i) lots[writeIndex] = lots[i];
                    unchecked {
                        ++writeIndex;
                    }
                }
                unchecked {
                    ++i;
                }
                continue;
            }

            if (writeIndex != i) lots[writeIndex] = lots[i];
            uint256 eurRemaining = s.creditLotRemainingEurGrossAmount[lots[writeIndex].lotId];
            if (!s.creditLotRemainingEurGrossAmountInitialized[lots[writeIndex].lotId] && eurRemaining == 0) {
                eurRemaining = lots[writeIndex].eurGrossAmount;
            }
            s.creditLotRemainingEurGrossAmount[lots[writeIndex].lotId] = eurRemaining;
            s.creditLotRemainingEurGrossAmountInitialized[lots[writeIndex].lotId] = true;
            unchecked {
                ++writeIndex;
                ++i;
            }
        }

        while (lots.length > writeIndex) lots.pop();
        s.serviceCreditBalance[account] = totalBalance;

        for (uint256 i; i < lots.length;) {
            CreditLot storage baseLot = lots[i];
            uint256 baseEur = _remainingEurGrossAmount(s, baseLot);
            uint256 j = i + 1;
            while (j < lots.length) {
                CreditLot storage candidate = lots[j];
                if (_lotsCanMerge(s, baseLot, baseEur, candidate, _remainingEurGrossAmount(s, candidate))) {
                    baseLot.remaining += candidate.remaining;
                    baseLot.creditAmount += candidate.creditAmount;
                    baseLot.eurGrossAmount += candidate.eurGrossAmount;
                    baseEur += _remainingEurGrossAmount(s, candidate);
                    s.creditLotRemainingEurGrossAmount[baseLot.lotId] = baseEur;
                    s.creditLotRemainingEurGrossAmountInitialized[baseLot.lotId] = true;
                    if (candidate.issuedAt < baseLot.issuedAt) baseLot.issuedAt = candidate.issuedAt;
                    _removeLotAt(s, account, j);
                } else {
                    unchecked {
                        ++j;
                    }
                }
            }
            unchecked {
                ++i;
            }
        }

        s.creditLotCursor[account] = 0;
    }

    function _removeLotAt(
        AppStorage storage s,
        address account,
        uint256 index
    ) private {
        CreditLot[] storage lots = s.creditLots[account];
        uint256 len = lots.length;
        for (uint256 i = index; i + 1 < len;) {
            lots[i] = lots[i + 1];
            uint256 eurRemaining = s.creditLotRemainingEurGrossAmount[lots[i].lotId];
            if (!s.creditLotRemainingEurGrossAmountInitialized[lots[i].lotId] && eurRemaining == 0) {
                eurRemaining = lots[i].eurGrossAmount;
            }
            s.creditLotRemainingEurGrossAmount[lots[i].lotId] = eurRemaining;
            s.creditLotRemainingEurGrossAmountInitialized[lots[i].lotId] = true;
            unchecked {
                ++i;
            }
        }
        lots.pop();
    }

    function _remainingEurGrossAmount(
        AppStorage storage s,
        CreditLot storage lot
    ) private view returns (uint256 eurRemaining) {
        eurRemaining = s.creditLotRemainingEurGrossAmount[lot.lotId];
        if (!s.creditLotRemainingEurGrossAmountInitialized[lot.lotId] && eurRemaining == 0) {
            eurRemaining = lot.eurGrossAmount;
        }
    }

    function _lotsCanMerge(
        AppStorage storage s,
        CreditLot storage a,
        uint256 eurA,
        CreditLot storage b,
        uint256 eurB
    ) private view returns (bool) {
        if (
            a.expired || b.expired || s.creditLotRefundReferences[a.lotId] > 0
                || s.creditLotRefundReferences[b.lotId] > 0 || a.fundingOrderId != b.fundingOrderId
                || a.expiresAt != b.expiresAt
        ) {
            return false;
        }
        if (a.remaining == 0 || b.remaining == 0) return false;
        if (a.expiresAt != 0 && a.expiresAt <= block.timestamp) return false;
        if (eurA == 0 || eurB == 0) return eurA == eurB;

        uint256 gcdA = _gcd(eurA, a.remaining);
        uint256 gcdB = _gcd(eurB, b.remaining);
        return eurA / gcdA == eurB / gcdB && a.remaining / gcdA == b.remaining / gcdB;
    }

    function _gcd(
        uint256 a,
        uint256 b
    ) private pure returns (uint256) {
        while (b != 0) {
            uint256 remainder = a % b;
            a = b;
            b = remainder;
        }
        return a;
    }

    function _advanceLotCursor(
        AppStorage storage s,
        address account
    ) private {
        CreditLot[] storage lots = s.creditLots[account];
        s.creditLotCursor[account] = _nextActiveLotIndex(lots, s.creditLotCursor[account], lots.length);
    }

    function _nextActiveLotIndex(
        CreditLot[] storage lots,
        uint256 index,
        uint256 len
    ) private view returns (uint256) {
        while (index < len) {
            CreditLot storage lot = lots[index];
            if (!lot.expired && lot.remaining > 0 && (lot.expiresAt == 0 || lot.expiresAt > block.timestamp)) {
                break;
            }
            unchecked {
                ++index;
            }
        }
        return index;
    }

    function _effectiveBalance(
        CreditLot[] storage lots
    ) private view returns (uint256 total) {
        for (uint256 i; i < lots.length;) {
            CreditLot storage lot = lots[i];
            if (!lot.expired && lot.remaining > 0 && (lot.expiresAt == 0 || lot.expiresAt > block.timestamp)) {
                total += lot.remaining;
            }
            unchecked {
                ++i;
            }
        }
    }

    function _earliestExpiryForAmount(
        CreditLot[] storage lots,
        uint256 cursor,
        uint256 amount
    ) private view returns (uint48 earliestExpiry) {
        uint256 remaining = amount;
        for (uint256 i = cursor; i < lots.length && remaining > 0;) {
            CreditLot storage lot = lots[i];
            if (!lot.expired && lot.remaining > 0 && (lot.expiresAt == 0 || lot.expiresAt > block.timestamp)) {
                uint256 take = lot.remaining < remaining ? lot.remaining : remaining;
                remaining -= take;
                if (lot.expiresAt != 0 && (earliestExpiry == 0 || lot.expiresAt < earliestExpiry)) {
                    earliestExpiry = lot.expiresAt;
                }
            }
            unchecked {
                ++i;
            }
        }
    }

    /// @dev Record a credit movement for audit trail
    function _recordMovement(
        AppStorage storage s,
        address account,
        CreditMovementKind kind,
        uint256 amount,
        bytes32 ref
    ) private {
        s.creditMovements[account].push(
            CreditMovement({
                kind: kind,
                amount: amount,
                balanceAfter: s.serviceCreditBalance[account],
                lockedAfter: s.creditLockedBalance[account],
                ref: ref,
                timestamp: uint48(block.timestamp)
            })
        );
    }
}
