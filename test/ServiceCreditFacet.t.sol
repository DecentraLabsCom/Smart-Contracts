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
}
