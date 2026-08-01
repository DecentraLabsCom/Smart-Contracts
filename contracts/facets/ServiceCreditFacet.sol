// SPDX-License-Identifier: GPL-3.0-or-later
pragma solidity ^0.8.33;

import {EnumerableSet} from "@openzeppelin/contracts/utils/structs/EnumerableSet.sol";
import {
    AppStorage,
    LibAppStorage,
    CreditLot,
    CreditMovement,
    CreditReservationAllocation
} from "../libraries/LibAppStorage.sol";
import {LibCreditLedger} from "../libraries/LibCreditLedger.sol";

contract ServiceCreditFacet {
    using EnumerableSet for EnumerableSet.AddressSet;

    // ── Lot lifecycle events (8.3.B audit trail) ─────────────────────────
    event CreditLotMinted(
        address indexed account,
        uint256 indexed lotId,
        uint256 creditAmount,
        uint256 eurGrossAmount,
        bytes32 fundingOrderId,
        uint48 expiresAt
    );
    event CreditLotConsumed(address indexed account, uint256 amount, bytes32 indexed reservationRef);
    event CreditLotReleased(address indexed account, uint256 amount, bytes32 indexed reservationRef);
    event CreditLotExpired(address indexed account, uint256 indexed lotIndex, uint256 expiredAmount);
    event CreditLotAdjusted(address indexed account, int256 delta, uint256 newBalance, bytes32 indexed adjustmentRef);
    event CreditsLocked(address indexed account, uint256 amount, bytes32 indexed reservationRef);
    event CreditsCancelled(address indexed account, uint256 amount, bytes32 indexed reservationRef);

    modifier onlyDefaultAdminRole() {
        AppStorage storage s = LibAppStorage.diamondStorage();
        require(s.roleMembers[s.DEFAULT_ADMIN_ROLE].contains(msg.sender), "Only admin");
        _;
    }

    // ═══════════════════════════════════════════════════════════════════════
    //  Credit Ledger API (8.3.A — lot-based, lock/capture model)
    // ═══════════════════════════════════════════════════════════════════════

    // ── Write operations ─────────────────────────────────────────────────

    /// @notice Mint credits into a new funding lot with full traceability
    /// @param account Recipient address
    /// @param creditAmount Amount of credits to issue
    /// @param fundingOrderId External funding order reference
    /// @param eurGrossAmount EUR gross amount that funded this lot (euro cents, informational)
    /// @param expiresAt Expiry timestamp (0 = no expiry)
    /// @return lotId The ID of the newly created lot
    function mintCredits(
        address account,
        uint256 creditAmount,
        bytes32 fundingOrderId,
        uint256 eurGrossAmount,
        uint48 expiresAt
    ) external onlyDefaultAdminRole returns (uint256 lotId) {
        lotId = LibCreditLedger.mintCredits(account, creditAmount, fundingOrderId, eurGrossAmount, expiresAt);
        emit CreditLotMinted(account, lotId, creditAmount, eurGrossAmount, fundingOrderId, expiresAt);
    }

    /// @notice Lock credits for a pending reservation
    /// @param account The account whose credits to lock
    /// @param amount Amount to lock
    /// @param reservationRef Reservation key for traceability
    function lockCredits(
        address account,
        uint256 amount,
        bytes32 reservationRef
    ) external onlyDefaultAdminRole {
        LibCreditLedger.lockCredits(account, amount, reservationRef);
        emit CreditsLocked(account, amount, reservationRef);
    }

    /// @notice Capture previously locked credits (consume FIFO from lots)
    /// @param account The account whose locked credits to capture
    /// @param amount Amount to capture
    /// @param reservationRef Reservation key for traceability
    function captureLockedCredits(
        address account,
        uint256 amount,
        bytes32 reservationRef
    ) external onlyDefaultAdminRole {
        LibCreditLedger.captureLockedCredits(account, amount, reservationRef);
        emit CreditLotConsumed(account, amount, reservationRef);
    }

    /// @notice Release previously locked credits back to available
    /// @param account The account whose locked credits to release
    /// @param amount Amount to release
    /// @param reservationRef Reservation key for traceability
    function releaseLockedCredits(
        address account,
        uint256 amount,
        bytes32 reservationRef
    ) external onlyDefaultAdminRole {
        LibCreditLedger.releaseLockedCredits(account, amount, reservationRef);
        emit CreditLotReleased(account, amount, reservationRef);
    }

    /// @notice Refund credits back to an account (e.g. post-confirmation cancellation)
    /// @param account The account to refund
    /// @param amount Amount to refund
    /// @param reservationRef Reservation key for traceability
    function cancelCredits(
        address account,
        uint256 amount,
        bytes32 reservationRef
    ) external onlyDefaultAdminRole {
        LibCreditLedger.cancelCredits(account, amount, reservationRef);
        emit CreditsCancelled(account, amount, reservationRef);
    }

    /// @notice Refund a bounded batch of source allocations.
    /// @dev Use the returned cursor to continue a legacy reservation whose
    ///      allocation list is larger than one transaction can process.
    function cancelCreditsBatch(
        address account,
        uint256 amount,
        bytes32 reservationRef,
        uint256 maxAllocations
    ) external onlyDefaultAdminRole returns (uint256 refundedAmount, uint256 nextCursor, bool complete) {
        (refundedAmount, nextCursor, complete) =
            LibCreditLedger.cancelCreditsBatch(account, amount, reservationRef, maxAllocations);
        if (refundedAmount > 0) emit CreditsCancelled(account, refundedAmount, reservationRef);
    }

    /// @notice Compact an account's spent/expired lots and merge compatible lots.
    function compactCreditLots(
        address account
    ) external onlyDefaultAdminRole returns (uint256 previousLength, uint256 compactedLength) {
        return LibCreditLedger.compactCreditLots(account);
    }

    /// @notice Expire a specific lot and deduct remaining balance
    /// @param account The account owning the lot
    /// @param lotIndex Index in the account's creditLots array
    /// @return expiredAmount The amount that was expired
    function expireCredits(
        address account,
        uint256 lotIndex
    ) external onlyDefaultAdminRole returns (uint256 expiredAmount) {
        expiredAmount = LibCreditLedger.expireLot(account, lotIndex);
        if (expiredAmount > 0) {
            emit CreditLotExpired(account, lotIndex, expiredAmount);
        }
    }

    /// @notice Administrative credit adjustment with lot tracking
    /// @param account The account to adjust
    /// @param delta Signed adjustment amount (positive or negative)
    /// @param adjustmentRef External reference for audit trail
    /// @return newBalance The new total balance after adjustment
    function ledgerAdjustCredits(
        address account,
        int256 delta,
        bytes32 adjustmentRef
    ) external onlyDefaultAdminRole returns (uint256 newBalance) {
        newBalance = LibCreditLedger.adjustCredits(account, delta, adjustmentRef);
        emit CreditLotAdjusted(account, delta, newBalance, adjustmentRef);
    }

    // ── Read operations ──────────────────────────────────────────────────

    /// @notice Available (unlocked) credits for an account
    function availableBalanceOf(
        address account
    ) external view returns (uint256) {
        return LibCreditLedger.availableBalanceOf(account);
    }

    /// @notice Locked credits for an account
    function lockedBalanceOf(
        address account
    ) external view returns (uint256) {
        return LibCreditLedger.lockedBalanceOf(account);
    }

    /// @notice Total credits for an account (available + locked)
    function totalBalanceOf(
        address account
    ) external view returns (uint256) {
        return LibCreditLedger.totalBalanceOf(account);
    }

    /// @notice Get paginated credit lots for an account
    /// @param account The account to query
    /// @param offset Starting index
    /// @param limit Maximum lots to return (capped at 50)
    /// @return lots Array of CreditLot structs
    /// @return total Total number of lots for the account
    function getCreditLots(
        address account,
        uint256 offset,
        uint256 limit
    ) external view returns (CreditLot[] memory lots, uint256 total) {
        AppStorage storage s = LibAppStorage.diamondStorage();
        CreditLot[] storage storedLots = s.creditLots[account];
        total = storedLots.length;
        if (offset >= total) return (new CreditLot[](0), total);

        uint256 end = offset + limit;
        if (end > total) end = total;
        if (limit > 50) {
            end = offset + 50;
            if (end > total) end = total;
        }

        lots = new CreditLot[](end - offset);
        for (uint256 i = offset; i < end;) {
            lots[i - offset] = storedLots[i];
            unchecked {
                ++i;
            }
        }
    }

    /// @notice Get paginated credit movements for an account
    /// @param account The account to query
    /// @param offset Starting index
    /// @param limit Maximum movements to return (capped at 50)
    /// @return movements Array of CreditMovement structs
    /// @return total Total number of movements for the account
    function getCreditMovements(
        address account,
        uint256 offset,
        uint256 limit
    ) external view returns (CreditMovement[] memory movements, uint256 total) {
        AppStorage storage s = LibAppStorage.diamondStorage();
        CreditMovement[] storage storedMovements = s.creditMovements[account];
        total = storedMovements.length;
        if (offset >= total) return (new CreditMovement[](0), total);

        uint256 end = offset + limit;
        if (end > total) end = total;
        if (limit > 50) {
            end = offset + 50;
            if (end > total) end = total;
        }

        movements = new CreditMovement[](end - offset);
        for (uint256 i = offset; i < end;) {
            movements[i - offset] = storedMovements[i];
            unchecked {
                ++i;
            }
        }
    }

    /// @notice Get paginated source-lot allocations for a reservation.
    /// @dev Allocations retain original funding and EUR provenance; refunded
    ///      amounts are exposed separately for reconciliation.
    function getCreditReservationAllocations(
        address account,
        bytes32 reservationRef,
        uint256 offset,
        uint256 limit
    ) external view returns (CreditReservationAllocation[] memory allocations, uint256 total) {
        total = LibCreditLedger.reservationAllocationCount(account, reservationRef);
        if (offset >= total) return (new CreditReservationAllocation[](0), total);

        uint256 end = offset + limit;
        if (end > total) end = total;
        if (limit > 50) {
            end = offset + 50;
            if (end > total) end = total;
        }

        allocations = new CreditReservationAllocation[](end - offset);
        for (uint256 i = offset; i < end;) {
            allocations[i - offset] = LibCreditLedger.getReservationAllocation(account, reservationRef, i);
            unchecked {
                ++i;
            }
        }
    }
}
