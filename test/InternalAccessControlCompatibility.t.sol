// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.33;

import {Test} from "forge-std/Test.sol";
import {AccessControlUpgradeable} from "@openzeppelin/contracts-upgradeable/access/AccessControlUpgradeable.sol";
import {Diamond, DiamondArgs} from "../contracts/Diamond.sol";
import {ProviderFacet} from "../contracts/facets/ProviderFacet.sol";
import {DiamondCutFacet} from "../contracts/facets/diamond/DiamondCutFacet.sol";
import {IDiamond} from "../contracts/interfaces/IDiamond.sol";
import {IDiamondCut} from "../contracts/interfaces/IDiamondCut.sol";
import {PROVIDER_ROLE} from "../contracts/libraries/LibAppStorage.sol";

contract LegacyAccessControlFacet is AccessControlUpgradeable {
    function initializeLegacy(
        address admin
    ) external initializer {
        _grantRole(DEFAULT_ADMIN_ROLE, admin);
    }
}

contract InternalAccessControlCompatibilityTest is Test {
    address private constant ADMIN = address(0xA11CE);
    address private constant PROVIDER = address(0xBEEF);

    function test_providerFacet_preservesOpenZeppelinRoleStorage_withoutGenericRoleSelectors() public {
        DiamondCutFacet cutFacet = new DiamondCutFacet();
        IDiamond.FacetCut[] memory initialCut = new IDiamond.FacetCut[](1);
        bytes4[] memory cutSelectors = new bytes4[](1);
        cutSelectors[0] = IDiamondCut.diamondCut.selector;
        initialCut[0] = IDiamond.FacetCut({
            facetAddress: address(cutFacet), action: IDiamond.FacetCutAction.Add, functionSelectors: cutSelectors
        });
        Diamond diamond = new Diamond(initialCut, DiamondArgs({owner: ADMIN, init: address(0), initCalldata: ""}));

        LegacyAccessControlFacet legacy = new LegacyAccessControlFacet();
        bytes4[] memory legacySelectors = new bytes4[](5);
        legacySelectors[0] = LegacyAccessControlFacet.initializeLegacy.selector;
        legacySelectors[1] = _selector("DEFAULT_ADMIN_ROLE()");
        legacySelectors[2] = _selector("hasRole(bytes32,address)");
        legacySelectors[3] = _selector("getRoleAdmin(bytes32)");
        legacySelectors[4] = _selector("grantRole(bytes32,address)");
        _cut(diamond, address(legacy), IDiamond.FacetCutAction.Add, legacySelectors);

        vm.prank(ADMIN);
        LegacyAccessControlFacet(address(diamond)).initializeLegacy(ADMIN);
        assertTrue(LegacyAccessControlFacet(address(diamond)).hasRole(bytes32(0), ADMIN));

        ProviderFacet providerFacet = new ProviderFacet();
        IDiamond.FacetCut[] memory upgrade = new IDiamond.FacetCut[](3);
        bytes4[] memory replacementSelectors = new bytes4[](3);
        replacementSelectors[0] = _selector("DEFAULT_ADMIN_ROLE()");
        replacementSelectors[1] = _selector("hasRole(bytes32,address)");
        replacementSelectors[2] = _selector("getRoleAdmin(bytes32)");
        upgrade[0] = IDiamond.FacetCut({
            facetAddress: address(providerFacet),
            action: IDiamond.FacetCutAction.Replace,
            functionSelectors: replacementSelectors
        });
        bytes4[] memory addedSelectors = new bytes4[](2);
        addedSelectors[0] = ProviderFacet.addProvider.selector;
        addedSelectors[1] = ProviderFacet.isLabProvider.selector;
        upgrade[1] = IDiamond.FacetCut({
            facetAddress: address(providerFacet), action: IDiamond.FacetCutAction.Add, functionSelectors: addedSelectors
        });
        bytes4[] memory removedSelectors = new bytes4[](1);
        removedSelectors[0] = _selector("grantRole(bytes32,address)");
        upgrade[2] = IDiamond.FacetCut({
            facetAddress: address(0), action: IDiamond.FacetCutAction.Remove, functionSelectors: removedSelectors
        });
        vm.prank(ADMIN);
        IDiamondCut(address(diamond)).diamondCut(upgrade, address(0), "");

        assertTrue(ProviderFacet(address(diamond)).hasRole(bytes32(0), ADMIN));
        assertEq(ProviderFacet(address(diamond)).getRoleAdmin(PROVIDER_ROLE), bytes32(0));

        vm.prank(ADMIN);
        ProviderFacet(address(diamond)).addProvider("Provider", PROVIDER, "provider@example.org", "ES", "");
        assertTrue(ProviderFacet(address(diamond)).hasRole(PROVIDER_ROLE, PROVIDER));
        assertTrue(ProviderFacet(address(diamond)).isLabProvider(PROVIDER));
    }

    function _cut(
        Diamond diamond,
        address facet,
        IDiamond.FacetCutAction action,
        bytes4[] memory selectors
    ) private {
        IDiamond.FacetCut[] memory cuts = new IDiamond.FacetCut[](1);
        cuts[0] = IDiamond.FacetCut({facetAddress: facet, action: action, functionSelectors: selectors});
        vm.prank(ADMIN);
        IDiamondCut(address(diamond)).diamondCut(cuts, address(0), "");
    }

    function _selector(
        string memory signature
    ) private pure returns (bytes4) {
        return bytes4(keccak256(bytes(signature)));
    }
}
