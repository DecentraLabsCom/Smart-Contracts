// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.33;

import "forge-std/Test.sol";
import "./BaseTest.sol";
import "./Harnesses.sol";
import "../contracts/libraries/LibAppStorage.sol";

contract ToggleRefundHarness {
    bool public failRefund = false;

    function setFailRefund(bool v) external {
        failRefund = v;
    }

    // mirror minimal harness storage helpers from InstReservationHarness
    function setBackend(
        address inst,
        address backend
    ) external {
        AppStorage storage s = LibAppStorage.diamondStorage();
        s.institutionalBackends[inst] = backend;
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
        AppStorage storage s = LibAppStorage.diamondStorage();
        Reservation storage r = s.reservations[key];
        r.renter = renter;
        r.payerInstitution = payerInstitution;
        r.price = price;
        r.status = status;
        r.labId = labId;
        r.start = start;
        r.end = start + 3600; // default 1 hour slot for tests
        if (bytes(puc).length > 0) s.reservationPucHash[key] = keccak256(bytes(puc));

        // align period start/duration to mimic createInstReservation behavior
        uint256 d = s.institutionalSpendingPeriod[payerInstitution];
        if (d == 0) d = LibAppStorage.DEFAULT_SPENDING_PERIOD;
        uint256 rsAligned = block.timestamp - (block.timestamp % d);
        r.requestPeriodStart = uint64(rsAligned);
        r.requestPeriodDuration = uint64(d);
    }

    function cancelBookingWrapper(
        address institutionalProvider,
        string calldata puc,
        bytes32 reservationKey
    ) external returns (uint256) {
        return LibInstitutionalReservation.cancelBooking(institutionalProvider, puc, reservationKey);
    }

    // capture refunds and support toggling failure
    address public lastRefundProvider;
    string public lastRefundPuc;
    uint256 public lastRefundAmount;

    function refundToInstitutionalTreasury(
        address provider,
        string calldata puc,
        uint256 amount
    ) external {
        if (failRefund) revert("refund failed");
        lastRefundProvider = provider;
        lastRefundPuc = puc;
        lastRefundAmount = amount;
    }

    // helper to read reservation status from storage
    function getReservationStatus(
        bytes32 key
    ) external view returns (uint8) {
        AppStorage storage s = LibAppStorage.diamondStorage();
        return s.reservations[key].status;
    }
}

contract IntegrationDiamondReservationTest is BaseTest {
    ConfirmHarness public confirm;
    InstReservationHarness public inst;
    ToggleRefundHarness public toggler;

    address constant INSTITUTION = address(0xBA11);
    address constant BACKEND = address(0xBEEF);
    address constant LAB_OWNER = address(0xDEAD);

    uint8 internal constant _PENDING = 0;
    uint8 internal constant _CONFIRMED = 1;
    uint8 internal constant _CANCELLED = 5;

    function setUp() public override {
        super.setUp();
        confirm = new ConfirmHarness();
        inst = new InstReservationHarness();
        toggler = new ToggleRefundHarness();
    }

    function test_institutional_confirm_and_cancel_end_to_end() public {
        // prepare reservation
        uint256 labId = 77;
        uint32 start = uint32(block.timestamp + 3600);
        bytes32 key = keccak256(abi.encodePacked(labId, start));
        string memory puc = "user@inst";
        uint96 price = 20000;

        // set institution role and backend
        confirm.setInstitutionRole(INSTITUTION);
        confirm.setBackend(INSTITUTION, BACKEND);

        // set lab owner and provider readiness
        confirm.setOwner(labId, LAB_OWNER);
        confirm.setProviderStake(LAB_OWNER, 1_000_000);
        confirm.setTokenStatus(labId, true);

        // set reservation in storage as pending (write via confirm harness to match confirm caller)
        confirm.setReservation(key, address(0xCAFE), INSTITUTION, price, _PENDING, labId, start, puc);
        // sanity check it was written
        assertEq(confirm.getReservationStatus(key), _PENDING);

        // confirm as backend
        vm.prank(BACKEND);
        confirm.confirmInstitutionalReservationRequestWithPuc(INSTITUTION, key, puc);

        // confirmed and treasury spent recorded
        assertEq(confirm.getReservationStatus(key), _CONFIRMED);
        assertEq(confirm.lastSpentProvider(), INSTITUTION);
        assertEq(confirm.lastSpentPuc(), puc);
        assertEq(confirm.lastSpentAmount(), price);

        // now cancel booking as backend; use inst harness which records refunds
        inst.setBackend(INSTITUTION, BACKEND);

        // mirror confirmed reservation into inst harness so cancellation operates on same state
        inst.setReservation(key, address(0xCAFE), INSTITUTION, price, _CONFIRMED, labId, start, puc);

        // sanity check that reservation is still confirmed in both harnesses
        assertEq(confirm.getReservationStatus(key), _CONFIRMED);
        assertEq(inst.getReservationStatus(key), _CONFIRMED);

        vm.prank(BACKEND);
        inst.cancelBookingWrapper(INSTITUTION, puc, key);

        // after successful cancel, refund should be recorded in harness
        assertEq(inst.lastRefundProvider(), INSTITUTION);
        assertEq(inst.lastRefundPuc(), puc);
        // fee/refund arithmetic verifies at least non-zero refund amount
        assert(inst.lastRefundAmount() > 0);
        assertEq(inst.getReservationStatus(key), _CANCELLED);
    }

    function test_cancelBooking_refund_failure_and_recovery() public {
        uint256 labId = 88;
        uint32 start = uint32(block.timestamp + 7200);
        bytes32 key = keccak256(abi.encodePacked(labId, start));
        string memory puc = "recover@inst";
        uint96 price = 20000;

        // prepare toggler as the handler (it will be called to refund)
        toggler.setBackend(INSTITUTION, BACKEND);
        toggler.setReservation(key, address(0xB), INSTITUTION, price, _CONFIRMED, labId, start, puc);
        toggler.setBackend(INSTITUTION, BACKEND);

        // set lab owner readiness in ConfirmHarness storage so provider checks pass
        confirm.setOwner(labId, LAB_OWNER);
        confirm.setProviderStake(LAB_OWNER, 1_000_000);
        confirm.setTokenStatus(labId, true);

        // make refund fail
        toggler.setFailRefund(true);

        // sanity check reservation is CONFIRMED before call
        assertEq(toggler.getReservationStatus(key), _CONFIRMED);

        vm.prank(BACKEND);
        // expect revert because refund reverts and bubbles
        vm.expectRevert(bytes("refund failed"));
        toggler.cancelBookingWrapper(INSTITUTION, puc, key);

        // reservation should remain confirmed (no partial state change)
        assertEq(toggler.getReservationStatus(key), _CONFIRMED);

        // now succeed refund and retry
        toggler.setFailRefund(false);
        vm.prank(BACKEND);
        toggler.cancelBookingWrapper(INSTITUTION, puc, key);

        // now reservation cancelled and refund recorded
        assertEq(toggler.lastRefundProvider(), INSTITUTION);
        assertEq(toggler.lastRefundPuc(), puc);
        assert(toggler.lastRefundAmount() > 0);
    }
}
