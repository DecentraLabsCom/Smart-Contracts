// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.33;

import "./RivalIntervalTreeInvariantTraceFail.t.sol";

contract RivalIntervalTreeRegression is RivalIntervalTreeInvariantTraceFail {
    function test_regression_invariant_random_seed_prefix() public {
        bytes32 seed = keccak256(abi.encodePacked("invariant-random"));
        // replay the first 36 operations (0..35) deterministically
        for (uint256 i = 0; i <= 35; ++i) {
            uint256 rnd = uint256(keccak256(abi.encodePacked(seed, i)));
            if (rnd % 2 == 0) {
                uint32 s = uint32(rnd % 10_000);
                uint32 e = s + uint32((rnd >> 8) % 100 + 1);
                bool ok = harness.tryInsert(s, e);
                // insertion may be false on overlap, that's fine; invariants must hold regardless
                if (!ok) { /* expected overlap or invalid insert */ }
            } else {
                uint32 s = uint32(rnd % 10_000);
                if (harness.exists(s)) harness.remove(s);
            }
            // After each op the tree must satisfy invariants
            bool okInv = _invariantsHold();
            assert(okInv);
        }
    }
}
