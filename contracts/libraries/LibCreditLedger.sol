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

/// @title LibCreditLedger
/// @notice Lot-based credit ledger with lock/capture/release semantics for MiCA 4.3.d compliance
/// @dev All write operations record a CreditMovement entry for audit traceability.
///      Lot consumption follows FIFO order (oldest non-expired lot first).
///      Available balance is the unexpired lot-backed balance minus locked credits.
library LibCreditLedger {
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
        if (account == address(0)) revert ZeroAccount();
        if (amount == 0) revert ZeroAmount();

        AppStorage storage s = LibAppStorage.diamondStorage();

        s.serviceCreditBalance[account] += amount;

        CreditReservationAllocation[] storage allocations = s.creditReservationAllocations[account][reservationRef];
        if (allocations.length == 0) revert NoReservationAllocation();
        uint256 remainingToRefund = amount;
        for (uint256 i; i < allocations.length && remainingToRefund > 0;) {
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
                _appendLot(s, account, refundAmount, allocation.fundingOrderId, refundEur, allocation.expiresAt);
                remainingToRefund -= refundAmount;
            }
            unchecked {
                ++i;
            }
        }

        if (remainingToRefund != 0) revert RefundExceedsReservationAllocation();
        delete s.creditReservationExpiry[account][reservationRef];

        _recordMovement(s, account, CreditMovementKind.CANCEL, amount, reservationRef);
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
        return LibAppStorage.diamondStorage().creditReservationAllocations[account][reservationRef].length;
    }

    /// @notice Get one source-lot allocation recorded for a reservation.
    function getReservationAllocation(
        address account,
        bytes32 reservationRef,
        uint256 index
    ) internal view returns (CreditReservationAllocation memory) {
        return LibAppStorage.diamondStorage().creditReservationAllocations[account][reservationRef][index];
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
                uint256 eurRemaining = s.creditLotRemainingEurGrossAmount[lot.lotId];
                // Initialize the appended sidecar lazily for lots created before
                // this provenance mapping was introduced.
                if (eurRemaining == 0 && lot.eurGrossAmount > 0) {
                    eurRemaining = lot.eurGrossAmount;
                }
                uint256 eurTake = take == lotRemainingBefore ? eurRemaining : (eurRemaining * take) / lotRemainingBefore;

                lot.remaining -= take;
                s.creditLotRemainingEurGrossAmount[lot.lotId] = eurRemaining - eurTake;
                if (recordAllocation) {
                    s.creditReservationAllocations[account][reservationRef].push(
                        CreditReservationAllocation({
                            fundingOrderId: lot.fundingOrderId,
                            amount: take,
                            refundedAmount: 0,
                            eurGrossAmount: eurTake,
                            refundedEurGrossAmount: 0,
                            expiresAt: lot.expiresAt
                        })
                    );
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

    function _appendLot(
        AppStorage storage s,
        address account,
        uint256 creditAmount,
        bytes32 fundingOrderId,
        uint256 eurGrossAmount,
        uint48 expiresAt
    ) private returns (uint256 lotId) {
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
