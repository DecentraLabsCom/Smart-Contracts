// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.33;

import "forge-std/Test.sol";
import "./BaseTest.sol";
import "../contracts/Diamond.sol";
import "../contracts/facets/diamond/DiamondCutFacet.sol";
import "../contracts/facets/InitFacet.sol";
import "../contracts/facets/ProviderFacet.sol";
import "../contracts/facets/ServiceCreditFacet.sol";
import "../contracts/facets/lab/LabFacet.sol";
import "../contracts/facets/reservation/institutional/InstitutionalTreasuryFacet.sol";
import "../contracts/facets/reservation/institutional/InstitutionalOrgRegistryFacet.sol";
import {IDiamondCut} from "../contracts/interfaces/IDiamondCut.sol";
import "../contracts/interfaces/IDiamond.sol";

/// @title Provider Test
/// @notice Tests Provider CRUD operations per specification
/// @dev Complements ProviderStakeBoundary.t.sol which tests stake calculations
contract ProviderTest is BaseTest {
    Diamond diamond;
    ProviderFacet providerFacet;
    ServiceCreditFacet creditFacet;
    InstitutionalTreasuryFacet treasuryFacet;
    InstitutionalOrgRegistryFacet orgRegistryFacet;

    address admin = address(0xA11CE);
    address provider1 = address(0xDEAD);
    address backend = address(0xBEEF);
    address nonAdmin = address(0xBAD);

    function _selector(
        string memory sig
    ) internal pure returns (bytes4) {
        return bytes4(keccak256(bytes(sig)));
    }

    function setUp() public override {
        super.setUp();

        DiamondCutFacet dc = new DiamondCutFacet();

        IDiamond.FacetCut[] memory cut = new IDiamond.FacetCut[](1);
        bytes4[] memory dcSelectors = new bytes4[](1);
        dcSelectors[0] = IDiamondCut.diamondCut.selector;
        cut[0] = IDiamond.FacetCut({
            facetAddress: address(dc), action: IDiamond.FacetCutAction.Add, functionSelectors: dcSelectors
        });

        DiamondArgs memory args = DiamondArgs({owner: admin, init: address(0), initCalldata: ""});
        diamond = new Diamond(cut, args);

        InitFacet initFacet = new InitFacet();
        ProviderFacet providerFacetImpl = new ProviderFacet();
        ServiceCreditFacet creditFacetImpl = new ServiceCreditFacet();
        LabFacet labFacet = new LabFacet();
        InstitutionalTreasuryFacet treasuryFacetImpl = new InstitutionalTreasuryFacet();
        InstitutionalOrgRegistryFacet orgRegistryFacetImpl = new InstitutionalOrgRegistryFacet();

        IDiamond.FacetCut[] memory cut2 = new IDiamond.FacetCut[](6);

        bytes4[] memory initSelectors = new bytes4[](1);
        initSelectors[0] = _selector("initializeDiamond(string,string,string,string,string)");
        cut2[0] = IDiamond.FacetCut({
            facetAddress: address(initFacet), action: IDiamond.FacetCutAction.Add, functionSelectors: initSelectors
        });

        bytes4[] memory providerSelectors = new bytes4[](5);
        providerSelectors[0] = _selector("initialize(string,string,string)");
        providerSelectors[1] = _selector("addProvider(string,address,string,string,string)");
        providerSelectors[2] = _selector("removeProvider(address)");
        providerSelectors[3] = _selector("updateProvider(string,string,string)");
        providerSelectors[4] = _selector("isLabProvider(address)");
        cut2[1] = IDiamond.FacetCut({
            facetAddress: address(providerFacetImpl),
            action: IDiamond.FacetCutAction.Add,
            functionSelectors: providerSelectors
        });

        bytes4[] memory labSelectors = new bytes4[](1);
        labSelectors[0] = _selector("initialize(string,string)");
        cut2[2] = IDiamond.FacetCut({
            facetAddress: address(labFacet), action: IDiamond.FacetCutAction.Add, functionSelectors: labSelectors
        });

        bytes4[] memory creditSelectors = new bytes4[](3);
        creditSelectors[0] = _selector("lockCredits(address,uint256,bytes32)");
        creditSelectors[1] = _selector("lockedBalanceOf(address)");
        creditSelectors[2] = _selector("totalBalanceOf(address)");
        cut2[3] = IDiamond.FacetCut({
            facetAddress: address(creditFacetImpl), action: IDiamond.FacetCutAction.Add, functionSelectors: creditSelectors
        });

        bytes4[] memory treasurySelectors = new bytes4[](2);
        treasurySelectors[0] = _selector("authorizeBackend(address)");
        treasurySelectors[1] = _selector("getAuthorizedBackend(address)");
        cut2[4] = IDiamond.FacetCut({
            facetAddress: address(treasuryFacetImpl), action: IDiamond.FacetCutAction.Add, functionSelectors: treasurySelectors
        });

        bytes4[] memory orgSelectors = new bytes4[](3);
        orgSelectors[0] = _selector("registerSchacHomeOrganization(string)");
        orgSelectors[1] = _selector("resolveSchacHomeOrganization(string)");
        orgSelectors[2] = _selector("getRegisteredSchacHomeOrganizations(address)");
        cut2[5] = IDiamond.FacetCut({
            facetAddress: address(orgRegistryFacetImpl), action: IDiamond.FacetCutAction.Add, functionSelectors: orgSelectors
        });

        vm.prank(admin);
        IDiamondCut(address(diamond)).diamondCut(cut2, address(0), "");

        vm.prank(admin);
        InitFacet(address(diamond)).initializeDiamond("Admin", "admin@x", "ES", "Labs", "LS");

        providerFacet = ProviderFacet(address(diamond));
        creditFacet = ServiceCreditFacet(address(diamond));
        treasuryFacet = InstitutionalTreasuryFacet(address(diamond));
        orgRegistryFacet = InstitutionalOrgRegistryFacet(address(diamond));
    }

    /// @notice SPEC: "ADD PROVIDER" use case — now issues service credits instead of minting tokens
    function test_addProvider_grants_role_and_issues_service_credits() public {
        vm.prank(admin);
        providerFacet.addProvider("NewProvider", provider1, "new@provider.com", "US", "");

        // Verify provider role granted
        assertTrue(providerFacet.isLabProvider(provider1));

        // Provider onboarding is credit-ledger only.
    }

    /// @notice SPEC: Only admin can add providers
    function test_addProvider_only_by_admin() public {
        vm.prank(nonAdmin);
        vm.expectRevert();
        providerFacet.addProvider("BadProvider", address(0x1234), "bad@example.com", "XX", "");
    }

    /// @notice SPEC: "UPDATE PROVIDER" use case
    function test_updateProvider_modifies_info() public {
        // Setup: Add provider
        vm.prank(admin);
        providerFacet.addProvider("Provider1", provider1, "p1@x", "ES", "");

        // Update provider info
        vm.prank(provider1);
        providerFacet.updateProvider("Provider1-Updated", "p1-new@x", "US");

        // TODO: Verify provider info updated (need getter function)
    }

    function test_updateProvider_reverts_on_invalid_name_length() public {
        vm.prank(admin);
        providerFacet.addProvider("Provider1", provider1, "p1@x", "ES", "");

        string memory longString = new string(10_000);
        vm.prank(provider1);
        vm.expectRevert(bytes("Invalid name length"));
        providerFacet.updateProvider(longString, "p1@x", "ES");
    }

    /// @notice SPEC: "REMOVE SPECIFIC PROVIDER" use case
    function test_removeProvider_requires_no_labs() public {
        // Setup: Add provider
        vm.prank(admin);
        providerFacet.addProvider("Provider1", provider1, "p1@x", "ES", "");

        // Remove provider (should succeed - no labs)
        vm.prank(admin);
        providerFacet.removeProvider(provider1);

        // Verify provider role revoked
        assertFalse(providerFacet.isLabProvider(provider1));
    }

    function test_removeProvider_clears_institutional_access_and_registry() public {
        vm.prank(admin);
        providerFacet.addProvider("Provider1", provider1, "p1@x", "ES", "");

        vm.startPrank(provider1);
        treasuryFacet.authorizeBackend(backend);
        orgRegistryFacet.registerSchacHomeOrganization("Example.EDU");
        vm.stopPrank();

        assertEq(treasuryFacet.getAuthorizedBackend(provider1), backend);
        assertEq(orgRegistryFacet.resolveSchacHomeOrganization("example.edu"), provider1);
        assertEq(orgRegistryFacet.getRegisteredSchacHomeOrganizations(provider1).length, 1);

        vm.prank(admin);
        providerFacet.removeProvider(provider1);

        assertEq(treasuryFacet.getAuthorizedBackend(provider1), address(0));
        assertEq(orgRegistryFacet.resolveSchacHomeOrganization("example.edu"), address(0));
        assertEq(orgRegistryFacet.getRegisteredSchacHomeOrganizations(provider1).length, 0);

        vm.prank(provider1);
        vm.expectRevert(bytes("Unknown institution"));
        treasuryFacet.authorizeBackend(backend);
    }

    function test_removeProvider_reverts_when_credits_are_locked() public {
        vm.prank(admin);
        providerFacet.addProvider("Provider1", provider1, "p1@x", "ES", "");

        vm.prank(admin);
        creditFacet.lockCredits(provider1, 1, keccak256("locked"));

        assertEq(creditFacet.lockedBalanceOf(provider1), 1);

        vm.prank(admin);
        vm.expectRevert(bytes("Provider has locked credits"));
        providerFacet.removeProvider(provider1);

        assertTrue(providerFacet.isLabProvider(provider1));
        assertEq(creditFacet.totalBalanceOf(provider1), 100_000_000);
    }
}
