// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.33;

import "forge-std/Test.sol";
import "./RivalIntervalTree.t.sol";

contract RivalIntervalTreeDecodeTraceTest is Test {
    TreeHarness public harness;

    bytes32 private constant TRACE_INSERT_SIG = keccak256("TraceInsertStep(string,uint256,uint256,uint256,uint256,uint256,uint256,bool)");
    bytes32 private constant TRACE_ROT_SIG = keccak256("TraceRotation(string,uint256,uint256,uint256,uint256)");

    function setUp() public {
        harness = new TreeHarness();
    }

    function test_decode_repro_trace() public {
        bytes32 seed = 0x152cd61ad49e67502f5f95c2c73664587889cbabb6b1ea03649221ccb5fcf02b;
        uint256 ops = (uint8(seed[0]) % 32) + 1;

        vm.recordLogs();
        for (uint256 i = 0; i < ops; ++i) {
            uint256 rnd = uint256(keccak256(abi.encodePacked(seed, i, "rnd")));
            bool doInsert = (rnd % 2 == 0);
            uint32 s = uint32(rnd % 10000);
            uint32 e = s + uint32((rnd >> 8) % 100 + 1);

            if (doInsert) {
                harness.tryInsert(s, e);
            } else {
                if (harness.exists(s)) harness.remove(s);
            }
        }

        Vm.Log[] memory logs = vm.getRecordedLogs();

        emit log_named_uint("total_logs", logs.length);
        for (uint256 i = 0; i < logs.length; ++i) {
            bytes32 sig = logs[i].topics.length > 0 ? logs[i].topics[0] : bytes32(0);
            if (sig == TRACE_INSERT_SIG) {
                // decode: (string step, uint256 key, uint256 cursor, uint256 parent, uint256 left, uint256 right, uint256 end, bool red)
                (string memory step, uint256 key, uint256 cursor, uint256 parent, uint256 left, uint256 right, uint256 end, bool red) = abi.decode(logs[i].data, (string,uint256,uint256,uint256,uint256,uint256,uint256,bool));
                emit log_named_string("insert_step", step);
                emit log_named_uint("  key", key);
                emit log_named_uint("  cursor", cursor);
                emit log_named_uint("  parent", parent);
                emit log_named_uint("  left", left);
                emit log_named_uint("  right", right);
                emit log_named_uint("  end", end);
                emit log_named_uint("  red", red ? 1 : 0);
            } else if (sig == TRACE_ROT_SIG) {
                // decode: (string step, uint256 key, uint256 cursor, uint256 cursorChild, uint256 parent)
                (string memory step, uint256 key, uint256 cursor, uint256 cursorChild, uint256 parent) = abi.decode(logs[i].data, (string,uint256,uint256,uint256,uint256));
                emit log_named_string("rot_step", step);
                emit log_named_uint("  key", key);
                emit log_named_uint("  cursor", cursor);
                emit log_named_uint("  cursorChild", cursorChild);
                emit log_named_uint("  parent", parent);
            }
        }
    }
}
