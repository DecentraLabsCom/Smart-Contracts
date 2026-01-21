// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.33;

import "forge-std/Test.sol";
import "./RivalIntervalTree.t.sol";

contract RivalIntervalTreeMinimizerTest is Test {
    TreeHarness public harness;

    struct Op { bool insert; uint32 s; uint32 e; }

    function setUp() public {
        harness = new TreeHarness();
    }

    function buildOps(bytes32 seed, uint256 prefix) internal pure returns (Op[] memory) {
        Op[] memory ops = new Op[](prefix);
        for (uint256 i = 0; i < prefix; ++i) {
            uint256 rnd = uint256(keccak256(abi.encodePacked(seed, i, "rnd")));
            bool doInsert = (rnd % 2 == 0);
            uint32 s = uint32(rnd % 10000);
            uint32 e = s + uint32((rnd >> 8) % 100 + 1);
            ops[i] = Op({insert: doInsert, s: s, e: e});
        }
        return ops;
    }

    function applyOps(Op[] memory ops) internal returns (bool failed, uint256 failedIndex, bytes memory reason) {
        TreeHarness h = new TreeHarness();
        for (uint256 i = 0; i < ops.length; ++i) {
            if (ops[i].insert) {
                try h.insert(ops[i].s, ops[i].e) {
                    // continue
                } catch (bytes memory r) {
                    return (true, i, r);
                }
            } else {
                if (h.exists(ops[i].s)) {
                    h.remove(ops[i].s);
                }
            }
        }
        return (false, 0, "");
    }

    function removeIndex(Op[] memory a, uint256 idx) internal pure returns (Op[] memory) {
        require(idx < a.length, "idx OOB");
        Op[] memory b = new Op[](a.length - 1);
        for (uint256 i = 0; i < idx; ++i) b[i] = a[i];
        for (uint256 i = idx + 1; i < a.length; ++i) b[i - 1] = a[i];
        return b;
    }

    function emitSequence(Op[] memory ops) internal {
        emit log_named_uint("min_len", ops.length);
        for (uint256 i = 0; i < ops.length; ++i) {
            emit log_named_uint(string(abi.encodePacked("op_", vm.toString(i), "_insert")), ops[i].insert ? 1 : 0);
            emit log_named_uint(string(abi.encodePacked("op_", vm.toString(i), "_s")), ops[i].s);
            emit log_named_uint(string(abi.encodePacked("op_", vm.toString(i), "_e")), ops[i].e);
        }
    }

    function test_minimize_failing_subsequence() public {
        bytes32 seed = 0x152cd61ad49e67502f5f95c2c73664587889cbabb6b1ea03649221ccb5fcf02b;
        uint256 prefix = 10; // found by the prefix-shrinker

        Op[] memory ops = buildOps(seed, prefix);

        // verify original prefix indeed fails
        (bool f0, uint256 fi0, bytes memory r0) = applyOps(ops);
        if (!f0) {
            emit log_string("original prefix did not fail unexpectedly");
            fail();
        }
        emit log_named_uint("original_failed_index", fi0);
        emit log_named_bytes("original_revert", r0);

        // greedy elimination: remove any single op that keeps failure
        bool changed = true;
        uint256 rounds = 0;
        while (changed && rounds < 32) {
            changed = false;
            for (uint256 i = 0; i < ops.length; ++i) {
                Op[] memory cand = removeIndex(ops, i);
                (bool f, , ) = applyOps(cand);
                if (f) {
                    ops = cand;
                    changed = true;
                    break;
                }
            }
            rounds++;
        }

        // emit minimized sequence and ensure it still fails
        (bool fmin, uint256 fim, bytes memory rmin) = applyOps(ops);
        assertTrue(fmin, "minimized sequence must still fail");
        emit log_named_uint("min_failed_index", fim);
        emit log_named_bytes("min_revert", rmin);
        emitSequence(ops);

        // assert minimality: removing any single op must NOT fail
        for (uint256 i = 0; i < ops.length; ++i) {
            Op[] memory sho = removeIndex(ops, i);
            (bool f, , ) = applyOps(sho);
            if (f) {
                emit log_named_uint("not_minimal_remove_at", i);
                fail();
            }
        }
    }
}
