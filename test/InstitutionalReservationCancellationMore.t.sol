// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.33;

import "forge-std/Test.sol";
import "./BaseTest.sol";
import "./Harnesses.sol";

contract RevertingInstReservationHarness2 {
    // minimal parts of InstReservationHarness behaviour required for tests
    using EnumerableSet for EnumerableSet.Bytes32Set;

    address public lastRefundProvider;

    function setBackend(
        address inst,
        address backend
    ) external {
        AppStorage storage _s = LibAppStorage.diamondStorage();
        _s.institutionalBackends[inst] = backend;
    }

    function setReservation(
        bytes32 key,
        address renter,
        address payerInstitution,
        uint96 price,
        uint8 status,
        uint256 labId,
        uint32 start,
        string calldata puc
    ) external {
        AppStorage storage _s = LibAppStorage.diamondStorage();
        Reservation storage r = _s.reservations[key];
        r.renter = renter;
        r.payerInstitution = payerInstitution;
        r.price = price;
        r.status = status;
        r.labId = labId;
        r.start = start;
        r.end = start + 3600;
        if (bytes(puc).length > 0) _s.reservationPucHash[key] = keccak256(bytes(puc));

        // set request period start/duration to a valid aligned period
        uint256 d = _s.institutionalSpendingPeriod[payerInstitution];
        if (d == 0) d = LibAppStorage.DEFAULT_SPENDING_PERIOD;
        uint256 rsAligned = block.timestamp - (block.timestamp % d);
        r.requestPeriodStart = uint64(rsAligned);
        r.requestPeriodDuration = uint64(d);
    }

    function cancelBookingWrapper(
        address institutionalProvider,
        bytes32 pucHash,
        bytes32 reservationKey
    ) external returns (uint256) {
        return LibInstitutionalReservation.cancelBooking(institutionalProvider, pucHash, reservationKey);
    }

    function refundToInstitutionalTreasuryForReservation(
        address,
        bytes32,
        bytes32,
        uint256
    ) external pure {
        revert("refund failed");
    }
}

