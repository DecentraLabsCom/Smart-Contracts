// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.33;

import "forge-std/Test.sol";
import "./RivalIntervalTree.t.sol";

contract RivalIntervalTreeInvariantTraceFail is Test {
    TreeHarness public harness;

    bytes32 private constant TRACE_INSERT_SIG =
        keccak256("TraceInsertStep(string,uint256,uint256,uint256,uint256,uint256,uint256,bool)");
    bytes32 private constant TRACE_ROT_SIG = keccak256("TraceRotation(string,uint256,uint256,uint256,uint256)");

    function setUp() public {
        harness = new TreeHarness();
        // enable heavy test-only tracing/checks
        harness.setDebug(true);
    }

    function test_replay_invariant_random_and_dump_on_failure() public {
        bytes32 seed = keccak256(abi.encodePacked("invariant-random"));
        for (uint256 i = 0; i < 64; ++i) {
            vm.recordLogs();
            uint256 rnd = uint256(keccak256(abi.encodePacked(seed, i)));
            if (rnd % 2 == 0) {
                uint32 s = uint32(rnd % 10_000);
                uint32 e = s + uint32((rnd >> 8) % 100 + 1);
                harness.tryInsert(s, e);
            } else {
                uint32 s = uint32(rnd % 10_000);
                if (harness.exists(s)) harness.remove(s);
            }

            // check invariants after each op
            bool ok = _invariantsHold();
            if (!ok) {
                emit log_named_uint("failed_op_index", i);
                Vm.Log[] memory logs = vm.getRecordedLogs();
                emit log_named_uint("recorded_logs", logs.length);
                for (uint256 j = 0; j < logs.length; ++j) {
                    bytes32 sig = logs[j].topics.length > 0 ? logs[j].topics[0] : bytes32(0);
                    if (sig == TRACE_INSERT_SIG) {
                        (
                            string memory step,
                            uint256 key,
                            uint256 cursor,
                            uint256 parent,
                            uint256 left,
                            uint256 right,
                            uint256 end,
                            bool red
                        ) = abi.decode(
                            logs[j].data, (string, uint256, uint256, uint256, uint256, uint256, uint256, bool)
                        );
                        emit log_named_string("insert_step", step);
                        emit log_named_uint("  key", key);
                        emit log_named_uint("  cursor", cursor);
                        emit log_named_uint("  parent", parent);
                        emit log_named_uint("  left", left);
                        emit log_named_uint("  right", right);
                        emit log_named_uint("  end", end);
                        emit log_named_uint("  red", red ? 1 : 0);
                    } else if (sig == TRACE_ROT_SIG) {
                        (string memory step, uint256 key, uint256 cursor, uint256 cursorChild, uint256 parent) =
                            abi.decode(logs[j].data, (string, uint256, uint256, uint256, uint256));
                        emit log_named_string("rot_step", step);
                        emit log_named_uint("  key", key);
                        emit log_named_uint("  cursor", cursor);
                        emit log_named_uint("  cursorChild", cursorChild);
                        emit log_named_uint("  parent", parent);
                    }
                }
                // dump basic nodes nearby actual root for quick snapshot
                uint256 root = harness.getRoot();
                emit log_named_uint("root_at_failure", root);
                if (root != 0) {
                    (uint256 k, uint256 end, uint256 parent, uint256 left, uint256 right, bool red) =
                        harness.getNode(uint32(root));
                    emit log_named_uint("root_key", k);
                    emit log_named_uint("root_end", end);
                    emit log_named_uint("root_parent", parent);
                    emit log_named_uint("root_left", left);
                    emit log_named_uint("root_right", right);
                    emit log_named_uint("root_red", red ? 1 : 0);
                }
                // fail so we capture logs in CI
                assert(false);
            }
        }
    }

    // Copy of invariantsHold (non-reverting) for quick checks
    function _invariantsHold() internal returns (bool) {
        uint256 root = harness.getRoot();
        if (root != 0) {
            (,,,,, bool redRoot) = harness.getNode(uint32(root));
            if (redRoot) {
                emit log_named_string("invariant", "root_red");
                return false;
            }
        }
        // no cycles
        uint256 cap = 1024;
        uint256[] memory seen = new uint256[](cap);
        uint256 cur = harness.first();
        uint256 i = 0;
        while (cur != 0) {
            for (uint256 j = 0; j < i; ++j) {
                if (seen[j] == cur) {
                    emit log_named_string("invariant", "cycle_detected");
                    return false;
                }
            }
            if (i >= cap) {
                emit log_named_string("invariant", "iteration_cap_exceeded");
                return false;
            }
            seen[i++] = cur;
            (,,, uint256 left, uint256 right,) = harness.getNode(uint32(cur));
            if (left != 0) {
                (,, uint256 lparent,,,) = harness.getNode(uint32(left));
                if (lparent != cur) {
                    emit log_named_string("invariant", "parent_mismatch_left");
                    emit log_named_uint("node", cur);
                    emit log_named_uint("child", left);
                    emit log_named_uint("child_parent", lparent);
                    return false;
                }
            }
            if (right != 0) {
                (,, uint256 rparent,,,) = harness.getNode(uint32(right));
                if (rparent != cur) {
                    emit log_named_string("invariant", "parent_mismatch_right");
                    emit log_named_uint("node", cur);
                    emit log_named_uint("child", right);
                    emit log_named_uint("child_parent", rparent);
                    return false;
                }
            }
            cur = harness.nextKey(uint32(cur));
        }
        // black-height quick check
        if (root != 0) {
            (uint256 bh, bool ok) = _blackHeight(root);
            if (!ok || bh == 0) {
                emit log_named_string("invariant", "black_height_mismatch");
                return false;
            }
        }
        return true;
    }

    function _blackHeight(
        uint256 k
    ) internal returns (uint256, bool) {
        if (k == 0) return (0, true);
        (,,, uint256 left, uint256 right, bool red) = harness.getNode(uint32(k));
        (uint256 hl, bool ol) = _blackHeight(left);
        (uint256 hr, bool orr) = _blackHeight(right);
        if (!ol || !orr) return (0, false);
        if (hl != hr) {
            emit log_named_string("bh_mismatch", "unequal_subtrees");
            emit log_named_uint("node", k);
            emit log_named_uint("hl", hl);
            emit log_named_uint("hr", hr);
            return (0, false);
        }
        uint256 add = red ? 0 : 1;
        return (hl + add, true);
    }
}
