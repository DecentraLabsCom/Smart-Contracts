// SPDX-License-Identifier: GPL-3.0-or-later
pragma solidity ^0.8.33;

import {AppStorage, LibAppStorage, CreditLot, CreditMovement, CreditMovementKind} from "./LibAppStorage.sol";

/// @title LibCreditLedger
/// @notice Lot-based credit ledger with lock/capture/release semantics for MiCA 4.3.d compliance
/// @dev All write operations record a CreditMovement entry for audit traceability.
///      Lot consumption follows FIFO order (oldest non-expired lot first).
///      The available balance is: serviceCreditBalance[account] - creditLockedBalance[account].
library LibCreditLedger {
    error ZeroAccount();
    error ZeroAmount();
    error InsufficientAvailableCredits();
    error InsufficientLockedCredits();
    error LotExpired();
    error LotAlreadyExpired();
    error LotNotExpired();

    /// @notice Available (unlocked) credits for an account
    function availableBalanceOf(address account) internal view returns (uint256) {
        AppStorage storage s = LibAppStorage.diamondStorage();
        return s.serviceCreditBalance[account] - s.creditLockedBalance[account];
    }

    /// @notice Locked credits for an account (reserved for pending reservations)
    function lockedBalanceOf(address account) internal view returns (uint256) {
        return LibAppStorage.diamondStorage().creditLockedBalance[account];
    }

    /// @notice Total credits for an account (available + locked)
    function totalBalanceOf(address account) internal view returns (uint256) {
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

        AppStorage storage s = LibAppStorage.diamondStorage();

        lotId = s.creditLotNextId++;

        s.creditLots[account].push(CreditLot({
            lotId: lotId,
            fundingOrderId: fundingOrderId,
            creditAmount: creditAmount,
            remaining: creditAmount,
            eurGrossAmount: eurGrossAmount,
            issuedAt: uint48(block.timestamp),
            expiresAt: expiresAt,
            expired: false
        }));

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

        uint256 available = s.serviceCreditBalance[account] - s.creditLockedBalance[account];
        if (available < amount) revert InsufficientAvailableCredits();

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

        _consumeFromLots(s, account, amount);

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

        uint256 lotId = s.creditLotNextId++;
        s.creditLots[account].push(CreditLot({
            lotId: lotId,
            fundingOrderId: reservationRef,
            creditAmount: amount,
            remaining: amount,
            eurGrossAmount: 0,
            issuedAt: uint48(block.timestamp),
            expiresAt: 0,
            expired: false
        }));

        _recordMovement(s, account, CreditMovementKind.CANCEL, amount, reservationRef);
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

            uint256 lotId = s.creditLotNextId++;
            s.creditLots[account].push(CreditLot({
                lotId: lotId,
                fundingOrderId: adjustmentRef,
                creditAmount: amount,
                remaining: amount,
                eurGrossAmount: 0,
                issuedAt: uint48(block.timestamp),
                expiresAt: 0,
                expired: false
            }));

            _recordMovement(s, account, CreditMovementKind.ADJUST, amount, adjustmentRef);
            newBalance = s.serviceCreditBalance[account];
        } else {
            uint256 amount = uint256(-delta);
            uint256 available = s.serviceCreditBalance[account] - s.creditLockedBalance[account];
            if (available < amount) revert InsufficientAvailableCredits();

            s.serviceCreditBalance[account] -= amount;
            _consumeFromLots(s, account, amount);

            _recordMovement(s, account, CreditMovementKind.ADJUST, amount, adjustmentRef);
            newBalance = s.serviceCreditBalance[account];
        }
    }

    /// @notice Get the number of lots for an account
    function lotCount(address account) internal view returns (uint256) {
        return LibAppStorage.diamondStorage().creditLots[account].length;
    }

    /// @notice Get a specific lot by index
    function getLot(address account, uint256 index) internal view returns (CreditLot memory) {
        return LibAppStorage.diamondStorage().creditLots[account][index];
    }

    /// @notice Get the number of credit movements for an account
    function movementCount(address account) internal view returns (uint256) {
        return LibAppStorage.diamondStorage().creditMovements[account].length;
    }

    /// @notice Get a specific credit movement by index
    function getMovement(address account, uint256 index) internal view returns (CreditMovement memory) {
        return LibAppStorage.diamondStorage().creditMovements[account][index];
    }

    /// @dev Consume `amount` credits from lots FIFO (oldest first, skip expired)
    function _consumeFromLots(
        AppStorage storage s,
        address account,
        uint256 amount
    ) private {
        CreditLot[] storage lots = s.creditLots[account];
        uint256 remaining = amount;
        uint256 len = lots.length;
        uint256 cursor = s.creditLotCursor[account];

        for (uint256 i = cursor; i < len && remaining > 0; ) {
            CreditLot storage lot = lots[i];
            if (!lot.expired && lot.remaining > 0) {
                uint256 take = lot.remaining < remaining ? lot.remaining : remaining;
                lot.remaining -= take;
                remaining -= take;
            }
            unchecked {
                ++i;
            }
        }

        s.creditLotCursor[account] = _nextActiveLotIndex(lots, cursor, len);
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
            if (!lot.expired && lot.remaining > 0) {
                break;
            }
            unchecked {
                ++index;
            }
        }
        return index;
    }

    /// @dev Record a credit movement for audit trail
    function _recordMovement(
        AppStorage storage s,
        address account,
        CreditMovementKind kind,
        uint256 amount,
        bytes32 ref
    ) private {
        s.creditMovements[account].push(CreditMovement({
            kind: kind,
            amount: amount,
            balanceAfter: s.serviceCreditBalance[account],
            lockedAfter: s.creditLockedBalance[account],
            ref: ref,
            timestamp: uint48(block.timestamp)
        }));
    }
}
