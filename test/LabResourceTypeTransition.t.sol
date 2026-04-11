// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.33;

import "forge-std/Test.sol";
import "./BaseTest.sol";
import "./Harnesses.sol";
import "../contracts/libraries/LibAppStorage.sol";

/// @title Lab Resource Type Transition Tests
/// @notice Ensures resourceType transitions cannot break booking invariants.
contract LabResourceTypeTransitionTest is BaseTest {
    LabAdminResourceTypeHarness internal harness;

    address internal constant LAB_OWNER = address(0xABCD);
    uint256 internal constant LAB_ID = 101;
    uint32 internal constant CREATED_AT = 123_456;

    function setUp() public override {
        super.setUp();
        harness = new LabAdminResourceTypeHarness();
    }

    function test_updateLab_reverts_resource_type_change_with_active_reservations() public {
        harness.seedLab(LAB_ID, LAB_OWNER, 1, CREATED_AT);
        harness.setActiveReservationCount(LAB_ID, 1);

        vm.prank(LAB_OWNER);
        vm.expectRevert("Cannot change resource type with active bookings");
        harness.updateLab(LAB_ID, "new-uri", 10, "new-access", "new-key", 0);

        LabBase memory lab = harness.getLabBase(LAB_ID);
        assertEq(lab.resourceType, 1);
    }

    function test_updateLab_reverts_resource_type_change_with_pending_provider_payout() public {
        harness.seedLab(LAB_ID, LAB_OWNER, 0, CREATED_AT);
        harness.setPendingProviderPayout(LAB_ID, 1);

        vm.prank(LAB_OWNER);
        vm.expectRevert("Cannot change resource type with active bookings");
        harness.updateLab(LAB_ID, "new-uri", 10, "new-access", "new-key", 1);

        LabBase memory lab = harness.getLabBase(LAB_ID);
        assertEq(lab.resourceType, 0);
    }

    function test_updateLab_allows_resource_type_change_without_active_bookings() public {
        harness.seedLab(LAB_ID, LAB_OWNER, 1, CREATED_AT);

        vm.prank(LAB_OWNER);
        harness.updateLab(LAB_ID, "new-uri", 10, "new-access", "new-key", 0);

        LabBase memory lab = harness.getLabBase(LAB_ID);
        assertEq(lab.resourceType, 0);
        assertEq(lab.createdAt, CREATED_AT);
        assertEq(lab.uri, "new-uri");
    }

    function test_updateLab_allows_metadata_update_with_active_bookings_if_type_unchanged() public {
        harness.seedLab(LAB_ID, LAB_OWNER, 1, CREATED_AT);
        harness.setActiveReservationCount(LAB_ID, 2);

        vm.prank(LAB_OWNER);
        harness.updateLab(LAB_ID, "updated-uri", 42, "updated-access", "updated-key", 1);

        LabBase memory lab = harness.getLabBase(LAB_ID);
        assertEq(lab.resourceType, 1);
        assertEq(lab.createdAt, CREATED_AT);
        assertEq(lab.price, 42);
        assertEq(lab.uri, "updated-uri");
        assertEq(lab.accessURI, "updated-access");
        assertEq(lab.accessKey, "updated-key");
    }
}
