// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.33;

import "forge-std/Test.sol";
import "./RivalIntervalTree.t.sol";

contract RivalIntervalTreePrefixShrinkerTest is Test {
    TreeHarness public harness;

    function setUp() public {
        harness = new TreeHarness();
    }

    // Try to find the minimal prefix length of the known failing seed that triggers an insert revert
    function test_find_minimal_failing_prefix() public {
        bytes32 seed = 0x152cd61ad49e67502f5f95c2c73664587889cbabb6b1ea03649221ccb5fcf02b;
        uint256 ops = (uint8(seed[0]) % 32) + 1;

        // linear search for minimal prefix causing a revert
        uint256 failingPrefix = 0;
        for (uint256 prefix = 1; prefix <= ops; ++prefix) {
            // fresh harness per attempt
            TreeHarness h = new TreeHarness();
            bool failed = false;

            for (uint256 i = 0; i < prefix; ++i) {
                uint256 rnd = uint256(keccak256(abi.encodePacked(seed, i, "rnd")));
                bool doInsert = (rnd % 2 == 0);
                uint32 s = uint32(rnd % 10_000);
                uint32 e = s + uint32((rnd >> 8) % 100 + 1);

                if (doInsert) {
                    try h.insert(s, e) {
                    // ok
                    }
                    catch (bytes memory reason) {
                        // record first failing prefix
                        emit log_named_uint("prefix_failed_at", prefix);
                        emit log_named_uint("failing_op_index", i);
                        emit log_named_bytes("revert_reason", reason);
                        failed = true;
                        break;
                    }
                } else {
                    if (h.exists(s)) {
                        h.remove(s);
                    }
                }
            }

            if (failed) {
                failingPrefix = prefix;
                break;
            }
        }

        // ensure we found a failing prefix for the seed (should be true given repro)
        assertTrue(failingPrefix > 0, "expected to find a failing prefix for the seed");

        // For minimality, ensure prefix-1 does not fail
        if (failingPrefix > 1) {
            TreeHarness h2 = new TreeHarness();
            for (uint256 i = 0; i < failingPrefix - 1; ++i) {
                uint256 rnd = uint256(keccak256(abi.encodePacked(seed, i, "rnd")));
                bool doInsert = (rnd % 2 == 0);
                uint32 s = uint32(rnd % 10_000);
                uint32 e = s + uint32((rnd >> 8) % 100 + 1);

                if (doInsert) {
                    try h2.insert(s, e) {}
                    catch {
                        fail(); // prefix-1 MUST not fail
                    }
                } else {
                    if (h2.exists(s)) {
                        h2.remove(s);
                    }
                }
            }
        }
    }
}
