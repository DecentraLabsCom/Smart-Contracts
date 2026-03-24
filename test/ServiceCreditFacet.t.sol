// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.33;

import {EnumerableSet} from "@openzeppelin/contracts/utils/structs/EnumerableSet.sol";
import "./BaseTest.sol";
import "../contracts/facets/ServiceCreditFacet.sol";
import "../contracts/libraries/LibAppStorage.sol";
import "../contracts/libraries/LibServiceCredit.sol";

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

    function test_issueServiceCredits_requires_admin() public {
        vm.prank(user1);
        vm.expectRevert("Only admin");
        harness.issueServiceCredits(user2, 1, bytes32("funding"));
    }

    function test_issueServiceCredits_tracks_balance() public {
        vm.prank(owner);
        uint256 newBalance = harness.issueServiceCredits(user1, 750_000, bytes32("funding"));

        assertEq(newBalance, 750_000);
        assertEq(harness.getServiceCreditBalance(user1), 750_000);

        vm.prank(user1);
        assertEq(harness.getMyServiceCreditBalance(), 750_000);
    }

    function test_adjustServiceCredits_can_credit_and_debit() public {
        vm.startPrank(owner);
        harness.issueServiceCredits(user1, 1_000_000, bytes32("funding"));

        uint256 afterCredit = harness.adjustServiceCredits(user1, int256(250_000), bytes32("bonus"));
        uint256 afterDebit = harness.adjustServiceCredits(user1, -int256(400_000), bytes32("usage"));
        vm.stopPrank();

        assertEq(afterCredit, 1_250_000);
        assertEq(afterDebit, 850_000);
        assertEq(harness.getServiceCreditBalance(user1), 850_000);
    }

    function test_adjustServiceCredits_reverts_when_debit_exceeds_balance() public {
        vm.prank(owner);
        harness.issueServiceCredits(user1, 100_000, bytes32("funding"));

        vm.prank(owner);
        vm.expectRevert(LibServiceCredit.InsufficientServiceCredits.selector);
        harness.adjustServiceCredits(user1, -int256(100_001), bytes32("overdraw"));
    }
}
