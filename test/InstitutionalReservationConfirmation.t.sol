// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.33;

import "forge-std/Test.sol";
import "./BaseTest.sol";
import "./Harnesses.sol";
import "../contracts/libraries/LibAppStorage.sol";

contract ConfirmBoundaryHarness is ConfirmHarness {
    function setRequestPeriod(
        bytes32 key,
        uint64 periodStart,
        uint64 periodDuration
    ) external {
        AppStorage storage s = LibAppStorage.diamondStorage();
        s.reservations[key].requestPeriodStart = periodStart;
        s.reservations[key].requestPeriodDuration = periodDuration;
    }
}

contract InstitutionalReservationConfirmationTest is BaseTest {
    ConfirmBoundaryHarness public harness;

    uint8 internal constant _PENDING = 0;
    uint8 internal constant _CONFIRMED = 1;

    function setUp() public override {
        super.setUp();
        harness = new ConfirmBoundaryHarness();
    }

    function test_confirm_with_puc_success() public {
        address inst = address(0x2222);
        uint256 labId = 99;
        uint32 start = 1234;
        bytes32 key = keccak256(abi.encodePacked(labId, start));
        string memory puc = "charlie@inst";
        uint96 price = 50;

        harness.setReservation(key, user1, inst, price, _PENDING, labId, start, puc);
        harness.setOwner(labId, provider);
        harness.setInstitutionRole(inst);
        harness.setBackend(inst, address(0x0));

        // make sure provider can fulfill
        harness.setTokenStatus(labId, true);
        harness.setProviderActive(provider);

        vm.prank(provider);
        harness.confirmInstitutionalReservationRequestWithPucHash(inst, key, keccak256(bytes(puc)));

        assertEq(harness.getReservationStatus(key), _CONFIRMED);
        assertEq(harness.lastSpentAmount(), uint256(price));
        assertEq(harness.lastGenericSpentAmount(), 0);
        (uint96 storedPrice, uint96 providerShare) = harness.getReservationEconomics(key);
        assertEq(storedPrice, price);
        assertEq(providerShare, 35);
    }

    function test_confirm_zero_price_same_institution_spends_two_credits() public {
        address inst = address(0x2222);
        uint256 labId = 107;
        uint32 start = 1234;
        bytes32 key = keccak256(abi.encodePacked(labId, start));
        string memory puc = "same-institution@inst";

        harness.setReservation(key, user1, inst, 0, _PENDING, labId, start, puc);
        harness.setOwner(labId, inst);
        harness.setInstitutionRole(inst);
        harness.setTokenStatus(labId, true);
        harness.setProviderActive(inst);

        vm.prank(inst);
        harness.confirmInstitutionalReservationRequestWithPucHash(inst, key, keccak256(bytes(puc)));

        assertEq(harness.getReservationStatus(key), _CONFIRMED);
        assertEq(harness.lastSpentAmount(), 0);
        assertEq(harness.lastGenericSpentInstitution(), inst);
        assertEq(harness.lastGenericSpentAmount(), 20_000_000);
        (uint96 storedPrice, uint96 providerShare) = harness.getReservationEconomics(key);
        assertEq(storedPrice, 0);
        assertEq(providerShare, 0);
    }

    function test_confirm_zero_price_cross_institution_spends_one_credit() public {
        address inst = address(0x2222);
        uint256 labId = 108;
        uint32 start = 1234;
        bytes32 key = keccak256(abi.encodePacked(labId, start));
        string memory puc = "cross-institution@inst";

        harness.setReservation(key, user1, inst, 0, _PENDING, labId, start, puc);
        harness.setOwner(labId, provider);
        harness.setInstitutionRole(inst);
        harness.setTokenStatus(labId, true);
        harness.setProviderActive(provider);

        vm.prank(provider);
        harness.confirmInstitutionalReservationRequestWithPucHash(inst, key, keccak256(bytes(puc)));

        assertEq(harness.getReservationStatus(key), _CONFIRMED);
        assertEq(harness.lastSpentAmount(), 0);
        assertEq(harness.lastGenericSpentInstitution(), inst);
        assertEq(harness.lastGenericSpentAmount(), 10_000_000);
        (uint96 storedPrice, uint96 providerShare) = harness.getReservationEconomics(key);
        assertEq(storedPrice, 0);
        assertEq(providerShare, 0);
    }

    function test_lab_price_change_after_creation_does_not_change_paid_reservation_economics() public {
        address inst = address(0x2222);
        uint256 labId = 109;
        uint32 start = 1234;
        bytes32 key = keccak256(abi.encodePacked(labId, start));
        string memory puc = "price-change-paid@inst";
        uint96 reservationPrice = 50;

        harness.setReservation(key, user1, inst, reservationPrice, _PENDING, labId, start, puc);
        harness.setOwner(labId, provider);
        harness.setLabPrice(labId, 999);
        harness.setInstitutionRole(inst);
        harness.setTokenStatus(labId, true);
        harness.setProviderActive(provider);

        vm.prank(provider);
        harness.confirmInstitutionalReservationRequestWithPucHash(inst, key, keccak256(bytes(puc)));

        assertEq(harness.lastSpentAmount(), reservationPrice);
        (uint96 storedPrice, uint96 providerShare) = harness.getReservationEconomics(key);
        assertEq(storedPrice, reservationPrice);
        assertEq(providerShare, 35);
    }

    function test_lab_price_change_after_creation_does_not_change_cross_free_reservation_economics() public {
        address inst = address(0x2222);
        uint256 labId = 110;
        uint32 start = 1234;
        bytes32 key = keccak256(abi.encodePacked(labId, start));
        string memory puc = "price-change-free@inst";

        harness.setReservation(key, user1, inst, 0, _PENDING, labId, start, puc);
        harness.setOwner(labId, provider);
        harness.setLabPrice(labId, 999);
        harness.setInstitutionRole(inst);
        harness.setTokenStatus(labId, true);
        harness.setProviderActive(provider);

        vm.prank(provider);
        harness.confirmInstitutionalReservationRequestWithPucHash(inst, key, keccak256(bytes(puc)));

        assertEq(harness.lastSpentAmount(), 0);
        assertEq(harness.lastGenericSpentAmount(), 10_000_000);
        (uint96 storedPrice, uint96 providerShare) = harness.getReservationEconomics(key);
        assertEq(storedPrice, 0);
        assertEq(providerShare, 0);
    }

    function test_institutional_fixed_fee_is_not_refunded_on_same_institution_cancellation() public {
        ReservationLifecycleHarness lifecycle = new ReservationLifecycleHarness();
        address inst = address(0x2222);
        address backend = address(0xBEEF);
        uint256 labId = 111;
        uint32 start = 1_000_100;
        bytes32 key = keccak256(abi.encodePacked(labId, start));
        string memory puc = "cancel-fixed-same@inst";

        lifecycle.setReservation(key, user1, inst, 0, _PENDING, labId, start, puc);
        lifecycle.setOwner(labId, inst);
        lifecycle.setBackend(inst, backend);
        lifecycle.setInstitutionRole(inst);
        lifecycle.setTokenStatus(labId, true);
        lifecycle.setProviderActive(inst);

        vm.warp(1_000_000);
        vm.prank(inst);
        lifecycle.confirmInstitutionalReservationRequestWithPucHash(inst, key, keccak256(bytes(puc)));
        assertEq(lifecycle.lastGenericSpentAmount(), 20_000_000);

        vm.prank(backend);
        lifecycle.cancelInstitutionalBookingWithPucHash(inst, key, keccak256(bytes(puc)));

        assertEq(lifecycle.lastRefundAmount(), 0);
    }

    function test_institutional_fixed_fee_is_not_refunded_on_cross_free_cancellation() public {
        ReservationLifecycleHarness lifecycle = new ReservationLifecycleHarness();
        address inst = address(0x2222);
        address backend = address(0xBEEF);
        uint256 labId = 112;
        uint32 start = 1_000_100;
        bytes32 key = keccak256(abi.encodePacked(labId, start));
        string memory puc = "cancel-fixed-cross@inst";

        lifecycle.setReservation(key, user1, inst, 0, _PENDING, labId, start, puc);
        lifecycle.setOwner(labId, provider);
        lifecycle.setBackend(inst, backend);
        lifecycle.setInstitutionRole(inst);
        lifecycle.setTokenStatus(labId, true);
        lifecycle.setProviderActive(provider);

        vm.warp(1_000_000);
        vm.prank(provider);
        lifecycle.confirmInstitutionalReservationRequestWithPucHash(inst, key, keccak256(bytes(puc)));
        assertEq(lifecycle.lastGenericSpentAmount(), 10_000_000);

        vm.prank(backend);
        lifecycle.cancelInstitutionalBookingWithPucHash(inst, key, keccak256(bytes(puc)));

        assertEq(lifecycle.lastRefundAmount(), 0);
    }

    function test_payer_cannot_confirm_external_reservation() public {
        address inst = address(0x2222);
        uint256 labId = 100;
        uint32 start = 1234;
        bytes32 key = keccak256(abi.encodePacked(labId, start));
        string memory puc = "external@inst";

        harness.setReservation(key, user1, inst, 50, _PENDING, labId, start, puc);
        harness.setOwner(labId, provider);
        harness.setInstitutionRole(inst);
        harness.setTokenStatus(labId, true);
        harness.setProviderActive(provider);

        vm.prank(inst);
        vm.expectRevert();
        harness.confirmInstitutionalReservationRequestWithPucHash(inst, key, keccak256(bytes(puc)));
    }

    function test_confirm_succeeds_one_second_before_start() public {
        address inst = address(0x2222);
        uint256 labId = 101;
        string memory puc = "before-start@inst";
        vm.warp(1_000_000);
        uint32 start = uint32(block.timestamp + 100);
        bytes32 key = keccak256(abi.encodePacked(labId, start));

        _preparePendingReservation(inst, labId, start, start + 60, key, puc);
        vm.warp(uint256(start) - 1);

        vm.prank(provider);
        harness.confirmInstitutionalReservationRequestWithPucHash(inst, key, keccak256(bytes(puc)));

        assertEq(harness.getReservationStatus(key), _CONFIRMED);
    }

    function test_confirm_cancels_exactly_at_start() public {
        address inst = address(0x2222);
        uint256 labId = 102;
        string memory puc = "at-start@inst";
        vm.warp(1_000_000);
        uint32 start = uint32(block.timestamp + 100);
        bytes32 key = keccak256(abi.encodePacked(labId, start));

        _preparePendingReservation(inst, labId, start, start + 60, key, puc);
        vm.warp(start);

        vm.prank(provider);
        harness.confirmInstitutionalReservationRequestWithPucHash(inst, key, keccak256(bytes(puc)));

        assertEq(harness.getReservationStatus(key), 4);
        assertEq(harness.lastSpentAmount(), 0);
    }

    function test_confirm_cancels_one_second_after_start() public {
        address inst = address(0x2222);
        uint256 labId = 103;
        string memory puc = "after-start@inst";
        vm.warp(1_000_000);
        uint32 start = uint32(block.timestamp + 100);
        bytes32 key = keccak256(abi.encodePacked(labId, start));

        _preparePendingReservation(inst, labId, start, start + 60, key, puc);
        vm.warp(uint256(start) + 1);

        vm.prank(provider);
        harness.confirmInstitutionalReservationRequestWithPucHash(inst, key, keccak256(bytes(puc)));

        assertEq(harness.getReservationStatus(key), 4);
        assertEq(harness.lastSpentAmount(), 0);
    }

    function test_confirm_cancels_after_end() public {
        address inst = address(0x2222);
        uint256 labId = 104;
        string memory puc = "after-end@inst";
        vm.warp(1_000_000);
        uint32 start = uint32(block.timestamp + 100);
        uint32 end = start + 60;
        bytes32 key = keccak256(abi.encodePacked(labId, start));

        _preparePendingReservation(inst, labId, start, end, key, puc);
        vm.warp(uint256(end) + 1);

        vm.prank(provider);
        harness.confirmInstitutionalReservationRequestWithPucHash(inst, key, keccak256(bytes(puc)));

        assertEq(harness.getReservationStatus(key), 4);
        assertEq(harness.lastSpentAmount(), 0);
    }

    function test_confirm_cancels_when_ttl_expires_before_start() public {
        address inst = address(0x2222);
        uint256 labId = 105;
        string memory puc = "ttl-first@inst";
        vm.warp(1_000_000);
        uint64 requestStart = uint64(block.timestamp);
        uint32 start = uint32(block.timestamp + 100);
        bytes32 key = keccak256(abi.encodePacked(labId, start));

        _preparePendingReservation(inst, labId, start, start + 60, key, puc);
        harness.setRequestPeriod(key, requestStart, 10);
        vm.warp(uint256(requestStart) + 10);

        vm.prank(provider);
        harness.confirmInstitutionalReservationRequestWithPucHash(inst, key, keccak256(bytes(puc)));

        assertEq(harness.getReservationStatus(key), 4);
        assertEq(harness.lastSpentAmount(), 0);
    }

    function test_listener_retry_after_start_cannot_confirm_cancelled_request() public {
        address inst = address(0x2222);
        uint256 labId = 106;
        string memory puc = "listener-retry@inst";
        vm.warp(1_000_000);
        uint32 start = uint32(block.timestamp + 100);
        bytes32 key = keccak256(abi.encodePacked(labId, start));

        _preparePendingReservation(inst, labId, start, start + 60, key, puc);
        vm.warp(uint256(start) + 1);

        vm.prank(provider);
        harness.confirmInstitutionalReservationRequestWithPucHash(inst, key, keccak256(bytes(puc)));
        assertEq(harness.getReservationStatus(key), 4);

        vm.prank(provider);
        vm.expectRevert();
        harness.confirmInstitutionalReservationRequestWithPucHash(inst, key, keccak256(bytes(puc)));
    }

    function _preparePendingReservation(
        address inst,
        uint256 labId,
        uint32 start,
        uint32 end,
        bytes32 key,
        string memory puc
    ) private {
        harness.setReservationWithEnd(key, user1, inst, 50, _PENDING, labId, start, end, puc);
        harness.setOwner(labId, provider);
        harness.setInstitutionRole(inst);
        harness.setBackend(inst, address(0));
        harness.setTokenStatus(labId, true);
        harness.setProviderActive(provider);
        harness.setRequestPeriod(key, uint64(block.timestamp), 5 minutes);
    }
}
