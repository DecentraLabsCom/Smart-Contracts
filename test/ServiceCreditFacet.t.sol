// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.33;

import {EnumerableSet} from "@openzeppelin/contracts/utils/structs/EnumerableSet.sol";
import "./BaseTest.sol";
import "../contracts/facets/ServiceCreditFacet.sol";
import "../contracts/libraries/LibAppStorage.sol";
import "../contracts/libraries/LibCreditLedger.sol";

contract ServiceCreditHarness is ServiceCreditFacet {
    using EnumerableSet for EnumerableSet.AddressSet;

    function seedDefaultAdmin(
        address account
    ) external {
        AppStorage storage s = LibAppStorage.diamondStorage();
        if (s.DEFAULT_ADMIN_ROLE == bytes32(0)) {
            s.DEFAULT_ADMIN_ROLE = keccak256("DEFAULT_ADMIN_ROLE");
        }
        s.roleMembers[s.DEFAULT_ADMIN_ROLE].add(account);
    }

    function reservationAllocationCount(
        address account,
        bytes32 reservationRef
    ) external view returns (uint256) {
        return LibAppStorage.diamondStorage().creditReservationAllocations[account][reservationRef].length;
    }
}

contract ServiceCreditFacetTest is BaseTest {
    ServiceCreditHarness internal harness;

    function setUp() public override {
        super.setUp();
        harness = new ServiceCreditHarness();
        harness.seedDefaultAdmin(owner);
    }

    function test_mintCredits_requires_admin() public {
        vm.prank(user1);
        vm.expectRevert("Only admin");
        harness.mintCredits(user2, 1, bytes32("funding"), 1, 0);
    }

    function test_mintCredits_tracks_lot_backed_balance() public {
        vm.prank(owner);
        uint256 lotId = harness.mintCredits(user1, 750_000, bytes32("funding"), 7500, 0);

        assertEq(lotId, 0);
        assertEq(harness.totalBalanceOf(user1), 750_000);
        assertEq(harness.availableBalanceOf(user1), 750_000);
    }

    function test_ledgerAdjustCredits_can_credit_and_debit() public {
        vm.startPrank(owner);
        harness.mintCredits(user1, 1_000_000, bytes32("funding"), 10_000, 0);

        uint256 afterCredit = harness.ledgerAdjustCredits(user1, int256(250_000), bytes32("bonus"));
        uint256 afterDebit = harness.ledgerAdjustCredits(user1, -int256(400_000), bytes32("usage"));
        vm.stopPrank();

        assertEq(afterCredit, 1_250_000);
        assertEq(afterDebit, 850_000);
        assertEq(harness.totalBalanceOf(user1), 850_000);
    }

    function test_ledgerAdjustCredits_reverts_when_debit_exceeds_balance() public {
        vm.prank(owner);
        harness.mintCredits(user1, 100_000, bytes32("funding"), 1000, 0);

        vm.prank(owner);
        vm.expectRevert(LibCreditLedger.InsufficientAvailableCredits.selector);
        harness.ledgerAdjustCredits(user1, -int256(100_001), bytes32("overdraw"));
    }

    function test_ledgerAdjustCredits_reverts_cleanly_when_balance_is_below_locked() public {
        vm.startPrank(owner);
        harness.mintCredits(user1, 100_000, bytes32("funding"), 1000, 0);
        harness.lockCredits(user1, 80_000, bytes32("reservation"));

        vm.expectRevert(LibCreditLedger.InsufficientAvailableCredits.selector);
        harness.ledgerAdjustCredits(user1, -int256(30_000), bytes32("overdraw-locked"));
        vm.stopPrank();
    }

    function test_compactCreditLots_merges_compatible_lots() public {
        bytes32 fundingOrder = keccak256("compatible-funding");

        vm.startPrank(owner);
        harness.mintCredits(user1, 100, fundingOrder, 95, 0);
        harness.mintCredits(user1, 200, fundingOrder, 190, 0);
        (uint256 previousLength, uint256 compactedLength) = harness.compactCreditLots(user1);
        vm.stopPrank();

        assertEq(previousLength, 2);
        assertEq(compactedLength, 1);
        assertEq(harness.totalBalanceOf(user1), 300);

        (CreditLot[] memory lots, uint256 total) = harness.getCreditLots(user1, 0, 10);
        assertEq(total, 1);
        assertEq(lots[0].remaining, 300);
        assertEq(lots[0].eurGrossAmount, 285);
    }

    function test_mintCredits_reverts_after_active_lot_bound() public {
        vm.startPrank(owner);
        for (uint256 i; i < 128; ++i) {
            harness.mintCredits(user1, 1, bytes32(i + 1), 0, 0);
        }

        vm.expectRevert(LibCreditLedger.CreditLotLimitExceeded.selector);
        harness.mintCredits(user1, 1, bytes32(uint256(129)), 0, 0);
        vm.stopPrank();
    }

    function test_captureLockedCredits_accepts_all_physical_source_lots() public {
        vm.startPrank(owner);
        for (uint256 i; i < 128; ++i) {
            harness.mintCredits(user1, 1, bytes32(i + 1), 0, 0);
        }
        bytes32 reservationRef = keccak256("allocation-cap");
        harness.lockCredits(user1, 128, reservationRef);
        harness.captureLockedCredits(user1, 128, reservationRef);
        vm.stopPrank();

        assertEq(harness.reservationAllocationCount(user1, reservationRef), 128);
        assertEq(harness.lockedBalanceOf(user1), 0);
        assertEq(harness.totalBalanceOf(user1), 0);
    }

    function test_cancelCreditsBatch_persists_cursor_for_large_legacy_refund() public {
        bytes32 reservationRef = keccak256("batched-refund");

        vm.startPrank(owner);
        for (uint256 i; i < 64; ++i) {
            harness.mintCredits(user1, 1, bytes32(i + 1), 0, 0);
        }
        harness.lockCredits(user1, 64, reservationRef);
        harness.captureLockedCredits(user1, 64, reservationRef);

        (uint256 firstRefund, uint256 cursor, bool complete) = harness.cancelCreditsBatch(user1, 64, reservationRef, 32);
        assertEq(firstRefund, 32);
        assertEq(cursor, 32);
        assertFalse(complete);
        assertEq(harness.totalBalanceOf(user1), 32);

        (uint256 secondRefund, uint256 finalCursor, bool finished) =
            harness.cancelCreditsBatch(user1, 32, reservationRef, 32);
        vm.stopPrank();

        assertEq(secondRefund, 32);
        assertEq(finalCursor, 64);
        assertTrue(finished);
        assertEq(harness.totalBalanceOf(user1), 64);
    }
}
