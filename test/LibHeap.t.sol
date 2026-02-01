// SPDX-License-Identifier: MIT
pragma solidity ^0.8.33;

import {BaseTest} from "./BaseTest.sol";
import "forge-std/Test.sol";
import {LibHeapHarness} from "../contracts/test/LibHeapHarness.sol";

contract LibHeapTest is BaseTest {
    LibHeapHarness harness;

    function setUp() public override {
        super.setUp();
        harness = new LibHeapHarness();
    }

    function test_singleElement_pop_removes() public {
        uint256 labId = 1;
        bytes32 k1 = keccak256(abi.encodePacked("k1"));
        harness.enqueueViaLib(labId, k1, uint32(1000));
        harness.setReservation(k1, labId, 1); // CONFIRMED

        vm.warp(2000);
        bytes32 popped = harness.popEligible(labId, block.timestamp);
        assertEq(popped, k1);
        assertEq(harness.heapLength(labId), 0);
    }

    function test_twoElements_pop_order() public {
        uint256 labId = 2;
        bytes32 k1 = keccak256(abi.encodePacked("k2_1"));
        bytes32 k2 = keccak256(abi.encodePacked("k2_2"));

        harness.enqueueViaLib(labId, k2, uint32(2000)); // later
        harness.enqueueViaLib(labId, k1, uint32(1000)); // earlier
        harness.setReservation(k1, labId, 1); // CONFIRMED
        harness.setReservation(k2, labId, 1); // CONFIRMED

        vm.warp(3000);
        bytes32 p1 = harness.popEligible(labId, block.timestamp);
        bytes32 p2 = harness.popEligible(labId, block.timestamp);
        assertEq(p1, k1);
        assertEq(p2, k2);
        assertEq(harness.heapLength(labId), 0);
    }

    function test_invalidRoot_skipped_and_next_returned() public {
        uint256 labId = 3;
        bytes32 bad = keccak256(abi.encodePacked("bad"));
        bytes32 good = keccak256(abi.encodePacked("good"));

        // Push bad then good, but mark bad as CANCELLED
        harness.enqueueViaLib(labId, bad, uint32(1000));
        harness.enqueueViaLib(labId, good, uint32(1100));
        harness.setReservation(bad, labId, 5); // CANCELLED (value as in code)
        harness.setReservation(good, labId, 1); // CONFIRMED

        vm.warp(2000);
        bytes32 popped = harness.popEligible(labId, block.timestamp);
        assertEq(popped, good);
        assertEq(harness.heapLength(labId), 0);
    }
}
