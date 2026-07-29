// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.33;

import {Test} from "forge-std/Test.sol";
import {Diamond, DiamondArgs} from "../contracts/Diamond.sol";
import {IDiamondCut} from "../contracts/interfaces/IDiamondCut.sol";
import {IDiamond} from "../contracts/interfaces/IDiamond.sol";
import {DiamondCutFacet} from "../contracts/facets/diamond/DiamondCutFacet.sol";
import {IntentRegistryFacet} from "../contracts/facets/IntentRegistryFacet.sol";
import {IntentMeta, IntentState} from "../contracts/libraries/IntentTypes.sol";
import {AppStorage, LibAppStorage} from "../contracts/libraries/LibAppStorage.sol";

/// @dev Test-only seeding facet. The production Diamond never exposes this selector.
contract IntentLifecycleSeedFacet {
    function seedIntent(
        bytes32 requestId,
        address signer,
        uint8 state,
        uint64 expiresAt
    ) external {
        AppStorage storage s = LibAppStorage.diamondStorage();
        s.intents[requestId] = IntentMeta({
            requestId: requestId,
            signer: signer,
            executor: signer,
            action: 8,
            payloadHash: bytes32(uint256(1)),
            nonce: 0,
            requestedAt: uint64(block.timestamp),
            expiresAt: expiresAt,
            state: IntentState(state)
        });
    }

    function storedState(
        bytes32 requestId
    ) external view returns (uint8) {
        return uint8(LibAppStorage.diamondStorage().intents[requestId].state);
    }
}

contract IntentLifecycleIntegrationTest is Test {
    Diamond internal diamond;
    IntentRegistryFacet internal registry;
    IntentLifecycleSeedFacet internal seed;
    address internal signer = makeAddr("intent-signer");

    function setUp() public {
        DiamondCutFacet cutFacet = new DiamondCutFacet();
        IDiamond.FacetCut[] memory initialCut = new IDiamond.FacetCut[](1);
        bytes4[] memory cutSelectors = new bytes4[](1);
        cutSelectors[0] = IDiamondCut.diamondCut.selector;
        initialCut[0] = IDiamond.FacetCut({
            facetAddress: address(cutFacet), action: IDiamond.FacetCutAction.Add, functionSelectors: cutSelectors
        });

        diamond = new Diamond(initialCut, DiamondArgs({owner: address(this), init: address(0), initCalldata: ""}));

        IntentRegistryFacet registryFacet = new IntentRegistryFacet();
        IntentLifecycleSeedFacet seedFacet = new IntentLifecycleSeedFacet();
        IDiamond.FacetCut[] memory lifecycleCut = new IDiamond.FacetCut[](2);

        bytes4[] memory registrySelectors = new bytes4[](3);
        registrySelectors[0] = IntentRegistryFacet.getIntent.selector;
        registrySelectors[1] = IntentRegistryFacet.cancelIntent.selector;
        registrySelectors[2] = IntentRegistryFacet.expireIntent.selector;
        lifecycleCut[0] = IDiamond.FacetCut({
            facetAddress: address(registryFacet),
            action: IDiamond.FacetCutAction.Add,
            functionSelectors: registrySelectors
        });

        bytes4[] memory seedSelectors = new bytes4[](2);
        seedSelectors[0] = IntentLifecycleSeedFacet.seedIntent.selector;
        seedSelectors[1] = IntentLifecycleSeedFacet.storedState.selector;
        lifecycleCut[1] = IDiamond.FacetCut({
            facetAddress: address(seedFacet), action: IDiamond.FacetCutAction.Add, functionSelectors: seedSelectors
        });

        IDiamondCut(address(diamond)).diamondCut(lifecycleCut, address(0), "");
        registry = IntentRegistryFacet(address(diamond));
        seed = IntentLifecycleSeedFacet(address(diamond));
    }

    function test_realDiamond_reads_every_intent_state_value() public {
        vm.warp(100);
        for (uint8 state = 0; state <= uint8(IntentState.Expired); state++) {
            bytes32 requestId = keccak256(abi.encode("read-state", state));
            uint64 expiresAt = state == uint8(IntentState.Pending) ? 200 : 99;
            seed.seedIntent(requestId, signer, state, expiresAt);

            IntentMeta memory intent = registry.getIntent(requestId);
            assertEq(uint8(intent.state), state);
        }
    }

    function test_realDiamond_cancels_pending_and_cannot_cancel_executed() public {
        vm.warp(100);
        bytes32 pendingId = keccak256("cancel-pending");
        seed.seedIntent(pendingId, signer, uint8(IntentState.Pending), 200);

        vm.prank(signer);
        registry.cancelIntent(pendingId);
        assertEq(uint8(registry.getIntent(pendingId).state), uint8(IntentState.Cancelled));

        bytes32 executedId = keccak256("cancel-executed");
        seed.seedIntent(executedId, signer, uint8(IntentState.Executed), 200);
        vm.prank(signer);
        vm.expectRevert();
        registry.cancelIntent(executedId);
        assertEq(uint8(registry.getIntent(executedId).state), uint8(IntentState.Executed));
    }

    function test_realDiamond_materializes_expiry() public {
        vm.warp(100);
        bytes32 requestId = keccak256("expire-pending");
        seed.seedIntent(requestId, signer, uint8(IntentState.Pending), 99);

        assertEq(uint8(registry.getIntent(requestId).state), uint8(IntentState.Expired));
        registry.expireIntent(requestId);
        assertEq(seed.storedState(requestId), uint8(IntentState.Expired));
    }
}
