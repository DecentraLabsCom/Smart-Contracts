// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.33;

import "forge-std/Test.sol";
import {Diamond} from "../contracts/Diamond.sol";
import {IDiamondLoupe} from "../contracts/interfaces/IDiamondLoupe.sol";
import {ProviderFacet} from "../contracts/facets/ProviderFacet.sol";
import {LabFacet} from "../contracts/facets/lab/LabFacet.sol";
import {LabAdminFacet} from "../contracts/facets/lab/LabAdminFacet.sol";
import {LabQueryFacet} from "../contracts/facets/lab/LabQueryFacet.sol";
import {FullDiamondFixture} from "./FullDiamondFixture.sol";

/// @notice Proxy-level smoke tests for the complete production selector cut.
contract FullDiamondSurfaceIntegrationTest is Test, FullDiamondFixture {
    Diamond internal diamond;

    function setUp() public {
        diamond = _deployFullDiamond();
    }

    function test_fullProductionCut_routes_every_manifest_selector() public view {
        IDiamondLoupe loupe = IDiamondLoupe(address(diamond));
        IDiamondLoupe.Facet[] memory materialized = loupe.facets();
        uint256 selectorCount;

        assertEq(materialized.length, PRODUCTION_FACET_COUNT);

        for (uint256 facetIndex; facetIndex < materialized.length; facetIndex++) {
            bytes4[] memory selectors = loupe.facetFunctionSelectors(materialized[facetIndex].facetAddress);
            assertEq(selectors.length, materialized[facetIndex].functionSelectors.length);

            for (uint256 selectorIndex; selectorIndex < selectors.length; selectorIndex++) {
                assertEq(loupe.facetAddress(selectors[selectorIndex]), materialized[facetIndex].facetAddress);
                selectorCount++;
            }
        }

        assertEq(selectorCount, PRODUCTION_SELECTOR_COUNT);
    }

    function test_fullDiamond_state_flows_across_provider_lab_and_query_facets() public {
        address provider = makeAddr("full-surface-provider");
        bytes32 creatorPucHash = keccak256("full-surface-creator");

        ProviderFacet(address(diamond)).addProvider("Provider", provider, "provider@example.test", "ES", "");
        assertTrue(ProviderFacet(address(diamond)).isLabProvider(provider));

        vm.prank(provider);
        LabAdminFacet(address(diamond))
            .addAndListLabWithPucHash(
                "ipfs://full-surface-lab",
                100,
                "https://provider.example.test/auth",
                "lab-access-key",
                0,
                creatorPucHash
            );

        assertEq(LabQueryFacet(address(diamond)).getLabCount(), 1);
        assertTrue(LabQueryFacet(address(diamond)).isLabListed(1));
        assertEq(LabFacet(address(diamond)).ownerOf(1), provider);
        assertEq(LabQueryFacet(address(diamond)).getPucHash(1), creatorPucHash);
    }
}
