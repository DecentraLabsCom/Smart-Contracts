// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.33;

import "forge-std/Test.sol";
import "./BaseTest.sol";
import "./Harnesses.sol";

contract ProviderCancellationReputationTest is BaseTest {
    ReservationDenialHarness public harness;

    uint8 internal constant _PENDING = 0;
    uint8 internal constant _CANCELLED = 4;

    function setUp() public override {
        super.setUp();
        harness = new ReservationDenialHarness();
    }

    function test_provider_manual_denial_penalizes_lab_reputation() public {
        uint256 labId = 77;
        uint32 start = uint32(block.timestamp + 1 days);
        bytes32 key = keccak256(abi.encodePacked("provider-denial", labId, start));

        harness.setOwner(labId, provider);
        harness.setReservation(key, user1, _PENDING, labId, start);

        vm.prank(provider);
        harness.denyReservationRequest(key);

        (int32 score, uint32 totalEvents, uint32 ownerCancellations,) = harness.getLabReputation(labId);
        assertEq(harness.getReservationStatus(key), _CANCELLED);
        assertEq(score, -1);
        assertEq(totalEvents, 1);
        assertEq(ownerCancellations, 1);
    }
}
