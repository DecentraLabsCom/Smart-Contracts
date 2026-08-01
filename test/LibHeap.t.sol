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
        harness.setReservation(bad, labId, 4); // CANCELLED
        harness.setReservation(good, labId, 1); // CONFIRMED

        vm.warp(2000);
        bytes32 popped = harness.popEligible(labId, block.timestamp);
        assertEq(popped, good);
        assertEq(harness.heapLength(labId), 0);
    }

    function test_accessAuthorizedWithoutAttestation_staysInHeapDuringGrace() public {
        uint256 labId = 4;
        bytes32 key = keccak256("access-authorized-without-attestation");

        harness.setReservation(key, labId, 2); // ACCESS_AUTHORIZED
        harness.setReservationEnd(key, 1000);
        harness.enqueueViaLib(labId, key, 1000);

        vm.warp(1000 + 1 days);
        assertEq(harness.popEligible(labId, block.timestamp), bytes32(0));
        assertEq(harness.heapLength(labId), 1);
        assertTrue(harness.payoutHeapContains(key));

        harness.setSessionStarted(key);
        assertEq(harness.popEligible(labId, block.timestamp), key);
        assertEq(harness.heapLength(labId), 0);
    }

    function test_boundedGraceScan_cursor_reaches_later_settleable_candidate() public {
        uint256 labId = 6;
        for (uint256 i; i < 256; i++) {
            bytes32 pendingKey = keccak256(abi.encodePacked("grace-pending", i));
            harness.setReservation(pendingKey, labId, 2); // ACCESS_AUTHORIZED
            harness.setReservationEnd(pendingKey, 900);
            harness.enqueueViaLib(labId, pendingKey, 900);
        }

        bytes32 settleableKey = keccak256("settleable-after-grace-prefix");
        harness.setReservation(settleableKey, labId, 2); // ACCESS_AUTHORIZED
        harness.setReservationEnd(settleableKey, 999);
        harness.setSessionStarted(settleableKey);
        harness.enqueueViaLib(labId, settleableKey, 999);

        vm.warp(1000);
        assertEq(harness.popEligible(labId, block.timestamp), bytes32(0));
        assertEq(harness.heapLength(labId), 257);

        assertEq(harness.popEligible(labId, block.timestamp), settleableKey);
        assertEq(harness.heapLength(labId), 256);
    }

    function test_removePayoutCandidate_updatesIndexes_afterMiddleRemoval() public {
        uint256 labId = 5;
        bytes32 first = keccak256("first");
        bytes32 middle = keccak256("middle");
        bytes32 last = keccak256("last");

        harness.setReservation(first, labId, 1);
        harness.setReservation(middle, labId, 1);
        harness.setReservation(last, labId, 1);
        harness.setReservationEnd(first, 100);
        harness.setReservationEnd(middle, 300);
        harness.setReservationEnd(last, 200);
        harness.enqueueViaLib(labId, first, 100);
        harness.enqueueViaLib(labId, middle, 300);
        harness.enqueueViaLib(labId, last, 200);

        harness.removePayoutCandidates(labId, middle);

        assertEq(harness.payoutHeapIndexPlusOne(middle), 0);
        assertEq(harness.popEligible(labId, 250), first);
        assertEq(harness.popEligible(labId, 250), last);
    }
}
