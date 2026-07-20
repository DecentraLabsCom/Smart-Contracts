// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.33;

import "forge-std/Test.sol";
import "./Harnesses.sol";

contract LabAdminStopSellingTest is Test {
    LabAdminResourceTypeHarness harness;
    address provider = makeAddr("provider");

    function setUp() public {
        harness = new LabAdminResourceTypeHarness();
        harness.seedLab(1, provider, 0, uint32(block.timestamp));
    }

    function test_unlistStopsNewReservationsWithoutRequiringObligationsToSettle() public {
        vm.prank(provider);
        harness.listLab(1);
        harness.setActiveReservationCount(1, 1);

        vm.prank(provider);
        harness.unlistLab(1);

        assertFalse(harness.isListed(1));
        assertFalse(harness.isAcceptingNewReservations(1));
    }

    function test_unlistStillRequiresTheLabToBeListed() public {
        vm.prank(provider);
        vm.expectRevert("Lab not listed");
        harness.unlistLab(1);
    }
}
