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

    function test_technical_denial_reason_does_not_penalize_lab_reputation() public {
        uint256 labId = 78;
        uint32 start = uint32(block.timestamp + 1 days);
        bytes32 key = keccak256(abi.encodePacked("provider-technical-denial", labId, start));

        harness.setOwner(labId, provider);
        harness.setReservation(key, user1, _PENDING, labId, start);

        vm.expectEmit(true, true, false, true);
        emit ReservationRequestDenied(key, labId, 6);

        vm.prank(provider);
        harness.denyReservationRequestWithReason(key, 6);

        (int32 score, uint32 totalEvents, uint32 ownerCancellations,) = harness.getLabReputation(labId);
        assertEq(harness.getReservationStatus(key), _CANCELLED);
        assertEq(score, 0);
        assertEq(totalEvents, 0);
        assertEq(ownerCancellations, 0);
    }

    function test_authorized_provider_backend_can_deny_pending_request() public {
        uint256 labId = 79;
        uint32 start = uint32(block.timestamp + 1 days);
        bytes32 key = keccak256(abi.encodePacked("provider-backend-denial", labId, start));
        address providerBackend = address(0xBEEF);

        harness.setOwner(labId, provider);
        harness.setBackend(provider, providerBackend);
        harness.setReservation(key, user1, _PENDING, labId, start);

        vm.prank(providerBackend);
        harness.denyReservationRequestWithReason(key, 6);

        assertEq(harness.getReservationStatus(key), _CANCELLED);
    }

    function test_payer_cannot_deny_external_request() public {
        uint256 labId = 80;
        uint32 start = uint32(block.timestamp + 1 days);
        bytes32 key = keccak256(abi.encodePacked("payer-denial", labId, start));

        harness.setOwner(labId, provider);
        harness.setReservation(key, user1, _PENDING, labId, start);

        vm.prank(user1);
        vm.expectRevert();
        harness.denyReservationRequest(key);

        assertEq(harness.getReservationStatus(key), _PENDING);
    }

    event ReservationRequestDenied(bytes32 indexed reservationKey, uint256 indexed tokenId, uint8 reason);
}
