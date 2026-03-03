// SPDX-License-Identifier: GPL-3.0-or-later
pragma solidity ^0.8.33;

import "forge-std/Script.sol";
import {IDiamond} from "../contracts/interfaces/IDiamond.sol";
import {IDiamondCut} from "../contracts/interfaces/IDiamondCut.sol";
import {LabQueryFacet} from "../contracts/facets/lab/LabQueryFacet.sol";

/**
 * @title UpgradeLabQueryFacet
 * @notice Foundry script to deploy a new LabQueryFacet and apply a diamondCut
 *         that replaces existing selectors and adds `getLabResourceType()`.
 *
 * Usage (dry-run):
 *   forge script script/UpgradeLabQueryFacet.s.sol --rpc-url $RPC_URL -vvv
 *
 * Usage (broadcast):
 *   forge script script/UpgradeLabQueryFacet.s.sol --rpc-url $RPC_URL --broadcast --private-key $PK
 *
 * Environment variables:
 *   DIAMOND_ADDRESS  — address of the deployed Diamond proxy
 */
contract UpgradeLabQueryFacet is Script {
    function run() external {
        address diamond = vm.envAddress("DIAMOND_ADDRESS");

        vm.startBroadcast();

        // 1. Deploy new facet
        LabQueryFacet newFacet = new LabQueryFacet();
        console.log("LabQueryFacet deployed at:", address(newFacet));

        // 2. Build selector arrays
        // Existing selectors to REPLACE (already in the Diamond)
        bytes4[] memory replaceSelectors = new bytes4[](9);
        replaceSelectors[0] = LabQueryFacet.getLab.selector;
        replaceSelectors[1] = LabQueryFacet.getLabsPaginated.selector;
        replaceSelectors[2] = LabQueryFacet.getLabCount.selector;
        replaceSelectors[3] = LabQueryFacet.isLabListed.selector;
        replaceSelectors[4] = LabQueryFacet.getLabPrice.selector;
        replaceSelectors[5] = LabQueryFacet.getLabAuthURI.selector;
        replaceSelectors[6] = LabQueryFacet.getLabAccessURI.selector;
        replaceSelectors[7] = LabQueryFacet.getLabAccessKey.selector;
        replaceSelectors[8] = LabQueryFacet.getLabAge.selector;

        // New selectors to ADD
        bytes4[] memory addSelectors = new bytes4[](1);
        addSelectors[0] = LabQueryFacet.getLabResourceType.selector;

        // 3. Build FacetCut array
        IDiamond.FacetCut[] memory cuts = new IDiamond.FacetCut[](2);
        cuts[0] = IDiamond.FacetCut({
            facetAddress: address(newFacet),
            action: IDiamond.FacetCutAction.Replace,
            functionSelectors: replaceSelectors
        });
        cuts[1] = IDiamond.FacetCut({
            facetAddress: address(newFacet),
            action: IDiamond.FacetCutAction.Add,
            functionSelectors: addSelectors
        });

        // 4. Execute diamondCut
        IDiamondCut(diamond).diamondCut(cuts, address(0), "");
        console.log("diamondCut executed - LabQueryFacet upgraded with getLabResourceType()");

        vm.stopBroadcast();
    }
}
