// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.33;

import "forge-std/Test.sol";
import "./RivalIntervalTree.t.sol";

contract RivalIntervalTreeTwoOpReproTest is Test {
    TreeHarness public harness;

    function setUp() public {
        harness = new TreeHarness();
    }

    function dumpNodes(
        uint256 cap
    ) internal {
        uint256 cur = harness.first();
        uint256 iter = 0;
        while (cur != 0 && iter < cap) {
            (uint256 k, uint256 end, uint256 parent, uint256 left, uint256 right, bool red) =
                harness.getNode(uint32(cur));
            emit log_named_uint("node_key", k);
            emit log_named_uint("node_end", end);
            emit log_named_uint("node_parent", parent);
            emit log_named_uint("node_left", left);
            emit log_named_uint("node_right", right);
            emit log_named_uint("node_red", red ? 1 : 0);
            uint256 nx = harness.nextKey(uint32(cur));
            cur = nx;
            iter++;
        }
        emit log_named_uint("dump_nodes_count", iter);
    }

    function dumpNodeKey(
        uint32 key
    ) internal {
        (uint256 k, uint256 end, uint256 parent, uint256 left, uint256 right, bool red) = harness.getNode(key);
        emit log_named_uint("single_node_key", k);
        emit log_named_uint("single_node_end", end);
        emit log_named_uint("single_node_parent", parent);
        emit log_named_uint("single_node_left", left);
        emit log_named_uint("single_node_right", right);
        emit log_named_uint("single_node_red", red ? 1 : 0);
    }

    function test_two_op_repro_and_dump() public {
        uint32 s1 = 5922;
        uint32 e1 = 5989;
        uint32 s2 = 5908;
        uint32 e2 = 5985;

        // Insert first interval
        harness.insert(s1, e1);
        emit log_string("after first insert");
        emit log_named_uint("nodes", harness.countNodes());
        dumpNodes(16);
        dumpNodeKey(s1);

        // Attempt second insert and capture failure
        uint256 gasBefore = gasleft();
        try harness.insert(s2, e2) {
            fail("expected second insert to revert with Overlap");
        } catch (bytes memory reason) {
            uint256 gasAfter = gasleft();
            emit log_named_uint("failed_insert_gas_used", gasBefore - gasAfter);
            emit log_named_bytes("revert_reason", reason);

            bytes memory expected = abi.encodeWithSignature("Error(string)", "Overlap");
            assert(keccak256(reason) == keccak256(expected));

            // Dump tree state after failure to see any partial changes
            emit log_string("after failed second insert (state dump)");
            emit log_named_uint("nodes", harness.countNodes());
            dumpNodes(16);
            dumpNodeKey(s1);
            if (harness.exists(s2)) {
                dumpNodeKey(s2);
            } else {
                emit log_string("second key does not exist (as expected)");
            }
            return;
        }
    }
}
