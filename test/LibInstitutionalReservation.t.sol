// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.33;

import "forge-std/Test.sol";
import "./BaseTest.sol";
import "./Harnesses.sol";
import "../contracts/libraries/LibAppStorage.sol";
import "../contracts/libraries/LibRevenue.sol";
import "../contracts/libraries/LibTracking.sol";

contract LibInstitutionalReservationTest is BaseTest {
    InstReservationHarness public harness;

    uint8 internal constant _PENDING = 0;
    uint8 internal constant _CONFIRMED = 1;
    uint8 internal constant _ACCESS_AUTHORIZED = 2;
    uint8 internal constant _SETTLED = 3;
    uint8 internal constant _CANCELLED = 4;

    event BookingCanceledByProvider(
        bytes32 indexed reservationKey,
        uint256 indexed tokenId,
        address indexed payerInstitution,
        address provider,
        bytes32 pucHash,
        uint96 refundAmount,
        uint8 reasonCode
    );

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
        assertEq(harness.lastRefundAmount(), 1_000_000);
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
        assertEq(harness.providerReceivable(labId), 1_000_000);
    }

    function test_releaseInstitutionalExpiredReservations_allows_third_party_without_payer_backend() public {
        vm.warp(10_000);
        address inst = address(0xCAFE);
        address thirdParty = address(0xD00D);
        uint256 labId = 16;
        uint32 start = uint32(block.timestamp - 7200);
        uint32 end = uint32(block.timestamp - 3600);
        bytes32 key = keccak256(abi.encodePacked("expired-without-backend", labId, start));
        bytes32 pucHash = keccak256(bytes("orphaned-backend@inst"));

        harness.setInstitution(inst);
        harness.setIndexedExpiredReservation(
            key, user1, inst, 1_000_000, _ACCESS_AUTHORIZED, labId, start, end, "orphaned-backend@inst"
        );

        vm.prank(thirdParty);
        uint256 processed = harness.releaseInstitutionalExpiredReservationsWrapper(inst, pucHash, labId, 10);

        assertEq(processed, 1);
        assertEq(harness.getReservationStatus(key), _SETTLED);
        assertEq(harness.lastRefundAmount(), 1_000_000);
    }

    function test_releaseInstitutionalExpiredReservations_repairs_active_reservation_pointer() public {
        vm.warp(10_000);
        address inst = address(0xCAFE);
        address backend = address(0xF00D);
        uint256 labId = 15;
        string memory puc = "pointer@inst";
        bytes32 pucHash = keccak256(bytes(puc));
        uint32 firstStart = uint32(block.timestamp - 7200);
        uint32 secondStart = uint32(block.timestamp - 3600);
        bytes32 firstKey = keccak256(abi.encodePacked("pointer-first", labId, firstStart));
        bytes32 secondKey = keccak256(abi.encodePacked("pointer-second", labId, secondStart));

        harness.setInstitution(inst);
        harness.setBackend(inst, backend);
        harness.setIndexedExpiredReservation(
            firstKey, user1, inst, 1_000_000, _ACCESS_AUTHORIZED, labId, firstStart, firstStart + 300, puc
        );
        harness.setIndexedExpiredReservation(
            secondKey, user1, inst, 1_000_000, _ACCESS_AUTHORIZED, labId, secondStart, secondStart + 300, puc
        );

        vm.prank(backend);
        harness.releaseInstitutionalExpiredReservationsWrapper(inst, pucHash, labId, 1);

        bytes32 remainingKey = harness.getReservationStatus(firstKey) == _SETTLED ? secondKey : firstKey;
        assertEq(
            harness.getActiveReservationKey(labId, LibTracking.trackingKeyFromInstitutionHash(inst, pucHash)),
            remainingKey
        );
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

    function test_providerCancellation_refundsFullPrice_and_penalizes_reputation_softly() public {
        address payer = address(0xCAFE);
        address providerOwner = address(0xD00D);
        address providerBackend = address(0xB0B);
        uint256 labId = 21;
        uint32 start = uint32(block.timestamp + 1 days);
        bytes32 key = keccak256(abi.encodePacked("provider-cancel", labId, start));
        string memory puc = "provider-cancel-user@inst";
        uint96 price = 2_000_000;

        harness.setInstitution(payer);
        harness.setBackend(providerOwner, providerBackend);
        harness.setLabOwner(labId, providerOwner);
        harness.setReservation(key, user1, payer, price, _CONFIRMED, labId, start, puc);

        vm.expectEmit(true, true, true, true);
        emit BookingCanceledByProvider(key, labId, payer, providerOwner, keccak256(bytes(puc)), price, 7);

        vm.prank(providerBackend);
        (
            uint256 returnedLabId,
            address returnedPayer,
            address returnedProvider,
            bytes32 returnedPuc,
            uint96 refundAmount
        ) = harness.cancelConfirmedBookingByProvider(key, 7);

        assertEq(returnedLabId, labId);
        assertEq(returnedPayer, payer);
        assertEq(returnedProvider, providerOwner);
        assertEq(returnedPuc, keccak256(bytes(puc)));
        assertEq(refundAmount, price);
        assertEq(harness.getReservationStatus(key), _CANCELLED);
        assertEq(harness.lastRefundProvider(), payer);
        assertEq(harness.lastRefundAmount(), price);
        assertEq(harness.providerReceivable(labId), 0);

        (int32 score, uint32 totalEvents, uint32 ownerCancellations,) = harness.getLabReputation(labId);
        assertEq(score, -1);
        assertEq(totalEvents, 1);
        assertEq(ownerCancellations, 1);
    }

    function test_providerCancellation_rejects_afterCutoff_and_accessAuthorized() public {
        address payer = address(0xCAFE);
        address providerOwner = address(0xD00D);
        uint256 labId = 22;
        uint32 start = uint32(block.timestamp + 1 days);
        bytes32 key = keccak256(abi.encodePacked("provider-cancel-cutoff", labId, start));
        string memory puc = "provider-cancel-cutoff@inst";

        harness.setInstitution(payer);
        harness.setLabOwner(labId, providerOwner);
        harness.setBackend(providerOwner, providerOwner);
        harness.setReservation(key, user1, payer, 1_000_000, _ACCESS_AUTHORIZED, labId, start, puc);

        vm.prank(providerOwner);
        vm.expectRevert();
        harness.cancelConfirmedBookingByProvider(key, 7);

        harness.setReservation(key, user1, payer, 1_000_000, _CONFIRMED, labId, start, puc);
        vm.warp(start);
        vm.prank(providerOwner);
        vm.expectRevert();
        harness.cancelConfirmedBookingByProvider(key, 7);
    }

    function test_providerCancellation_rejects_reentrant_provider_cancellation() public {
        address providerOwner = address(harness);
        uint256 firstLabId = 31;
        uint256 reentrantLabId = 32;
        uint32 firstStart = uint32(block.timestamp + 1 days);
        uint32 reentrantStart = firstStart + 1 hours;
        bytes32 firstKey = keccak256(abi.encodePacked("provider-cancel-reentrancy", firstLabId, firstStart));
        bytes32 reentrantKey = keccak256(abi.encodePacked("provider-cancel-reentrancy", reentrantLabId, reentrantStart));

        harness.setLabOwner(firstLabId, providerOwner);
        harness.setLabOwner(reentrantLabId, providerOwner);
        harness.setReservation(firstKey, user1, address(0xCAFE), 2_000_000, _CONFIRMED, firstLabId, firstStart, "first");
        harness.setReservation(
            reentrantKey, user1, address(0xCAFE), 3_000_000, _CONFIRMED, reentrantLabId, reentrantStart, "reentrant"
        );
        harness.configureReentrancy(reentrantKey);

        vm.prank(providerOwner);
        vm.expectRevert();
        harness.cancelConfirmedBookingByProvider(firstKey, 7);

        assertEq(harness.getReservationStatus(firstKey), _CONFIRMED);
        assertEq(harness.getReservationStatus(reentrantKey), _CONFIRMED);
    }
}
