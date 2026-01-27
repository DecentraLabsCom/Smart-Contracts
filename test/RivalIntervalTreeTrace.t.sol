// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.33;

import "forge-std/Test.sol";
import "./RivalIntervalTree.t.sol";

contract RivalIntervalTreeTraceTest is Test {
    TreeHarness public harness;

    function setUp() public {
        harness = new TreeHarness();
    }

    function test_trace_two_op_sequence_logs() public {
        uint32 s1 = 5922;
        uint32 e1 = 5989;
        uint32 s2 = 5908;
        uint32 e2 = 5985;

        // Clear and record logs around operations
        vm.recordLogs();
        bool ok1 = harness.tryInsert(s1, e1);
        assertTrue(ok1, "first tryInsert should succeed");

        // Start recording logs for the second op only
        vm.recordLogs();
        bool ok2 = harness.tryInsert(s2, e2);
        emit log_named_uint("second_try_insert_result", ok2 ? 1 : 0);

        // Retrieve recorded logs and dump topics/data
        Vm.Log[] memory logs = vm.getRecordedLogs();

        emit log_named_uint("logs_count", logs.length);
        for (uint256 i = 0; i < logs.length; ++i) {
            // Log first topic (event signature) and raw data
            bytes32 topic0 = logs[i].topics.length > 0 ? logs[i].topics[0] : bytes32(0);
            emit log_named_bytes32("topic0", topic0);
            emit log_named_bytes("data", logs[i].data);
        }
    }
}
