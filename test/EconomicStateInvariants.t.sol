// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.33;

import {Test} from "forge-std/Test.sol";
import {EnumerableSet} from "@openzeppelin/contracts/utils/structs/EnumerableSet.sol";
import {ProviderSettlementFacet} from "../contracts/facets/reservation/ProviderSettlementFacet.sol";
import {
    AppStorage,
    CreditLot,
    LibAppStorage,
    Reservation,
    ProviderSettlementBatch
} from "../contracts/libraries/LibAppStorage.sol";
import {LibCreditLedger} from "../contracts/libraries/LibCreditLedger.sol";
import {LibProviderReceivable} from "../contracts/libraries/LibProviderReceivable.sol";

/// @notice Stateful handler for the lot-backed service-credit ledger.
/// @dev The handler only performs valid, bounded operations. The invariant
///      suite then checks the storage-level conservation properties after
///      arbitrary sequences of those operations.
contract CreditLedgerInvariantHandler {
    address internal constant ACCOUNT = address(0xC0ED17);
    bytes32 internal constant RESERVATION_REF = keccak256("economic-invariant-reservation");
    uint256 internal constant MAX_OPERATION_AMOUNT = 1e18;

    uint256 public refundableCapturedAmount;

    function mint(
        uint256 rawAmount
    ) external {
        // Keep room for compaction while allowing the invariant runner to
        // exercise the production lot limit and its normal steady state.
        if (LibCreditLedger.lotCount(ACCOUNT) >= 120) return;
        LibCreditLedger.mintCredits(
            ACCOUNT,
            _boundedAmount(rawAmount),
            keccak256(abi.encode("invariant-funding", rawAmount, LibCreditLedger.movementCount(ACCOUNT))),
            rawAmount % MAX_OPERATION_AMOUNT,
            0
        );
    }

    function lock(
        uint256 rawAmount
    ) external {
        uint256 available = LibCreditLedger.availableBalanceOf(ACCOUNT);
        if (available == 0) return;
        LibCreditLedger.lockCredits(ACCOUNT, _boundedAmount(rawAmount, available), RESERVATION_REF);
    }

    function release(
        uint256 rawAmount
    ) external {
        uint256 locked = LibCreditLedger.lockedBalanceOf(ACCOUNT);
        if (locked == 0) return;
        LibCreditLedger.releaseLockedCredits(ACCOUNT, _boundedAmount(rawAmount, locked), RESERVATION_REF);
    }

    function capture(
        uint256 rawAmount
    ) external {
        uint256 locked = LibCreditLedger.lockedBalanceOf(ACCOUNT);
        if (locked == 0) return;
        // Keep each capture within one source lot and within the production
        // allocation bound, so reverts represent only genuine state guards.
        if (LibCreditLedger.reservationAllocationCount(ACCOUNT, RESERVATION_REF) >= 4) return;
        uint256 sourceLotRemaining;
        uint256 lots = LibCreditLedger.lotCount(ACCOUNT);
        for (uint256 i; i < lots; ++i) {
            CreditLot memory lot = LibCreditLedger.getLot(ACCOUNT, i);
            if (!lot.expired && lot.remaining > 0) {
                sourceLotRemaining = lot.remaining;
                break;
            }
        }
        if (sourceLotRemaining == 0) return;
        uint256 maxCapture = locked < sourceLotRemaining ? locked : sourceLotRemaining;
        uint256 amount = _boundedAmount(rawAmount, maxCapture);
        LibCreditLedger.captureLockedCredits(ACCOUNT, amount, RESERVATION_REF);
        refundableCapturedAmount += amount;
    }

    function refund(
        uint256 rawAmount
    ) external {
        if (refundableCapturedAmount == 0) return;
        uint256 amount = _boundedAmount(rawAmount, refundableCapturedAmount);
        LibCreditLedger.cancelCredits(ACCOUNT, amount, RESERVATION_REF);
        refundableCapturedAmount -= amount;
    }

    function compact() external {
        LibCreditLedger.compactCreditLots(ACCOUNT);
    }

    function totalBalance() external view returns (uint256) {
        return LibCreditLedger.totalBalanceOf(ACCOUNT);
    }

    function availableBalance() external view returns (uint256) {
        return LibCreditLedger.availableBalanceOf(ACCOUNT);
    }

    function lockedBalance() external view returns (uint256) {
        return LibCreditLedger.lockedBalanceOf(ACCOUNT);
    }

    function lotCount() external view returns (uint256) {
        return LibCreditLedger.lotCount(ACCOUNT);
    }

    function lotRemaining(
        uint256 index
    ) external view returns (uint256) {
        CreditLot memory lot = LibCreditLedger.getLot(ACCOUNT, index);
        return lot.remaining;
    }

    function movementCount() external view returns (uint256) {
        return LibCreditLedger.movementCount(ACCOUNT);
    }

    function movementSnapshot(
        uint256 index
    ) external view returns (uint256 balanceAfter, uint256 lockedAfter) {
        return (
            LibCreditLedger.getMovement(ACCOUNT, index).balanceAfter,
            LibCreditLedger.getMovement(ACCOUNT, index).lockedAfter
        );
    }

    function _boundedAmount(
        uint256 rawAmount
    ) internal pure returns (uint256) {
        return _boundedAmount(rawAmount, MAX_OPERATION_AMOUNT);
    }

    function _boundedAmount(
        uint256 rawAmount,
        uint256 maximum
    ) internal pure returns (uint256) {
        return rawAmount % maximum + 1;
    }
}

