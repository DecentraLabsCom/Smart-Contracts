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
import {Lab, LabBase} from "../contracts/libraries/LibAppStorage.sol";

/// @title LabQuery Test
/// @notice Dedicated tests for LabQueryFacet read-only functions
/// @dev Covers all 9 external functions, exists modifier, and pagination edge cases
contract LabQueryTest is BaseTest {
    Diamond diamond;
    LabAdminFacet labAdmin;
    LabFacet labFacet;
    LabQueryFacet labQuery;
    ProviderFacet providerFacet;
    LabERC20 token;

    address admin = address(0xA11CE);
    address provider1 = address(0xDEAD);
    address provider2 = address(0xBEEF);

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
        initSelectors[0] = _selector("initializeDiamond(string,string,string,address,string,string)");
        cut2[0] = IDiamond.FacetCut({
            facetAddress: address(initFacet), action: IDiamond.FacetCutAction.Add, functionSelectors: initSelectors
        });

        bytes4[] memory providerSelectors = new bytes4[](3);
        providerSelectors[0] = _selector("initialize(string,string,string,address)");
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
        labAdminSelectors[0] = _selector("addLab(string,uint96,string,string)");
        labAdminSelectors[1] = _selector("updateLab(uint256,string,uint96,string,string)");
        labAdminSelectors[2] = _selector("deleteLab(uint256)");
        labAdminSelectors[3] = _selector("listLab(uint256)");
        labAdminSelectors[4] = _selector("unlistLab(uint256)");
        cut2[3] = IDiamond.FacetCut({
            facetAddress: address(labAdminImpl),
            action: IDiamond.FacetCutAction.Add,
            functionSelectors: labAdminSelectors
        });

        bytes4[] memory labQuerySelectors = new bytes4[](9);
        labQuerySelectors[0] = _selector("getLab(uint256)");
        labQuerySelectors[1] = _selector("isLabListed(uint256)");
        labQuerySelectors[2] = _selector("getLabsPaginated(uint256,uint256)");
        labQuerySelectors[3] = _selector("getLabCount()");
        labQuerySelectors[4] = _selector("getLabPrice(uint256)");
        labQuerySelectors[5] = _selector("getLabAuthURI(uint256)");
        labQuerySelectors[6] = _selector("getLabAccessURI(uint256)");
        labQuerySelectors[7] = _selector("getLabAccessKey(uint256)");
        labQuerySelectors[8] = _selector("getLabAge(uint256)");
        cut2[4] = IDiamond.FacetCut({
            facetAddress: address(labQueryImpl),
            action: IDiamond.FacetCutAction.Add,
            functionSelectors: labQuerySelectors
        });

        vm.prank(admin);
        IDiamondCut(address(diamond)).diamondCut(cut2, address(0), "");

        token = new LabERC20();
        token.initialize("LS", address(diamond));

        vm.prank(admin);
        InitFacet(address(diamond)).initializeDiamond("Admin", "admin@x", "ES", address(token), "Labs", "LS");

        providerFacet = ProviderFacet(address(diamond));
        labFacet = LabFacet(address(diamond));
        labAdmin = LabAdminFacet(address(diamond));
        labQuery = LabQueryFacet(address(diamond));

        vm.prank(admin);
        providerFacet.addProvider("Provider1", provider1, "p1@x", "ES", "https://provider1.example.com/auth");
        vm.prank(admin);
        providerFacet.addProvider("Provider2", provider2, "p2@x", "ES", "https://provider2.example.com/auth");
    }

    // ──────────────────────────────────────────────
    //  getLab
    // ──────────────────────────────────────────────

    function test_getLab_returns_correct_metadata() public {
        vm.prank(provider1);
        labAdmin.addLab("ipfs://lab1", 50 ether, "https://access.lab1.com", "key-abc");

        Lab memory lab = labQuery.getLab(1);

        assertEq(lab.labId, 1);
        assertEq(lab.base.uri, "ipfs://lab1");
        assertEq(lab.base.price, 50 ether);
        assertEq(lab.base.accessURI, "https://access.lab1.com");
        assertEq(lab.base.accessKey, "key-abc");
        assertGt(lab.base.createdAt, 0);
    }

    function test_getLab_reverts_for_nonexistent_lab() public {
        vm.expectRevert("Lab does not exist");
        labQuery.getLab(999);
    }

    function test_getLab_reverts_for_deleted_lab() public {
        vm.startPrank(provider1);
        labAdmin.addLab("ipfs://lab1", 50 ether, "https://access.lab1.com", "key1");
        labAdmin.deleteLab(1);
        vm.stopPrank();

        vm.expectRevert("Lab does not exist");
        labQuery.getLab(1);
    }

    // ──────────────────────────────────────────────
    //  getLabCount
    // ──────────────────────────────────────────────

    function test_getLabCount_starts_at_zero() public view {
        assertEq(labQuery.getLabCount(), 0);
    }

    function test_getLabCount_tracks_minted_labs() public {
        vm.startPrank(provider1);
        labAdmin.addLab("uri1", 10 ether, "access1", "k1");
        labAdmin.addLab("uri2", 20 ether, "access2", "k2");
        labAdmin.addLab("uri3", 30 ether, "access3", "k3");
        vm.stopPrank();

        assertEq(labQuery.getLabCount(), 3);
    }

    function test_getLabCount_does_not_decrease_after_delete() public {
        vm.startPrank(provider1);
        labAdmin.addLab("uri1", 10 ether, "access1", "k1");
        labAdmin.addLab("uri2", 20 ether, "access2", "k2");
        labAdmin.deleteLab(1);
        vm.stopPrank();

        assertEq(labQuery.getLabCount(), 2, "Counter reflects total minted, not active");
    }

    // ──────────────────────────────────────────────
    //  isLabListed
    // ──────────────────────────────────────────────

    function test_isLabListed_false_by_default() public {
        vm.prank(provider1);
        labAdmin.addLab("uri1", 10 ether, "access1", "k1");

        assertFalse(labQuery.isLabListed(1));
    }

    function test_isLabListed_reflects_listing_status() public {
        vm.startPrank(provider1);
        labAdmin.addLab("uri1", 10 ether, "access1", "k1");

        labAdmin.listLab(1);
        assertTrue(labQuery.isLabListed(1));

        labAdmin.unlistLab(1);
        assertFalse(labQuery.isLabListed(1));
        vm.stopPrank();
    }

    // ──────────────────────────────────────────────
    //  getLabPrice
    // ──────────────────────────────────────────────

    function test_getLabPrice_returns_correct_price() public {
        vm.prank(provider1);
        labAdmin.addLab("uri1", 42 ether, "access1", "k1");

        assertEq(labQuery.getLabPrice(1), 42 ether);
    }

    function test_getLabPrice_reverts_for_nonexistent() public {
        vm.expectRevert("Lab does not exist");
        labQuery.getLabPrice(999);
    }

    // ──────────────────────────────────────────────
    //  getLabAuthURI
    // ──────────────────────────────────────────────

    function test_getLabAuthURI_resolves_from_provider() public {
        vm.prank(provider1);
        labAdmin.addLab("uri1", 10 ether, "access1", "k1");

        assertEq(labQuery.getLabAuthURI(1), "https://provider1.example.com/auth");
    }

    function test_getLabAuthURI_different_providers() public {
        vm.prank(provider1);
        labAdmin.addLab("uri1", 10 ether, "access1", "k1");
        vm.prank(provider2);
        labAdmin.addLab("uri2", 10 ether, "access2", "k2");

        assertEq(labQuery.getLabAuthURI(1), "https://provider1.example.com/auth");
        assertEq(labQuery.getLabAuthURI(2), "https://provider2.example.com/auth");
    }

    function test_getLabAuthURI_reverts_for_nonexistent() public {
        vm.expectRevert("Lab does not exist");
        labQuery.getLabAuthURI(999);
    }

    // ──────────────────────────────────────────────
    //  getLabAccessURI / getLabAccessKey
    // ──────────────────────────────────────────────

    function test_getLabAccessURI_returns_correct_uri() public {
        vm.prank(provider1);
        labAdmin.addLab("uri1", 10 ether, "https://access.lab.io", "k1");

        assertEq(labQuery.getLabAccessURI(1), "https://access.lab.io");
    }

    function test_getLabAccessKey_returns_correct_key() public {
        vm.prank(provider1);
        labAdmin.addLab("uri1", 10 ether, "access1", "secret-key-xyz");

        assertEq(labQuery.getLabAccessKey(1), "secret-key-xyz");
    }

    // ──────────────────────────────────────────────
    //  getLabAge
    // ──────────────────────────────────────────────

    function test_getLabAge_increases_with_time() public {
        vm.prank(provider1);
        labAdmin.addLab("uri1", 10 ether, "access1", "k1");

        uint256 ageAtCreation = labQuery.getLabAge(1);
        assertEq(ageAtCreation, 0);

        vm.warp(block.timestamp + 3600);
        assertEq(labQuery.getLabAge(1), 3600);

        vm.warp(block.timestamp + 86_400);
        assertEq(labQuery.getLabAge(1), 3600 + 86_400);
    }

    function test_getLabAge_reverts_for_nonexistent() public {
        vm.expectRevert("Lab does not exist");
        labQuery.getLabAge(999);
    }

    // ──────────────────────────────────────────────
    //  getLabsPaginated
    // ──────────────────────────────────────────────

    function test_getLabsPaginated_full_page() public {
        vm.startPrank(provider1);
        for (uint256 i = 0; i < 5; i++) {
            labAdmin.addLab("uri", 10 ether, "access", "key");
        }
        vm.stopPrank();

        (uint256[] memory ids, uint256 total) = labQuery.getLabsPaginated(0, 5);

        assertEq(total, 5);
        assertEq(ids.length, 5);
        for (uint256 i = 0; i < 5; i++) {
            assertEq(ids[i], i + 1);
        }
    }

    function test_getLabsPaginated_partial_last_page() public {
        vm.startPrank(provider1);
        for (uint256 i = 0; i < 7; i++) {
            labAdmin.addLab("uri", 10 ether, "access", "key");
        }
        vm.stopPrank();

        (uint256[] memory ids, uint256 total) = labQuery.getLabsPaginated(5, 5);

        assertEq(total, 7);
        assertEq(ids.length, 2);
        assertEq(ids[0], 6);
        assertEq(ids[1], 7);
    }

    function test_getLabsPaginated_offset_beyond_total_returns_empty() public {
        vm.prank(provider1);
        labAdmin.addLab("uri", 10 ether, "access", "key");

        (uint256[] memory ids, uint256 total) = labQuery.getLabsPaginated(100, 10);

        assertEq(total, 1);
        assertEq(ids.length, 0);
    }

    function test_getLabsPaginated_reverts_limit_zero() public {
        vm.expectRevert("Limit must be between 1 and 100");
        labQuery.getLabsPaginated(0, 0);
    }

    function test_getLabsPaginated_reverts_limit_over_100() public {
        vm.expectRevert("Limit must be between 1 and 100");
        labQuery.getLabsPaginated(0, 101);
    }

    function test_getLabsPaginated_max_limit_100_succeeds() public {
        vm.prank(provider1);
        labAdmin.addLab("uri", 10 ether, "access", "key");

        (uint256[] memory ids, uint256 total) = labQuery.getLabsPaginated(0, 100);

        assertEq(total, 1);
        assertEq(ids.length, 1);
    }
}
