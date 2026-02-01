// SPDX-License-Identifier: MIT
pragma solidity ^0.8.33;

import {BaseTest} from "./BaseTest.sol";
import "forge-std/Test.sol";
import {LibHeapHarness} from "../contracts/test/LibHeapHarness.sol";

contract LibHeapStress is BaseTest {
    LibHeapHarness harness;

    function setUp() public override {
        super.setUp();
        harness = new LibHeapHarness();
    }

    // Fuzzed test: build a heap of up to 1000 entries and randomly cancel some
    // Ensures popped elements come in non-decreasing end order and cancellations are skipped
    function test_fuzz_heap_with_random_cancellations(
        uint256 seed,
        uint16 n
    ) public {
        // bound n to 1..1000
        uint256 nn = uint256(n % 1000) + 1;
        vm.assume(nn > 0 && nn <= 1000);

        uint256 labId = 42;
        bytes32[] memory keys = new bytes32[](nn);
        uint32[] memory ends = new uint32[](nn);

        uint256 confirmedCount = 0;
        for (uint256 i = 0; i < nn; i++) {
            bytes32 k = keccak256(abi.encodePacked(seed, i));
            uint32 end = uint32(1000 + i * 10 + uint32(seed % 10));
            keys[i] = k;
            ends[i] = end;
            harness.enqueueViaLib(labId, k, end);
            // pseudo-random cancellation decision
            uint256 p = uint256(keccak256(abi.encodePacked(seed, i, nn)));
            if (p % 4 == 0) {
                // CANCELLED
                harness.setReservation(k, labId, 5);
            } else {
                harness.setReservation(k, labId, 1); // CONFIRMED
                confirmedCount++;
            }
        }

        vm.warp(1 days);

        bytes32 prev = bytes32(0);
        uint32 prevEnd = 0;
        uint256 poppedCount = 0;
        while (harness.heapLength(labId) > 0) {
            bytes32 p = harness.popEligible(labId, block.timestamp);
            if (p == bytes32(0)) break; // none eligible
            // find end for key p
            uint32 found = 0;
            for (uint256 j = 0; j < nn; j++) {
                if (keys[j] == p) {
                    found = ends[j];
                    break;
                }
            }
            // popped must be confirmed
            assertTrue(found > 0, "popped key not found in local mapping");
            if (prev != bytes32(0)) {
                assertTrue(found >= prevEnd, "heap popped out of order");
            }
            prev = p;
            prevEnd = found;
            poppedCount++;
        }

        assertEq(poppedCount, confirmedCount);
    }

    // Stress test: compaction should trigger when invalidCount > heapSize/5 and size <= MAX_COMPACTION_SIZE
    function test_compaction_trigger() public {
        uint256 labId = 100;
        uint256 n = 400; // less than MAX_COMPACTION_SIZE (500)
        // Enqueue n entries
        for (uint256 i = 0; i < n; i++) {
            bytes32 k = keccak256(abi.encodePacked("c", i));
            harness.enqueueViaLib(labId, k, uint32(1000 + i));
            // mark half as cancelled to ensure invalidCount is large
            if (i % 2 == 0) {
                harness.setReservation(k, labId, 5); // CANCELLED
            } else {
                harness.setReservation(k, labId, 1); // CONFIRMED
            }
        }
        // set invalidCount to number of cancelled entries (~n/2)
        harness.setInvalidCount(labId, n / 2);
        uint256 beforeLen = harness.heapLength(labId);
        bytes32 popped = harness.popEligible(labId, block.timestamp + 1 days);
        // after pop, compaction should have run and invalidCount reset
        assertEq(harness.invalidCount(labId), 0);
        assertTrue(harness.heapLength(labId) <= beforeLen, "heap did not compact");
        // popped should be a confirmed reservation (non-zero)
        assertTrue(popped != bytes32(0));
    }

    // Stress test: compaction should be skipped when heap size > MAX_COMPACTION_SIZE
    function test_compaction_skipped_large_heap() public {
        uint256 labId = 101;
        uint256 n = 600; // greater than MAX_COMPACTION_SIZE (500)
        for (uint256 i = 0; i < n; i++) {
            bytes32 k = keccak256(abi.encodePacked("d", i));
            harness.enqueueViaLib(labId, k, uint32(1000 + i));
            // mark many cancelled
            if (i % 3 == 0) {
                harness.setReservation(k, labId, 5);
            } else {
                harness.setReservation(k, labId, 1);
            }
        }
        harness.setInvalidCount(labId, n / 3);
        uint256 beforeLen = harness.heapLength(labId);
        harness.popEligible(labId, block.timestamp + 1 days);
        // Since originalLength > MAX_COMPACTION_SIZE, compaction should have been skipped and invalidCount remains
        assertTrue(harness.invalidCount(labId) > 0, "invalidCount was unexpectedly reset");
        // At least one element should have been removed via popEligible (either invalids or a popped confirmed), but full compaction should be skipped
        assertTrue(harness.heapLength(labId) < beforeLen, "no elements were removed by popEligible");
    }
}
