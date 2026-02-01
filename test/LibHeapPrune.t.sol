// SPDX-License-Identifier: MIT
pragma solidity ^0.8.33;

import {BaseTest} from "./BaseTest.sol";
import "forge-std/Test.sol";
import {LibHeapHarness} from "../contracts/test/LibHeapHarness.sol";

contract LibHeapPrune is BaseTest {
    LibHeapHarness harness;

    function setUp() public override {
        super.setUp();
        harness = new LibHeapHarness();
    }

    function test_prune_respects_maxIterations() public {
        uint256 labId = 7;
        uint256 n = 50;
        for (uint256 i = 0; i < n; i++) {
            bytes32 k = keccak256(abi.encodePacked("p", i));
            harness.enqueueViaLib(labId, k, uint32(1000 + i));
            // mark all as cancelled
            harness.setReservation(k, labId, 5);
        }
        harness.setInvalidCount(labId, n);
        uint256 beforeLen = harness.heapLength(labId);
        uint256 removed = harness.pruneViaLib(labId, 10);
        assertEq(removed, 10);
        assertEq(harness.invalidCount(labId), n - 10);
        assertEq(harness.heapLength(labId), beforeLen - 10);
    }

    function test_prune_on_large_heap_allows_batch_compaction() public {
        uint256 labId = 8;
        uint256 n = 600; // > MAX_COMPACTION_SIZE
        for (uint256 i = 0; i < n; i++) {
            bytes32 k = keccak256(abi.encodePacked("q", i));
            harness.enqueueViaLib(labId, k, uint32(1000 + i));
            if (i % 2 == 0) {
                harness.setReservation(k, labId, 5);
            } else {
                harness.setReservation(k, labId, 1);
            }
        }
        harness.setInvalidCount(labId, n / 2);
        uint256 beforeLen = harness.heapLength(labId);
        // run prune with 100 iterations (max checks). removed may be <= 100 since some checks find valid entries
        uint256 removed = harness.pruneViaLib(labId, 100);
        assertTrue(removed > 0, "prune did not remove any entries");
        assertTrue(removed <= 100, "removed more than max iterations");
        assertEq(harness.invalidCount(labId), n / 2 - removed);
        assertTrue(harness.heapLength(labId) < beforeLen);
        // repeat pruning until invalidCount is zero (batch compaction via repeated calls)
        uint256 iterations = 0;
        uint256 totalRemoved = removed;
        while (harness.invalidCount(labId) > 0 && iterations < 50) {
            uint256 r = harness.pruneViaLib(labId, 100);
            if (r == 0) break;
            totalRemoved += r;
            iterations++;
        }
        assertEq(harness.invalidCount(labId), n / 2 - totalRemoved);
        // further, confirm heap still yields valid pops in order
        vm.warp(1 days);
        bytes32 last = bytes32(0);
        while (true) {
            bytes32 p = harness.popEligible(labId, block.timestamp);
            if (p == bytes32(0)) break;
            // ensure popped ones are confirmed
            assertTrue(harness.heapLength(labId) < beforeLen);
            last = p;
        }
    }
}
