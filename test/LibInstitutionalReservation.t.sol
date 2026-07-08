// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.33;

import "forge-std/Test.sol";
import "./BaseTest.sol";
import "./Harnesses.sol";
import "../contracts/libraries/LibAppStorage.sol";
import "../contracts/libraries/LibRevenue.sol";

contract LibInstitutionalReservationTest is BaseTest {
    InstReservationHarness public harness;

    uint8 internal constant _PENDING = 0;
    uint8 internal constant _CONFIRMED = 1;
    uint8 internal constant _ACCESS_AUTHORIZED = 2;
    uint8 internal constant _SETTLED = 3;
    uint8 internal constant _CANCELLED = 4;

    function setUp() public override {
        super.setUp();
        harness = new InstReservationHarness();
    }

    function test_cancelReservationRequest_success() public {
        address inst = address(0xABCD);
        address backend = address(0xBEEF);
        uint256 labId = 42;
        uint32 start = 1000;
        bytes32 key = keccak256(abi.encodePacked(labId, start));
        string memory puc = "user@inst.example";

        // set backend and reservation
        harness.setBackend(inst, backend);
        harness.setReservation(key, user1, inst, 0, _PENDING, labId, start, puc);

        vm.prank(backend);
        uint256 returned = harness.cancelReservationRequestWrapper(inst, keccak256(bytes(puc)), key);

        assertEq(returned, labId);

        assertEq(harness.getReservationStatus(key), _CANCELLED);
    }

    function test_cancelReservationRequest_does_not_penalize_lab_reputation() public {
        address inst = address(0xABCD);
        address backend = address(0xBEEF);
        uint256 labId = 42;
        uint32 start = 1000;
        bytes32 key = keccak256(abi.encodePacked("pending-user-cancel", labId, start));
        string memory puc = "user@inst.example";

        harness.setBackend(inst, backend);
        harness.setReservation(key, user1, inst, 0, _PENDING, labId, start, puc);

        vm.prank(backend);
        harness.cancelReservationRequestWrapper(inst, keccak256(bytes(puc)), key);

        (int32 score, uint32 totalEvents, uint32 ownerCancellations,) = harness.getLabReputation(labId);
        assertEq(score, 0);
        assertEq(totalEvents, 0);
        assertEq(ownerCancellations, 0);
    }

    function test_cancelBooking_refund() public {
        address inst = address(0xCAFE);
        address backend = address(0xF00D);
        uint256 labId = 7;
        uint32 start = 2000;
        bytes32 key = keccak256(abi.encodePacked(labId, start));
        string memory puc = "alice@inst";
        uint96 price = 1_000_000;

        harness.setBackend(inst, backend);
        harness.setReservation(key, user1, inst, price, _CONFIRMED, labId, start, puc);

        vm.prank(backend);
        uint256 returned = harness.cancelBookingWrapper(inst, keccak256(bytes(puc)), key);
        assertEq(returned, labId);

        (uint96 providerFee, uint96 refundAmount) = LibRevenue.computeCancellationFee(price);
        assertEq(harness.lastRefundAmount(), refundAmount);
        assertEq(harness.lastRefundProvider(), inst);
    }

    function test_cancelBooking_unauthorized_reverts() public {
        address inst = address(0x1111);
        uint256 labId = 8;
        uint32 start = 3000;
        bytes32 key = keccak256(abi.encodePacked(labId, start));
        string memory puc = "bob@inst";

        harness.setReservation(key, user1, inst, 0, _CONFIRMED, labId, start, puc);

        vm.expectRevert();
        harness.cancelBookingWrapper(inst, keccak256(bytes(puc)), key);
    }

    function test_cancelBooking_accessAuthorized_reverts() public {
        address inst = address(0xCAFE);
        address backend = address(0xF00D);
        uint256 labId = 11;
        uint32 start = 5000;
        bytes32 key = keccak256(abi.encodePacked(labId, start));
        string memory puc = "eve@inst";

        harness.setBackend(inst, backend);
        harness.setReservation(key, user1, inst, 1_000_000, _ACCESS_AUTHORIZED, labId, start, puc);

        vm.prank(backend);
        vm.expectRevert();
        harness.cancelBookingWrapper(inst, keccak256(bytes(puc)), key);
    }

    function test_releaseInstitutionalExpiredReservations_accessAuthorizedWithoutSessionStarted_doesNotRewardReputation()
        public
    {
        vm.warp(10_000);
        address inst = address(0xCAFE);
        address backend = address(0xF00D);
        uint256 labId = 13;
        uint32 start = uint32(block.timestamp - 7200);
        uint32 end = uint32(block.timestamp - 3600);
        bytes32 key = keccak256(abi.encodePacked("expired-without-session", labId, start));
        string memory puc = "sessionless@inst";
        bytes32 pucHash = keccak256(bytes(puc));

        harness.setInstitution(inst);
        harness.setBackend(inst, backend);
        harness.setIndexedExpiredReservation(key, user1, inst, 1_000_000, _ACCESS_AUTHORIZED, labId, start, end, puc);

        vm.prank(backend);
        uint256 processed = harness.releaseInstitutionalExpiredReservationsWrapper(inst, pucHash, labId, 10);

        assertEq(processed, 1);
        assertEq(harness.getReservationStatus(key), _SETTLED);
        (int32 score, uint32 totalEvents, uint32 ownerCancellations,) = harness.getLabReputation(labId);
        assertEq(score, 0);
        assertEq(totalEvents, 0);
        assertEq(ownerCancellations, 0);
    }

    function test_releaseInstitutionalExpiredReservations_accessAuthorizedWithSessionStarted_rewardsReputation()
        public
    {
        vm.warp(10_000);
        address inst = address(0xCAFE);
        address backend = address(0xF00D);
        uint256 labId = 14;
        uint32 start = uint32(block.timestamp - 7200);
        uint32 end = uint32(block.timestamp - 3600);
        bytes32 key = keccak256(abi.encodePacked("expired-with-session", labId, start));
        string memory puc = "started@inst";
        bytes32 pucHash = keccak256(bytes(puc));

        harness.setInstitution(inst);
        harness.setBackend(inst, backend);
        harness.setIndexedExpiredReservation(key, user1, inst, 1_000_000, _ACCESS_AUTHORIZED, labId, start, end, puc);
        harness.markSessionStartedForTest(key);

        vm.prank(backend);
        uint256 processed = harness.releaseInstitutionalExpiredReservationsWrapper(inst, pucHash, labId, 10);

        assertEq(processed, 1);
        assertEq(harness.getReservationStatus(key), _SETTLED);
        (int32 score, uint32 totalEvents, uint32 ownerCancellations,) = harness.getLabReputation(labId);
        assertEq(score, 1);
        assertEq(totalEvents, 1);
        assertEq(ownerCancellations, 0);
    }

    function test_cancelBooking_afterStart_reverts() public {
        address inst = address(0xCAFE);
        address backend = address(0xF00D);
        uint256 labId = 12;
        uint32 start = uint32(block.timestamp + 60);
        bytes32 key = keccak256(abi.encodePacked(labId, start));
        string memory puc = "mallory@inst";

        harness.setBackend(inst, backend);
        harness.setReservation(key, user1, inst, 1_000_000, _CONFIRMED, labId, start, puc);

        vm.warp(uint256(start));
        vm.prank(backend);
        vm.expectRevert();
        harness.cancelBookingWrapper(inst, keccak256(bytes(puc)), key);
    }
}
