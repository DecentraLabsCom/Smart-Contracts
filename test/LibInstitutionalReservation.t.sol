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
    uint8 internal constant _IN_USE = 2;
    uint8 internal constant _CANCELLED = 5;

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
        uint256 returned = harness.cancelReservationRequestWrapper(inst, puc, key);

        assertEq(returned, labId);

        assertEq(harness.getReservationStatus(key), _CANCELLED);
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
        uint256 returned = harness.cancelBookingWrapper(inst, puc, key);
        assertEq(returned, labId);

        (uint96 providerFee, uint96 treasuryFee, uint96 governanceFee, uint96 refundAmount) =
            LibRevenue.computeCancellationFee(price);
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
        harness.cancelBookingWrapper(inst, puc, key);
    }
}
