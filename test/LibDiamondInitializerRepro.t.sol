// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.33;

import "forge-std/Test.sol";
import "./LibDiamondInitializer.t.sol";

contract LibDiamondInitializerRepro is Test {
    DiamondHarness diamond;
    MockFacet mockFacet;
    UnsafeExternalInitializer unsafeInit;

    event RevertData(bytes data);

    function setUp() public {
        diamond = new DiamondHarness();
        mockFacet = new MockFacet();
        unsafeInit = new UnsafeExternalInitializer();
    }

    /// @dev Deterministic repro: construct a small but non-empty cut and call via low-level call
    /// to capture the revert payload without letting Forge fail the test runner.
    function test_repro_initializeDiamondCut_smallCut() public {
        // Construct a cut with 3 facets and up to 4 selectors each (keeps output limited but non-trivial)
        IDiamond.FacetCut[] memory cut = new IDiamond.FacetCut[](3);

        bytes4[] memory sel0 = new bytes4[](2);
        sel0[0] = MockFacet.initialize.selector;
        sel0[1] = bytes4(0xdeadbeef);
        cut[0] = IDiamond.FacetCut({
            facetAddress: address(mockFacet), action: IDiamond.FacetCutAction.Add, functionSelectors: sel0
        });

        bytes4[] memory sel1 = new bytes4[](1);
        sel1[0] = bytes4(0x8be0079c);
        cut[1] = IDiamond.FacetCut({
            facetAddress: address(0x1234), action: IDiamond.FacetCutAction.Add, functionSelectors: sel1
        });

        bytes4[] memory sel2 = new bytes4[](3);
        sel2[0] = bytes4(0x94499827);
        sel2[1] = bytes4(0x0e4562a1);
        sel2[2] = bytes4(0x057c384a);
        cut[2] = IDiamond.FacetCut({
            facetAddress: address(0xBEEF), action: IDiamond.FacetCutAction.Add, functionSelectors: sel2
        });

        // Use UnsafeExternalInitializer (no isInitializer marker) to provoke the "not allowed" path
        bytes memory initData = abi.encodeWithSelector(UnsafeExternalInitializer.init.selector);

        // Low-level call to capture the revert bytes instead of letting the test framework fail directly
        (bool ok, bytes memory data) = address(diamond)
            .call(abi.encodeWithSelector(diamond.callInitializeDiamondCut.selector, address(unsafeInit), initData, cut));

        // We expect it to revert (no marker and init not present in cut)
        assertFalse(ok, "call should have reverted");
        emit RevertData(data);
    }
}
