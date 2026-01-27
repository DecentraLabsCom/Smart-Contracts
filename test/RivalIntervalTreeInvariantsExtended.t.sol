// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.33;

import "forge-std/Test.sol";
import "./RivalIntervalTree.t.sol";

contract RivalIntervalTreeInvariantsExtendedTest is Test {
    TreeHarness public harness;

    function setUp() public {
        harness = new TreeHarness();
    }

    // Helper: check no cycles when iterating first->next
    function noCycles() internal view returns (bool) {
        uint256 cap = 1024;
        uint256[] memory seen = new uint256[](cap);
        uint256 cur = harness.first();
        uint256 i = 0;
        while (cur != 0) {
            for (uint256 j = 0; j < i; ++j) {
                if (seen[j] == cur) return false;
            }
            if (i >= cap) return false;
            seen[i++] = cur;
            cur = harness.nextKey(uint32(cur));
        }
        return true;
    }

    // Helper: parent/child pointers are consistent
    function parentChildConsistent() internal view returns (bool) {
        uint256 cur = harness.first();
        while (cur != 0) {
            (,, uint256 parent, uint256 left, uint256 right,) = harness.getNode(uint32(cur));
            if (left != 0) {
                (uint256 lk,, uint256 lparent,,,) = harness.getNode(uint32(left));
                if (lparent != cur || lk != left) return false;
            }
            if (right != 0) {
                (uint256 rk,, uint256 rparent,,,) = harness.getNode(uint32(right));
                if (rparent != cur || rk != right) return false;
            }
            if (parent == cur) return false; // self parent
            cur = harness.nextKey(uint32(cur));
        }
        // root parent check
        uint256 root = harness.getRoot();
        if (root != 0) {
            (,, uint256 rparent,,,) = harness.getNode(uint32(root));
            if (rparent != 0) return false;
        }
        return true;
    }

    // Compute black-height for subtree rooted at k; returns (height, ok)
    function blackHeight(
        uint256 k
    ) internal view returns (uint256, bool) {
        if (k == 0) return (0, true);
        (,,, uint256 left, uint256 right, bool red) = harness.getNode(uint32(k));
        (uint256 hl, bool ol) = blackHeight(left);
        (uint256 hr, bool orr) = blackHeight(right);
        if (!ol || !orr) return (0, false);
        if (hl != hr) return (0, false);
        uint256 add = red ? 0 : 1;
        return (hl + add, true);
    }

    function invariantsHold() internal view returns (bool) {
        // root black
        uint256 root = harness.getRoot();
        if (root != 0) {
            (,,,,, bool redRoot) = harness.getNode(uint32(root));
            if (redRoot) return false;
        }
        if (!noCycles()) return false;
        if (!parentChildConsistent()) return false;
        if (root != 0) {
            (uint256 bh, bool ok) = blackHeight(root);
            if (!ok || bh == 0) return false; // empty tree should be handled separately
        }
        return true;
    }

    // Reproduce the minimized failing subsequence and check invariants at each step
    function test_trace_sequence_preserves_invariants() public {
        uint32[2] memory s = [uint32(5922), uint32(5908)];
        uint32[2] memory e = [uint32(5989), uint32(5985)];

        // first insert should succeed and preserve invariants
        bool ok0 = harness.tryInsert(s[0], e[0]);
        assertTrue(ok0, "first insert should succeed");
        assertTrue(invariantsHold(), "invariants after first insert");

        // second insert should fail (overlap) but must not break invariants
        bool ok1 = harness.tryInsert(s[1], e[1]);
        assertTrue(!ok1, "second tryInsert expected to return false due to overlap");
        assertTrue(invariantsHold(), "invariants after failed overlapping insert");

        // ensure no ghost nodes created
        assertEq(harness.countNodes(), 1);
        assertTrue(harness.exists(s[0]));
        assertTrue(!harness.exists(s[1]));
    }

    // Test that a revert during insert (actual insert reverts) does not leave partial state
    function test_actual_revert_leaves_no_ghosts() public {
        harness.setDebug(true);
        harness.insert(10_000 - 1000, 10_000 - 900); // some other nodes to mix
        uint256 before = harness.countNodes();
        // expected to revert
        try harness.insert(5922, 5989) {
        // ok
        }
            catch {
            // ignore
        }
        // attempt overlapping insert via raw insert that will revert
        try harness.insert(5922, 5989) {
        // first time may succeed depending on prior insert
        }
            catch {
            // ignored
        }

        // Force an overlapping insert to revert: ensure s1 exists then attempt overlap
        harness.remove(5922); // ensure base
        harness.insert(5922, 5989);
        uint256 nodesBeforeOverlap = harness.countNodes();
        vm.expectRevert();
        harness.insert(5908, 5985);
        // after revert, count should equal nodesBeforeOverlap
        assertEq(harness.countNodes(), nodesBeforeOverlap, "no ghost nodes after revert");
        assertTrue(invariantsHold(), "invariants after revert");
    }

    // Small randomized insertions using tryInsert: invariants should always hold
    function test_small_random_sequence_keeps_invariants() public {
        harness.setDebug(true);
        bytes32 seed = keccak256(abi.encodePacked("invariant-random"));
        for (uint256 i = 0; i < 64; ++i) {
            uint256 rnd = uint256(keccak256(abi.encodePacked(seed, i)));
            if (rnd % 2 == 0) {
                uint32 s = uint32(rnd % 10_000);
                uint32 e = s + uint32((rnd >> 8) % 100 + 1);
                harness.tryInsert(s, e);
            } else {
                uint32 s = uint32(rnd % 10_000);
                if (harness.exists(s)) harness.remove(s);
            }
            assertTrue(invariantsHold(), "invariants failed during random ops");
        }
    }

    // Simple gas-regression test for heavy insert (threshold conservative)
    function test_insert_gas_regression() public {
        // create some nodes to make tree non-trivial
        for (uint32 i = 1000; i < 1050; ++i) {
            harness.tryInsert(i * 10, i * 10 + 5);
        }
        uint32 s = 9000;
        uint32 e = 9010;
        uint256 gasBefore = gasleft();
        harness.tryInsert(s, e);
        uint256 gasAfter = gasleft();
        uint256 gasUsed = gasBefore - gasAfter;
        emit log_named_uint("gas_used_try_insert", gasUsed);
        // set a generous cap for tryInsert (should be small per operation)
        assertLt(gasUsed, 200_000, "tryInsert gas regression: >200k");
    }
}