/// @notice Test-only settlement handler that uses the same batch lifecycle
///      and invalidation entry points as the production facet.
contract ProviderSettlementInvariantHandler is ProviderSettlementFacet {
    using EnumerableSet for EnumerableSet.AddressSet;

    uint256 internal constant LAB_ID = 7;
    uint256 internal constant MAX_OPERATION_AMOUNT = 1e18;
    address internal constant SOURCE_ACCOUNT = address(0xCAFE);

    bytes32[] private batchIds;
    uint256 public totalAccruedAmount;
    uint256 private batchNonce;
    uint256 private resolutionNonce;

    constructor() {
        AppStorage storage s = LibAppStorage.diamondStorage();
        s.DEFAULT_ADMIN_ROLE = keccak256("DEFAULT_ADMIN_ROLE");
        s.roleMembers[s.DEFAULT_ADMIN_ROLE].add(address(this));
    }

    function queue(
        uint256 rawAmount
    ) external {
        uint256 amount = rawAmount % MAX_OPERATION_AMOUNT + 1;
        bytes32 reservationId = keccak256(abi.encode("invariant-source", ++batchNonce, rawAmount));

        AppStorage storage s = LibAppStorage.diamondStorage();
        Reservation storage reservation = s.reservations[reservationId];
        reservation.labId = LAB_ID;
        reservation.renter = SOURCE_ACCOUNT;
        reservation.status = 3;

        LibProviderReceivable.accrueReceivable(LAB_ID, amount, reservationId);
        bytes32 batchId = _createProviderSettlementBatch(s, LAB_ID, amount);

        s.providerReceivableAccrued[LAB_ID] -= amount;
        s.providerSettlementQueue[LAB_ID] += amount;
        batchIds.push(batchId);
        totalAccruedAmount += amount;
    }

    function dispute(
        uint256 rawIndex
    ) external {
        if (batchIds.length == 0) return;
        bytes32 batchId = batchIds[rawIndex % batchIds.length];
        if (LibAppStorage.diamondStorage().providerSettlementBatches[batchId].status != 1) return;
        this.disputeSettlementBatch(batchId, _resolutionReference(batchId, rawIndex));
    }

    function reverse(
        uint256 rawIndex
    ) external {
        if (batchIds.length == 0) return;
        bytes32 batchId = batchIds[rawIndex % batchIds.length];
        uint8 status = LibAppStorage.diamondStorage().providerSettlementBatches[batchId].status;
        if (status != 1 && status != 3) return;
        this.reverseSettlementBatch(batchId, _resolutionReference(batchId, rawIndex));
    }

    function batchCount() external view returns (uint256) {
        return batchIds.length;
    }

    function batchAt(
        uint256 index
    ) external view returns (bytes32 batchId, uint256 totalAmount, uint256 remainingAmount, uint8 status) {
        batchId = batchIds[index];
        ProviderSettlementBatch storage batch = LibAppStorage.diamondStorage().providerSettlementBatches[batchId];
        return (batchId, batch.totalAmount, batch.remainingAmount, batch.status);
    }

    function lifecycle()
        external
        view
        returns (
            uint256 accrued,
            uint256 queued,
            uint256 invoiced,
            uint256 approved,
            uint256 paid,
            uint256 reversed,
            uint256 disputed
        )
    {
        AppStorage storage s = LibAppStorage.diamondStorage();
        return (
            s.providerReceivableAccrued[LAB_ID],
            s.providerSettlementQueue[LAB_ID],
            s.providerReceivableInvoiced[LAB_ID],
            s.providerReceivableApproved[LAB_ID],
            s.providerReceivablePaid[LAB_ID],
            s.providerReceivableReversed[LAB_ID],
            s.providerReceivableDisputed[LAB_ID]
        );
    }

    function _resolutionReference(
        bytes32 batchId,
        uint256 rawIndex
    ) internal returns (bytes32) {
        return keccak256(abi.encode("invariant-resolution", batchId, ++resolutionNonce, rawIndex));
    }
}

