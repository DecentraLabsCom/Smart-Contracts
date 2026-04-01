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

    address admin = address(0xA11CE);
    address provider1 = address(0xDEAD);
    address provider2 = address(0xBEEF);
    address nonProvider = address(0xBAD);

    uint96 constant PRICE_100 = 10_000_000;
    uint96 constant PRICE_200 = 20_000_000;

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
        LabFacet labFacetImpl = new LabFacet();
        LabAdminFacet labAdminImpl = new LabAdminFacet();
        LabQueryFacet labQueryImpl = new LabQueryFacet();

        IDiamond.FacetCut[] memory cut2 = new IDiamond.FacetCut[](5);

        bytes4[] memory initSelectors = new bytes4[](1);
        initSelectors[0] = _selector("initializeDiamond(string,string,string,string,string)");
        cut2[0] = IDiamond.FacetCut({
            facetAddress: address(initFacet), action: IDiamond.FacetCutAction.Add, functionSelectors: initSelectors
        });

        bytes4[] memory providerSelectors = new bytes4[](3);
        providerSelectors[0] = _selector("initialize(string,string,string)");
        providerSelectors[1] = _selector("addProvider(string,address,string,string,string)");
        providerSelectors[2] = _selector("isLabProvider(address)");
        cut2[1] = IDiamond.FacetCut({
            facetAddress: address(providerFacetImpl),
            action: IDiamond.FacetCutAction.Add,
            functionSelectors: providerSelectors
        });

        bytes4[] memory labSelectors = new bytes4[](6);
        labSelectors[0] = _selector("initialize(string,string)");
        labSelectors[1] = _selector("safeMintTo(address,uint256)");
        labSelectors[2] = _selector("burnToken(uint256)");
        labSelectors[3] = _selector("ownerOf(uint256)");
        labSelectors[4] = _selector("tokenURI(uint256)");
        labSelectors[5] = _selector("calculateRequiredStake(address,uint256)");
        cut2[2] = IDiamond.FacetCut({
            facetAddress: address(labFacetImpl), action: IDiamond.FacetCutAction.Add, functionSelectors: labSelectors
        });

        bytes4[] memory labAdminSelectors = new bytes4[](5);
        labAdminSelectors[0] = _selector("addLab(string,uint96,string,string,uint8)");
        labAdminSelectors[1] = _selector("updateLab(uint256,string,uint96,string,string,uint8)");
        labAdminSelectors[2] = _selector("deleteLab(uint256)");
        labAdminSelectors[3] = _selector("listLab(uint256)");
        labAdminSelectors[4] = _selector("unlistLab(uint256)");
        cut2[3] = IDiamond.FacetCut({
            facetAddress: address(labAdminImpl),
            action: IDiamond.FacetCutAction.Add,
            functionSelectors: labAdminSelectors
        });

        bytes4[] memory labQuerySelectors = new bytes4[](3);
        labQuerySelectors[0] = _selector("getLab(uint256)");
        labQuerySelectors[1] = _selector("isLabListed(uint256)");
        labQuerySelectors[2] = _selector("getLabsPaginated(uint256,uint256)");
        cut2[4] = IDiamond.FacetCut({
            facetAddress: address(labQueryImpl),
            action: IDiamond.FacetCutAction.Add,
            functionSelectors: labQuerySelectors
        });

        vm.prank(admin);
        IDiamondCut(address(diamond)).diamondCut(cut2, address(0), "");

        vm.prank(admin);
        InitFacet(address(diamond)).initializeDiamond("Admin", "admin@x", "ES", "Labs", "LS");

        providerFacet = ProviderFacet(address(diamond));
        labFacet = LabFacet(address(diamond));
        labAdmin = LabAdminFacet(address(diamond));
        labQuery = LabQueryFacet(address(diamond));

        vm.prank(admin);
        providerFacet.addProvider("Provider1", provider1, "p1@x", "ES", "");
        vm.prank(admin);
        providerFacet.addProvider("Provider2", provider2, "p2@x", "ES", "");
    }

    /// @notice SPEC: "ADD LAB" use case
    function test_addLab_creates_nft_with_metadata() public {
        vm.prank(provider1);
        labAdmin.addLab("ipfs://lab-metadata", PRICE_100, "https://access.example.com", "accessKey123", 0);

        // Verify NFT was minted
        assertEq(labFacet.ownerOf(1), provider1);
        assertEq(labFacet.tokenURI(1), "ipfs://lab-metadata");

        // TODO: Verify metadata stored correctly
        // Lab memory lab = labQuery.getLab(1);
        // assertEq(lab.uri, "ipfs://lab-metadata");
        // assertEq(lab.price, PRICE_100);
    }

    /// @notice SPEC: Precondition "Caller must be the lab provider"
    function test_addLab_requires_provider_role() public {
        vm.prank(nonProvider);
        vm.expectRevert();
        labAdmin.addLab("ipfs://metadata", PRICE_100, "https://access.example.com", "key", 0);
    }

    /// @notice SPEC: "UPDATE LAB" use case
    function test_updateLab_modifies_metadata() public {
        // Setup: Create lab
        vm.prank(provider1);
        labAdmin.addLab("uri1", PRICE_100, "access1", "key1", 0);

        // Update lab
        vm.prank(provider1);
        labAdmin.updateLab(1, "uri2", PRICE_200, "access2", "key2", 0);

        assertEq(labFacet.tokenURI(1), "uri2");
    }

    /// @notice SPEC: Only lab owner can update
    function test_updateLab_only_by_owner() public {
        // Setup: Provider1 creates lab
        vm.prank(provider1);
        labAdmin.addLab("uri1", PRICE_100, "access1", "key1", 0);

        // Provider2 cannot update Provider1's lab
        vm.prank(provider2);
        vm.expectRevert();
        labAdmin.updateLab(1, "uri2", PRICE_200, "access2", "key2", 0);
    }

    /// @notice SPEC: "DELETE LAB" use case
    function test_deleteLab_removes_nft() public {
        // Setup: Create lab
        vm.prank(provider1);
        labAdmin.addLab("uri1", PRICE_100, "access1", "key1", 0);

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
        labAdmin.addLab("uri1", PRICE_100, "access1", "key1", 0);

        // List lab
        vm.prank(provider1);
        labAdmin.listLab(1);

        assertTrue(labQuery.isLabListed(1));
    }

    /// @notice Test unlisting lab
    function test_unlistLab_makes_unavailable() public {
        // Setup: Create and list lab
        vm.prank(provider1);
        labAdmin.addLab("uri1", PRICE_100, "access1", "key1", 0);
        vm.prank(provider1);
        labAdmin.listLab(1);

        // Unlist lab
        vm.prank(provider1);
        labAdmin.unlistLab(1);

        assertFalse(labQuery.isLabListed(1));
    }

    function test_getLabsPaginated_excludes_deleted_ids() public {
        vm.startPrank(provider1);
        labAdmin.addLab("uri1", PRICE_100, "access1", "key1", 0);
        labAdmin.addLab("uri2", PRICE_100, "access2", "key2", 0);
        labAdmin.addLab("uri3", PRICE_100, "access3", "key3", 0);
        labAdmin.deleteLab(2);
        vm.stopPrank();

        (uint256[] memory ids, uint256 total) = labQuery.getLabsPaginated(0, 5);

        assertEq(total, 2);
        assertEq(ids.length, 2);
        assertEq(ids[0], 1);
        assertEq(ids[1], 3);
    }
}