contract InstitutionalReservationCancellationMoreTest is BaseTest {
    RevertingInstReservationHarness2 public revHarness;
    InstReservationHarness public harness;

    uint8 internal constant _PENDING = 0;
    uint8 internal constant _CONFIRMED = 1;
    uint8 internal constant _ACCESS_AUTHORIZED = 2;
    uint8 internal constant _CANCELLED = 4;

    function setUp() public override {
        super.setUp();
        harness = new InstReservationHarness();
        revHarness = new RevertingInstReservationHarness2();
    }

    function test_cancelReservationRequest_unauthorized_reverts() public {
        address inst = address(0xABCD);
        address backend = address(0xBEEF);
        uint256 labId = 42;
        uint32 start = 1000;
        bytes32 key = keccak256(abi.encodePacked(labId, start));
        string memory puc = "user@inst.example";

        // set backend and reservation but call from wrong sender
        harness.setBackend(inst, backend);
        harness.setReservation(key, user1, inst, 0, _PENDING, labId, start, puc);

        // no prank; msg.sender != backend should revert
        vm.expectRevert();
        harness.cancelReservationRequestWrapper(inst, keccak256(bytes(puc)), key);
    }

    function test_cancelBooking_invalid_status_reverts() public {
        // try to cancel booking when status is pending -> InvalidStatus
        address inst = address(0xCAFE);
        address backend = address(0xF00D);
        uint256 labId = 7;
        uint32 start = 2000;
        bytes32 key = keccak256(abi.encodePacked(labId, start));
        string memory puc = "alice@inst";
        uint96 price = 1_000_000;

        harness.setBackend(inst, backend);
        // set to PENDING instead of CONFIRMED
        harness.setReservation(key, user1, inst, price, _PENDING, labId, start, puc);

        vm.prank(backend);
        vm.expectRevert();
        harness.cancelBookingWrapper(inst, keccak256(bytes(puc)), key);
    }

    function test_cancelBooking_puc_mismatch_reverts() public {
        address inst = address(0xCAFE);
        address backend = address(0xF00D);
        uint256 labId = 7;
        uint32 start = 2000;
        bytes32 key = keccak256(abi.encodePacked(labId, start));
        string memory puc = "alice@inst";
        string memory wrong = "wrong@inst";
        uint96 price = 1_000_000;

        harness.setBackend(inst, backend);
        harness.setReservation(key, user1, inst, price, _CONFIRMED, labId, start, puc);

        vm.prank(backend);
        vm.expectRevert();
        harness.cancelBookingWrapper(inst, keccak256(bytes(wrong)), key);
    }

    function test_cancelBooking_refund_revert_bubbles() public {
        address inst = address(0xDEAD);
        address backend = address(0xB0B);
        uint256 labId = 9;
        uint32 start = 4000;
        bytes32 key = keccak256(abi.encodePacked(labId, start));
        string memory puc = "who@inst";
        uint96 price = 5000;

        // use revHarness so refundToInstitutionalTreasury reverts
        revHarness.setBackend(inst, backend);
        revHarness.setReservation(key, user1, inst, price, _CONFIRMED, labId, start, puc);

        vm.prank(backend);
        vm.expectRevert(bytes("refund failed"));
        revHarness.cancelBookingWrapper(inst, keccak256(bytes(puc)), key);
    }

    function test_cancelBooking_at_lot_limit_restores_consumer_refund() public {
        address inst = address(0xC001);
        address backend = address(0xB001);
        uint256 labId = 17;
        uint32 start = uint32(block.timestamp + 3600);
        bytes32 key = keccak256("consumer-lot-limit");
        string memory puc = "consumer@inst";
        uint96 price = 10_000_000;

        harness.setBackend(inst, backend);
        harness.setReservation(key, user1, inst, price, _CONFIRMED, labId, start, puc);
        harness.enableLedgerRefund();
        harness.seedCreditReservationAtLotLimit(inst, key, keccak256("consumer-source"), uint256(price) * 2, price);

        vm.prank(backend);
        harness.cancelBookingWrapper(inst, keccak256(bytes(puc)), key);

        assertEq(harness.getReservationStatus(key), _CANCELLED);
        assertEq(harness.creditLotCount(inst), 128);
        assertEq(harness.lastRefundAmount(), 9_000_000);
    }

    function test_providerCancellation_at_lot_limit_restores_full_refund() public {
        address inst = address(0xC002);
        address provider = address(0xB002);
        uint256 labId = 18;
        uint32 start = uint32(block.timestamp + 3600);
        bytes32 key = keccak256("provider-lot-limit");
        string memory puc = "provider@inst";
        uint96 price = 10_000_000;

        harness.setLabOwner(labId, provider);
        harness.setReservation(key, user1, inst, price, _CONFIRMED, labId, start, puc);
        harness.enableLedgerRefund();
        harness.seedCreditReservationAtLotLimit(inst, key, keccak256("provider-source"), uint256(price) * 2, price);

        vm.prank(provider);
        harness.cancelConfirmedBookingByProviderWrapper(key, 7);

        assertEq(harness.getReservationStatus(key), _CANCELLED);
        assertEq(harness.creditLotCount(inst), 128);
        assertEq(harness.lastRefundAmount(), price);
    }

    function test_consumerCancellation_with_maximum_gas_safe_allocations() public {
        address inst = address(0xC003);
        address backend = address(0xB003);
        uint256 labId = 19;
        bytes32 key = keccak256("consumer-terminal-gas-bound");
        string memory puc = "consumer-gas@inst";
        uint96 price = 4;

        harness.setBackend(inst, backend);
        harness.setReservation(key, user1, inst, price, _CONFIRMED, labId, uint32(block.timestamp + 3600), puc);
        harness.setLabResourceType(labId, 1);
        harness.enableLedgerRefund();
        harness.seedCreditReservationWithAllocations(inst, key, 4);

        vm.prank(backend);
        uint256 gasBefore = gasleft();
        harness.cancelBookingWrapper(inst, keccak256(bytes(puc)), key);
        uint256 gasUsed = gasBefore - gasleft();

        assertLt(gasUsed, 1_000_000, "consumer cancellation exceeds backend gas limit");
        assertEq(harness.getReservationStatus(key), _CANCELLED);
    }
}
