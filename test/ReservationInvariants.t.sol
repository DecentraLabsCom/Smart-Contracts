// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.33;

import "forge-std/Test.sol";
import {ReservationHarness, MockERC20} from "./GasReservations.t.sol";
import "../contracts/libraries/LibAppStorage.sol";

contract ReservationInvariantsTest is Test {
    ReservationHarness harness;
    MockERC20 token;
    address renter = address(0xBEEF);
    uint256 labId;

    function setUp() public {
        token = new MockERC20();
        harness = new ReservationHarness();
        harness.initializeHarness(address(token));
        labId = harness.mintAndList(1e6);

        // prepare funds
        token.mint(renter, 10 ether);
        vm.prank(renter);
        token.approve(address(harness), type(uint256).max);
    }

    function _key(
        uint32 start
    ) internal view returns (bytes32) {
        return keccak256(abi.encodePacked(labId, start));
    }

    function test_confirm_increments_counts_and_keys() public {
        uint32 start = uint32(block.timestamp + 1000);
        uint32 end = start + 500;

        vm.prank(renter);
        harness.reservationRequest(labId, start, end);

        bytes32 key = _key(start);

        // confirm
        vm.prank(address(this));
        harness.confirmReservationRequest(key);

        assertEq(harness.getActiveCount(labId, renter), 1);
        assertEq(harness.getReservationKeysByTokenAndUserLength(labId, renter), 1);
        assertEq(harness.getReservationKeysByTokenLength(labId), 1);
    }

    function test_cancel_decrements_counts_and_removes_key() public {
        uint32 start = uint32(block.timestamp + 2000);
        uint32 end = start + 500;

        vm.prank(renter);
        harness.reservationRequest(labId, start, end);
        bytes32 key = _key(start);

        vm.prank(address(this));
        harness.confirmReservationRequest(key);

        // renter cancels booking
        vm.prank(renter);
        harness.cancelBooking(key);

        assertEq(harness.getActiveCount(labId, renter), 0);
        assertEq(harness.getReservationKeysByTokenAndUserLength(labId, renter), 0);
    }

    function test_double_confirm_reverts() public {
        uint32 start = uint32(block.timestamp + 3000);
        uint32 end = start + 500;

        vm.prank(renter);
        harness.reservationRequest(labId, start, end);
        bytes32 key = _key(start);

        vm.prank(address(this));
        harness.confirmReservationRequest(key);

        vm.expectRevert();
        vm.prank(address(this));
        harness.confirmReservationRequest(key);
    }

    function test_activeReservation_by_token_and_user_updates_to_earliest() public {
        uint32 sEarly = uint32(block.timestamp + 5000);
        uint32 eEarly = sEarly + 100;
        uint32 sLate = uint32(block.timestamp + 7000);
        uint32 eLate = sLate + 100;

        // create late and early
        vm.prank(renter);
        harness.reservationRequest(labId, sLate, eLate);
        bytes32 kLate = _key(sLate);

        vm.prank(renter);
        harness.reservationRequest(labId, sEarly, eEarly);
        bytes32 kEarly = _key(sEarly);

        // confirm late first
        vm.prank(address(this));
        harness.confirmReservationRequest(kLate);
        bytes32 active1 = harness.getActiveReservationKey(labId, renter);
        assertEq(active1, kLate);

        // confirm early; active should switch to early
        vm.prank(address(this));
        harness.confirmReservationRequest(kEarly);
        bytes32 active2 = harness.getActiveReservationKey(labId, renter);
        assertEq(active2, kEarly);
    }

    function test_confirm_reverts_when_active_count_is_huge(
        uint8 big
    ) public {
        vm.assume(big > 200); // bias toward a value that would overflow on increment, if allowed
        // set extreme active count directly in harness storage
        vm.prank(address(this));
        harness.setActiveCount(labId, renter, big);

        // reservation request itself should be blocked when active count is already huge
        vm.prank(renter);
        uint32 start = uint32(block.timestamp + 9000);
        uint32 end = start + 100;
        vm.expectRevert();
        harness.reservationRequest(labId, start, end);
    }

    function test_deny_does_not_increment_counts_or_keys() public {
        uint32 start = uint32(block.timestamp + 11_000);
        uint32 end = start + 100;

        vm.prank(renter);
        harness.reservationRequest(labId, start, end);
        bytes32 key = _key(start);

        // provider denies
        vm.prank(address(this));
        harness.denyReservationRequest(key);

        assertEq(harness.getActiveCount(labId, renter), 0);
        assertEq(harness.getReservationKeysByTokenAndUserLength(labId, renter), 0);
    }
}