contract CreditLedgerEconomicInvariantTest is Test {
    CreditLedgerInvariantHandler internal handler;

    function setUp() public {
        handler = new CreditLedgerInvariantHandler();
        bytes4[] memory selectors = new bytes4[](5);
        selectors[0] = CreditLedgerInvariantHandler.mint.selector;
        selectors[1] = CreditLedgerInvariantHandler.lock.selector;
        selectors[2] = CreditLedgerInvariantHandler.release.selector;
        selectors[3] = CreditLedgerInvariantHandler.capture.selector;
        selectors[4] = CreditLedgerInvariantHandler.refund.selector;
        targetSelector(FuzzSelector({addr: address(handler), selectors: selectors}));
    }

    function invariant_creditLedgerConservesLotBackedBalance() external view {
        uint256 total = handler.totalBalance();
        uint256 available = handler.availableBalance();
        uint256 locked = handler.lockedBalance();
        assertEq(total, available + locked);

        uint256 lotBackedBalance;
        uint256 lots = handler.lotCount();
        for (uint256 i; i < lots; ++i) {
            lotBackedBalance += handler.lotRemaining(i);
        }
        assertEq(lotBackedBalance, total);
    }

    function invariant_creditLedgerMovementSnapshotsRemainOrdered() external view {
        uint256 movements = handler.movementCount();
        for (uint256 i; i < movements; ++i) {
            (uint256 balanceAfter, uint256 lockedAfter) = handler.movementSnapshot(i);
            assertLe(lockedAfter, balanceAfter);
        }
    }
}

contract ProviderSettlementEconomicInvariantTest is Test {
    ProviderSettlementInvariantHandler internal handler;

    function setUp() public {
        handler = new ProviderSettlementInvariantHandler();
        bytes4[] memory selectors = new bytes4[](3);
        selectors[0] = ProviderSettlementInvariantHandler.queue.selector;
        selectors[1] = ProviderSettlementInvariantHandler.dispute.selector;
        selectors[2] = ProviderSettlementInvariantHandler.reverse.selector;
        targetSelector(FuzzSelector({addr: address(handler), selectors: selectors}));
    }

    function invariant_providerSettlementBucketsConserveAccruedValue() external view {
        (
            uint256 accrued,
            uint256 queued,
            uint256 invoiced,
            uint256 approved,
            uint256 paid,
            uint256 reversed,
            uint256 disputed
        ) = handler.lifecycle();

        assertEq(accrued + queued + invoiced + approved + paid + reversed + disputed, handler.totalAccruedAmount());

        uint256 batches = handler.batchCount();
        uint256 batchTotal;
        for (uint256 i; i < batches; ++i) {
            (, uint256 totalAmount, uint256 remainingAmount, uint8 status) = handler.batchAt(i);
            batchTotal += totalAmount;
            if (status == 1) {
                assertEq(remainingAmount, totalAmount);
            } else if (status == 3 || status == 4) {
                assertEq(remainingAmount, 0);
            }
        }
        assertEq(batchTotal, handler.totalAccruedAmount());
    }
}
