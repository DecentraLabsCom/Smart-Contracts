// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.33;

import {Test} from "forge-std/Test.sol";
import {IntentRegistryFacet} from "../contracts/facets/IntentRegistryFacet.sol";
import {IntentMeta, IntentState} from "../contracts/libraries/IntentTypes.sol";
import {AppStorage, LibAppStorage} from "../contracts/libraries/LibAppStorage.sol";

contract IntentExpiryHarness is IntentRegistryFacet {
    function seedExpired(
        bytes32 requestId
    ) external {
        AppStorage storage s = LibAppStorage.diamondStorage();
        s.intents[requestId] = IntentMeta({
            requestId: requestId,
            signer: address(0xBEEF),
            executor: address(0xCAFE),
            action: 8,
            payloadHash: bytes32(uint256(1)),
            nonce: 0,
            requestedAt: uint64(block.timestamp - 2),
            expiresAt: uint64(block.timestamp - 1),
            state: IntentState.Pending
        });
    }

    function storedIntentState(
        bytes32 requestId
    ) external view returns (IntentState) {
        return LibAppStorage.diamondStorage().intents[requestId].state;
    }
}

contract IntentExpiryTest is Test {
    function test_getIntent_derives_expired_state_without_reverting_or_writing() public {
        IntentExpiryHarness harness = new IntentExpiryHarness();
        bytes32 requestId = keccak256("expired-intent");
        vm.warp(100);
        harness.seedExpired(requestId);

        IntentMeta memory meta = harness.getIntent(requestId);
        assertEq(uint8(meta.state), uint8(IntentState.Expired));
    }

    function test_expireIntent_persists_state_and_emits_event() public {
        IntentExpiryHarness harness = new IntentExpiryHarness();
        bytes32 requestId = keccak256("materialized-expired-intent");
        vm.warp(100);
        harness.seedExpired(requestId);

        vm.expectEmit(true, true, false, false);
        emit IntentRegistryFacet.IntentExpired(requestId, address(0xBEEF));
        harness.expireIntent(requestId);

        assertEq(uint8(harness.storedIntentState(requestId)), uint8(IntentState.Expired));
    }
}
