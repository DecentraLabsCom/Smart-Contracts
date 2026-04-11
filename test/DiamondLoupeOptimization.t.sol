// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.33;

import "forge-std/Test.sol";

import "../contracts/Diamond.sol";
import "../contracts/facets/diamond/DiamondCutFacet.sol";
import "../contracts/facets/diamond/DiamondLoupeFacet.sol";
import "../contracts/interfaces/IDiamond.sol";
import "../contracts/interfaces/IDiamondCut.sol";
import "../contracts/interfaces/IDiamondLoupe.sol";

contract DummyFacetA {
    function foo() external pure returns (uint256) {
        return 1;
    }

    function bar() external pure returns (uint256) {
        return 2;
    }
}

contract DummyFacetB {
    function foo() external pure returns (uint256) {
        return 3;
    }
}

contract DiamondLoupeOptimizationTest is Test {
    function test_materialized_loupe_tracks_add_replace_and_remove() public {
        address admin = address(0xA11CE);

        DiamondCutFacet diamondCutFacet = new DiamondCutFacet();
        DiamondLoupeFacet diamondLoupeFacet = new DiamondLoupeFacet();

        IDiamond.FacetCut[] memory initialCut = new IDiamond.FacetCut[](2);
        bytes4[] memory cutSelectors = new bytes4[](1);
        cutSelectors[0] = IDiamondCut.diamondCut.selector;
        initialCut[0] = IDiamond.FacetCut({
            facetAddress: address(diamondCutFacet), action: IDiamond.FacetCutAction.Add, functionSelectors: cutSelectors
        });

        bytes4[] memory loupeSelectors = new bytes4[](4);
        loupeSelectors[0] = IDiamondLoupe.facets.selector;
        loupeSelectors[1] = IDiamondLoupe.facetFunctionSelectors.selector;
        loupeSelectors[2] = IDiamondLoupe.facetAddresses.selector;
        loupeSelectors[3] = IDiamondLoupe.facetAddress.selector;
        initialCut[1] = IDiamond.FacetCut({
            facetAddress: address(diamondLoupeFacet),
            action: IDiamond.FacetCutAction.Add,
            functionSelectors: loupeSelectors
        });

        Diamond diamond = new Diamond(initialCut, DiamondArgs({owner: admin, init: address(0), initCalldata: ""}));

        DummyFacetA facetA = new DummyFacetA();
        bytes4[] memory selectorsA = new bytes4[](2);
        selectorsA[0] = DummyFacetA.foo.selector;
        selectorsA[1] = DummyFacetA.bar.selector;

        IDiamond.FacetCut[] memory addFacetA = new IDiamond.FacetCut[](1);
        addFacetA[0] = IDiamond.FacetCut({
            facetAddress: address(facetA), action: IDiamond.FacetCutAction.Add, functionSelectors: selectorsA
        });

        vm.prank(admin);
        IDiamondCut(address(diamond)).diamondCut(addFacetA, address(0), "");

        IDiamondLoupe loupe = IDiamondLoupe(address(diamond));

        bytes4[] memory facetASelectors = loupe.facetFunctionSelectors(address(facetA));
        assertEq(facetASelectors.length, 2);
        assertEq(facetASelectors[0], DummyFacetA.foo.selector);
        assertEq(facetASelectors[1], DummyFacetA.bar.selector);
        assertEq(loupe.facetAddress(DummyFacetA.foo.selector), address(facetA));

        DummyFacetB facetB = new DummyFacetB();
        bytes4[] memory replaceSelectors = new bytes4[](1);
        replaceSelectors[0] = DummyFacetB.foo.selector;
        IDiamond.FacetCut[] memory replaceCut = new IDiamond.FacetCut[](1);
        replaceCut[0] = IDiamond.FacetCut({
            facetAddress: address(facetB), action: IDiamond.FacetCutAction.Replace, functionSelectors: replaceSelectors
        });

        vm.prank(admin);
        IDiamondCut(address(diamond)).diamondCut(replaceCut, address(0), "");

        facetASelectors = loupe.facetFunctionSelectors(address(facetA));
        bytes4[] memory facetBSelectors = loupe.facetFunctionSelectors(address(facetB));
        assertEq(facetASelectors.length, 1);
        assertEq(facetASelectors[0], DummyFacetA.bar.selector);
        assertEq(facetBSelectors.length, 1);
        assertEq(facetBSelectors[0], DummyFacetB.foo.selector);
        assertEq(loupe.facetAddress(DummyFacetB.foo.selector), address(facetB));

        bytes4[] memory removeSelectors = new bytes4[](1);
        removeSelectors[0] = DummyFacetA.bar.selector;
        IDiamond.FacetCut[] memory removeCut = new IDiamond.FacetCut[](1);
        removeCut[0] = IDiamond.FacetCut({
            facetAddress: address(0), action: IDiamond.FacetCutAction.Remove, functionSelectors: removeSelectors
        });

        vm.prank(admin);
        IDiamondCut(address(diamond)).diamondCut(removeCut, address(0), "");

        facetASelectors = loupe.facetFunctionSelectors(address(facetA));
        assertEq(facetASelectors.length, 0);
        assertEq(loupe.facetAddress(DummyFacetA.bar.selector), address(0));

        address[] memory facetAddresses = loupe.facetAddresses();
        assertEq(facetAddresses.length, 3);
        assertFalse(_contains(facetAddresses, address(facetA)));
        assertTrue(_contains(facetAddresses, address(facetB)));

        IDiamondLoupe.Facet[] memory facets = loupe.facets();
        assertEq(facets.length, 3);
        assertFalse(_containsFacet(facets, address(facetA)));
        assertTrue(_containsFacet(facets, address(facetB)));
    }

    function _contains(
        address[] memory values,
        address target
    ) private pure returns (bool) {
        for (uint256 i; i < values.length;) {
            if (values[i] == target) {
                return true;
            }
            unchecked {
                ++i;
            }
        }
        return false;
    }

    function _containsFacet(
        IDiamondLoupe.Facet[] memory values,
        address target
    ) private pure returns (bool) {
        for (uint256 i; i < values.length;) {
            if (values[i].facetAddress == target) {
                return true;
            }
            unchecked {
                ++i;
            }
        }
        return false;
    }
}
