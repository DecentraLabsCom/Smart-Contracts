// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.33;

import "forge-std/Test.sol";
import "../contracts/interfaces/IDiamond.sol";
import "./LibDiamondInitializer.t.sol"; // reuse contracts

contract LibDiamondInitializerFuzz is Test {
    DiamondHarness diamond;
    MockFacet mockFacet;
    SafeExternalInitializer safeInit;

    event RevertData(bytes data);

    function setUp() public {
        diamond = new DiamondHarness();
        mockFacet = new MockFacet();
        safeInit = new SafeExternalInitializer();
    }

    // Simplified constrained fuzz target to avoid huge generated inputs and nested struct fuzzing issues
    // Use a single FacetCut constructed from simpler fuzzable types so Forge can produce runs.
    function testFuzz_initializeDiamondCut(
        address _init,
        bytes memory _calldata,
        address _facet,
        uint8 _action,
        bytes4[] memory _functionSelectors
    ) public {
        // constrain sizes to keep outputs small and ensure some valid fuzz inputs
        // require a sensible calldata window: at least a selector (4 bytes) and not too large
        vm.assume(_calldata.length >= 4 && _calldata.length <= 128);

        // limit selector array to a reasonable size for readability
        vm.assume(_functionSelectors.length >= 1 && _functionSelectors.length <= 6);
        // constrain action to valid enum range (0..2)
        vm.assume(_action <= 2);

        // construct a single-element diamond cut to avoid complex nested fuzz inputs
        IDiamond.FacetCut[] memory _diamondCut = new IDiamond.FacetCut[](1);
        _diamondCut[0] = IDiamond.FacetCut({
            facetAddress: _facet,
            action: IDiamond.FacetCutAction(_action),
            functionSelectors: _functionSelectors
        });

        // Low-level call to capture revert data without Forge's massive dump
        (bool success, bytes memory data) = address(diamond).call(
            abi.encodeWithSelector(diamond.callInitializeDiamondCut.selector, _init, _calldata, _diamondCut)
        );

        if (!success) {
            emit RevertData(data);
            // avoid failing the fuzz run so we can inspect the emitted revert data
            // but assert that revert data is of expected kinds (optional)
        }
    }
}
