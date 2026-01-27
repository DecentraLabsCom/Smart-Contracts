// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.33;

import "forge-std/Test.sol";
import "./RivalIntervalTree.t.sol";

contract RivalIntervalTreeReproTraceTest is Test {
    TreeHarness public harness;

    function setUp() public {
        harness = new TreeHarness();
    }

    function test_repro_failing_seed_with_trace() public {
        // failing seed observed in fuzz run
        bytes32 seed = 0x152cd61ad49e67502f5f95c2c73664587889cbabb6b1ea03649221ccb5fcf02b;
        uint256 ops = (uint8(seed[0]) % 32) + 1;

        emit log_named_bytes32("seed", seed);

        // start recording logs for whole sequence
        vm.recordLogs();

        for (uint256 i = 0; i < ops; ++i) {
            uint256 rnd = uint256(keccak256(abi.encodePacked(seed, i, "rnd")));
            bool doInsert = (rnd % 2 == 0);
            uint32 s = uint32(rnd % 10_000);
            uint32 e = s + uint32((rnd >> 8) % 100 + 1);

            emit log_named_uint("op_index", i);
            emit log_named_uint("s", s);
            emit log_named_uint("e", e);

            if (doInsert) {
                bool ok = harness.tryInsert(s, e);
                emit log_named_uint("try_insert_ok", ok ? 1 : 0);
            } else {
                if (harness.exists(s)) {
                    harness.remove(s);
                    emit log_string("remove: success");
                } else {
                    emit log_string("remove: skip not exists");
                }
            }
        }

        // retrieve logs
        Vm.Log[] memory logs = vm.getRecordedLogs();
        emit log_named_uint("recorded_logs", logs.length);
        for (uint256 i = 0; i < logs.length; ++i) {
            bytes32 topic0 = logs[i].topics.length > 0 ? logs[i].topics[0] : bytes32(0);
            emit log_named_bytes32("topic0", topic0);
            emit log_named_bytes("data", logs[i].data);
        }
    }
}
