// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.33;

import "forge-std/Test.sol";
import "./BaseTest.sol";
import "../contracts/Diamond.sol";
import "../contracts/facets/diamond/DiamondCutFacet.sol";
import "../contracts/facets/InitFacet.sol";
import "../contracts/facets/ProviderFacet.sol";
import "../contracts/facets/lab/LabFacet.sol";
import "../contracts/facets/lab/LabAdminFacet.sol";
import "../contracts/facets/lab/LabQueryFacet.sol";
import "../contracts/external/LabERC20.sol";
import {IDiamondCut} from "../contracts/interfaces/IDiamondCut.sol";
import "../contracts/interfaces/IDiamond.sol";

/// @title LabAdmin Test
/// @notice Tests Lab CRUD operations per specification
/// @dev Tests addLab, updateLab, deleteLab, listLab, unlistLab
contract LabAdminTest is BaseTest {
    Diamond diamond;
    LabAdminFacet labAdmin;
    LabFacet labFacet;
    LabQueryFacet labQuery;
    ProviderFacet providerFacet;
    LabERC20 token;

    address admin = address(0xA11CE);
    address provider1 = address(0xDEAD);
    address provider2 = address(0xBEEF);
    address nonProvider = address(0xBAD);

    function _selector(
        string memory sig
    ) internal pure returns (bytes4) {
        return bytes4(keccak256(bytes(sig)));
    }

    function setUp() public override {
        super.setUp();

        // TODO: Deploy diamond with all Lab facets (similar to LabSecurity setup)
        // Add LabAdminFacet, LabQueryFacet selectors
        // Initialize diamond
        // Add providers
    }

    /// @notice SPEC: "ADD LAB" use case
    function test_addLab_creates_nft_with_metadata() public {
        vm.prank(provider1);
        labAdmin.addLab("ipfs://lab-metadata", 100 ether, "https://access.example.com", "accessKey123");

        // Verify NFT was minted
        assertEq(labFacet.ownerOf(1), provider1);

        // TODO: Verify metadata stored correctly
        // Lab memory lab = labQuery.getLab(1);
        // assertEq(lab.uri, "ipfs://lab-metadata");
        // assertEq(lab.price, 100 ether);
    }

    /// @notice SPEC: Precondition "Caller must be the lab provider"
    function test_addLab_requires_provider_role() public {
        vm.prank(nonProvider);
        vm.expectRevert();
        labAdmin.addLab("ipfs://metadata", 100 ether, "https://access.example.com", "key");
    }

    /// @notice SPEC: "UPDATE LAB" use case
    function test_updateLab_modifies_metadata() public {
        // Setup: Create lab
        vm.prank(provider1);
        labAdmin.addLab("uri1", 100 ether, "access1", "key1");

        // Update lab
        vm.prank(provider1);
        labAdmin.updateLab(1, "uri2", 200 ether, "access2", "key2");

        // TODO: Verify metadata updated
        // Lab memory lab = labQuery.getLab(1);
        // assertEq(lab.uri, "uri2");
        // assertEq(lab.price, 200 ether);
    }

    /// @notice SPEC: Only lab owner can update
    function test_updateLab_only_by_owner() public {
        // Setup: Provider1 creates lab
        vm.prank(provider1);
        labAdmin.addLab("uri1", 100 ether, "access1", "key1");

        // Provider2 cannot update Provider1's lab
        vm.prank(provider2);
        vm.expectRevert();
        labAdmin.updateLab(1, "uri2", 200 ether, "access2", "key2");
    }

    /// @notice SPEC: "DELETE LAB" use case
    function test_deleteLab_removes_nft() public {
        // Setup: Create lab
        vm.prank(provider1);
        labAdmin.addLab("uri1", 100 ether, "access1", "key1");

        // Delete lab
        vm.prank(provider1);
        labAdmin.deleteLab(1);

        // Verify NFT burned
        vm.expectRevert();
        labFacet.ownerOf(1);
    }

    /// @notice Test listing lab for reservations
    function test_listLab_makes_available() public {
        // Setup: Create lab
        vm.prank(provider1);
        labAdmin.addLab("uri1", 100 ether, "access1", "key1");

        // List lab
        vm.prank(provider1);
        labAdmin.listLab(1);

        // TODO: Verify lab is listed (check storage state)
    }

    /// @notice Test unlisting lab
    function test_unlistLab_makes_unavailable() public {
        // Setup: Create and list lab
        vm.prank(provider1);
        labAdmin.addLab("uri1", 100 ether, "access1", "key1");
        vm.prank(provider1);
        labAdmin.listLab(1);

        // Unlist lab
        vm.prank(provider1);
        labAdmin.unlistLab(1);

        // TODO: Verify lab is unlisted
    }
}
