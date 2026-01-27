// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.33;

import "forge-std/Test.sol";
import "./RivalIntervalTree.t.sol";

contract RivalIntervalTreeReproTest is Test {
    TreeHarness public harness;

    function setUp() public {
        harness = new TreeHarness();
    }

    function test_repro_failing_seed() public {
        // failing seed observed in fuzz run
        bytes32 seed = 0x152cd61ad49e67502f5f95c2c73664587889cbabb6b1ea03649221ccb5fcf02b;
        uint256 ops = (uint8(seed[0]) % 32) + 1;

        emit log_named_bytes32("seed", seed);

        for (uint256 i = 0; i < ops; ++i) {
            uint256 rnd = uint256(keccak256(abi.encodePacked(seed, i, "rnd")));
            bool doInsert = (rnd % 2 == 0);
            uint32 s = uint32(rnd % 10_000);
            uint32 e = s + uint32((rnd >> 8) % 100 + 1);

            // avoid calling expensive countNodes on every iteration (can OOG after large inserts)
            uint256 nodeCount = 0;
            if (i % 8 == 0 && gasleft() > 200_000) {
                nodeCount = harness.countNodes();
            }
            emit log_named_uint("op_index", i);
            emit log_named_uint("nodes_before", nodeCount);
            emit log_named_uint("gas_before", gasleft());
            emit log_named_uint("s", s);
            emit log_named_uint("e", e);

            if (doInsert) {
                uint256 gasBeforeInsert = gasleft();
                try harness.insert(s, e) {
                    uint256 gasAfterInsert = gasleft();
                    emit log_string("insert: success");
                    emit log_named_uint("gas_used_by_insert", gasBeforeInsert - gasAfterInsert);
                } catch (bytes memory reason) {
                    // Report op index and revert reason, assert it's the known "Overlap" revert, then stop early
                    emit log_named_uint("failed_op_index", i);
                    emit log_named_bytes("revert_reason", reason);
                    // expect Error(string) == "Overlap"
                    bytes memory expected = abi.encodeWithSignature("Error(string)", "Overlap");
                    assert(keccak256(reason) == keccak256(expected));
                    return;
                }
            } else {
                // remove path: attempt remove only if exists
                if (harness.exists(s)) {
                    harness.remove(s);
                    emit log_string("remove: success");
                    emit log_named_uint("nodes_after", harness.countNodes());
                } else {
                    emit log_string("remove: skip not exists");
                }
            }
        }

        // sanity: assert no overlapping intervals
        // iterate through present nodes and ensure no overlaps via getNode navigation (best effort)
        uint256 first = harness.first();
        if (first != 0) {
            // safer traversal that detects cycles and caps iterations to avoid OOG
            uint256 cur = first;
            uint256 iter = 0;
            uint256 cap = 128; // should be plenty for our tests
            uint256[] memory visited = new uint256[](cap);
            while (cur != 0) {
                if (iter >= cap) {
                    emit log_named_uint("iter_cap_reached", iter);
                    assert(false); // fail test to capture logs
                }
                // log node details
                (uint256 k, uint256 end, uint256 parent, uint256 left, uint256 right, bool red) =
                    harness.getNode(uint32(cur));
                emit log_named_uint("node_key", k);
                emit log_named_uint("node_end", end);
                emit log_named_uint("node_parent", parent);
                emit log_named_uint("node_left", left);
                emit log_named_uint("node_right", right);
                emit log_named_uint("node_red", red ? 1 : 0);

                // detect cycle by checking if next node was already visited
                uint256 nx = harness.nextKey(uint32(cur));
                for (uint256 j = 0; j < iter; ++j) {
                    if (visited[j] == nx && nx != 0) {
                        emit log_named_uint("cycle_detected_at_node", nx);
                        assert(false);
                    }
                }
                visited[iter] = cur;

                if (nx != 0) {
                    // also assert ordering to check for overlaps
                    (uint256 nk,,,,,) = harness.getNode(uint32(nx));
                    assert(end <= nk);
                }

                cur = nx;
                iter++;
            }
        }
    }
}
