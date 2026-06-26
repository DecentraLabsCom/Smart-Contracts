// SPDX-License-Identifier: MIT
pragma solidity ^0.8.33;

import {Test} from "forge-std/Test.sol";
import {ConfirmHarness} from "./Harnesses.sol";

contract LongDurationReservationTest is Test {
    ConfirmHarness harness;

    address institution = address(0xBEEF);
    address backend = address(0xBEE1);
    address provider = address(0xCAFE);
    uint256 labId = 77;

    uint8 internal constant _PENDING = 0;
    uint8 internal constant _CONFIRMED = 1;

    function setUp() public {
        harness = new ConfirmHarness();
        harness.setInstitutionRole(institution);
        harness.setBackend(institution, backend);
        harness.setOwner(labId, provider);
        harness.setTokenStatus(labId, true);
        harness.setProviderActive(provider);
    }

    function _key(
        uint32 start
    ) internal view returns (bytes32) {
        return keccak256(abi.encodePacked(labId, start));
    }

    function _seedPending(
        uint32 start,
        uint32 end,
        uint96 price,
        string memory puc
    ) internal returns (bytes32 key) {
        key = _key(start);
        harness.setReservationWithEnd(key, address(0xABCD), institution, price, _PENDING, labId, start, end, puc);
    }

    function _confirm(
        bytes32 key,
        string memory puc
    ) internal {
        vm.prank(backend);
        harness.confirmInstitutionalReservationRequestWithPuc(institution, key, puc);
    }

    function test_confirms_one_day_reservation() public {
        uint32 start = uint32(block.timestamp + 1 days);
        uint32 end = start + 1 days;
        bytes32 key = _seedPending(start, end, 100 * uint96(end - start), "day@inst");

        _confirm(key, "day@inst");

        assertEq(harness.getReservationStatus(key), _CONFIRMED);
        assertEq(harness.getReservationEnd(key), end);
    }

    function test_confirms_one_week_reservation() public {
        uint32 start = uint32(block.timestamp + 2 days);
        uint32 end = start + 7 days;
        bytes32 key = _seedPending(start, end, 100 * uint96(end - start), "week@inst");

        _confirm(key, "week@inst");

        assertEq(harness.getReservationStatus(key), _CONFIRMED);
        assertEq(harness.getReservationEnd(key), end);
    }

    function test_confirms_thirty_day_reservation() public {
        uint32 start = uint32(block.timestamp + 3 days);
        uint32 end = start + 30 days;
        bytes32 key = _seedPending(start, end, 100 * uint96(end - start), "month@inst");

        _confirm(key, "month@inst");

        assertEq(harness.getReservationStatus(key), _CONFIRMED);
        assertEq(harness.getReservationEnd(key), end);
    }

    function test_long_reservation_blocks_overlapping_short_reservation() public {
        uint32 start = uint32(block.timestamp + 4 days);
        uint32 end = start + 7 days;
        bytes32 longKey = _seedPending(start, end, 100, "long@inst");
        _confirm(longKey, "long@inst");

        uint32 shortStart = start + 1 days;
        uint32 shortEnd = shortStart + 1 hours;
        bytes32 shortKey = _seedPending(shortStart, shortEnd, 100, "short@inst");

        vm.prank(backend);
        vm.expectRevert();
        harness.confirmInstitutionalReservationRequestWithPuc(institution, shortKey, "short@inst");
    }

    function test_adjacent_reservation_after_long_reservation_is_allowed() public {
        uint32 start = uint32(block.timestamp + 5 days);
        uint32 end = start + 7 days;
        bytes32 longKey = _seedPending(start, end, 100, "long@inst");
        _confirm(longKey, "long@inst");

        uint32 adjacentStart = end;
        uint32 adjacentEnd = adjacentStart + 1 days;
        bytes32 adjacentKey = _seedPending(adjacentStart, adjacentEnd, 100, "adjacent@inst");
        _confirm(adjacentKey, "adjacent@inst");

        assertEq(harness.getReservationStatus(adjacentKey), _CONFIRMED);
    }

    function test_price_total_must_fit_uint96() public pure {
        uint256 pricePerSecond = type(uint96).max;
        uint256 durationSeconds = 2;
        uint256 total = pricePerSecond * durationSeconds;

        assertGt(total, type(uint96).max);
    }

    function test_end_timestamp_must_fit_uint32_before_cast() public pure {
        uint256 end = uint256(type(uint32).max) + 1;

        assertGt(end, type(uint32).max);
    }
}
