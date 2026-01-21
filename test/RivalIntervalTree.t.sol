// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.33;

import "forge-std/Test.sol";
import "../contracts/libraries/RivalIntervalTreeLibrary.sol";
import "../contracts/libraries/LibAppStorage.sol";

contract TreeHarness {
    using RivalIntervalTreeLibrary for Tree;
    Tree internal tree;

    function insert(uint32 s, uint32 e) external {
        tree.insert(s, e);
    }

    function exists(uint32 k) external view returns (bool) {
        return tree.exists(k);
    }

    function hasConflict(uint32 s, uint32 e) external view returns (bool) {
        return tree.hasConflict(s, e);
    }

    function remove(uint32 k) external {
        tree.remove(k);
    }

    function first() external view returns (uint256) {
        return tree.first();
    }

    function last() external view returns (uint256) {
        return tree.last();
    }

    function getNode(uint32 k) external view returns (uint256 _k, uint256 _end, uint256 _parent, uint256 _left, uint256 _right, bool _red) {
        return tree.getNode(k);
    }
}

contract RivalIntervalTreeTest is Test {
    TreeHarness harness;

    function setUp() public {
        harness = new TreeHarness();
    }

    function test_insert_non_overlapping_and_navigation() public {
        harness.insert(10, 20);
        harness.insert(30, 40);
        harness.insert(50, 60);

        assertTrue(harness.exists(10));
        assertTrue(harness.exists(30));
        assertTrue(harness.exists(50));

        assertEq(harness.first(), 10);
        assertEq(harness.last(), 50);
    }

    function test_insert_overlap_reverts() public {
        harness.insert(100, 200);
        vm.expectRevert();
        harness.insert(150, 250); // overlaps existing
    }

    function test_hasConflict_detects_existing_or_overlap() public {
        harness.insert(1000, 1100);
        assertTrue(harness.hasConflict(1000, 1100)); // existing key
        assertTrue(harness.hasConflict(1050, 1150)); // overlap
        assertFalse(harness.hasConflict(1100, 1200)); // adjacent allowed
    }

    function test_remove_and_reinsert() public {
        harness.insert(3000, 3100);
        assertTrue(harness.exists(3000));
        harness.remove(3000);
        assertFalse(harness.exists(3000));
        harness.insert(3000, 3100); // should not revert
        assertTrue(harness.exists(3000));
    }
}
