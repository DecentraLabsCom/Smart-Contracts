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
import "../contracts/facets/lab/LabReputationFacet.sol";
import "../contracts/external/LabERC20.sol";
import {IDiamondCut} from "../contracts/interfaces/IDiamondCut.sol";
import "../contracts/interfaces/IDiamond.sol";

/// @title LabReputation Test
/// @notice Dedicated tests for LabReputationFacet
/// @dev Same minimal diamond layout as LabQuery.t.sol (Init, Provider, Lab, LabAdmin + this facet)
contract LabReputationTest is BaseTest {
    Diamond diamond;
    LabAdminFacet labAdmin;
    LabFacet labFacet;
    LabReputationFacet labReputation;
    ProviderFacet providerFacet;
    LabERC20 token;

    address admin = address(0xA11CE);
    address provider1 = address(0xDEAD);
    address provider2 = address(0xBEEF);
    address outsider = address(0xCAFE);

    event LabReputationAdjusted(uint256 indexed labId, int32 delta, int32 newScore, uint32 totalEvents, string reason);

    event LabReputationSet(uint256 indexed labId, int32 newScore, string reason);

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
        LabReputationFacet labReputationImpl = new LabReputationFacet();

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

        bytes4[] memory repSelectors = new bytes4[](6);
        repSelectors[0] = _selector("getLabReputation(uint256)");
        repSelectors[1] = _selector("getLabScore(uint256)");
        repSelectors[2] = _selector("getLabRating(uint256)");
        repSelectors[3] = _selector("adjustLabReputation(uint256,int32,string)");
        repSelectors[4] = _selector("setLabReputation(uint256,int32,string)");
        repSelectors[5] = _selector("tokenURIWithReputation(uint256)");
        cut2[4] = IDiamond.FacetCut({
            facetAddress: address(labReputationImpl),
            action: IDiamond.FacetCutAction.Add,
            functionSelectors: repSelectors
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
        labReputation = LabReputationFacet(address(diamond));

        vm.prank(admin);
        providerFacet.addProvider("Provider1", provider1, "p1@x", "ES", "https://provider1.example.com/auth");
        vm.prank(admin);
        providerFacet.addProvider("Provider2", provider2, "p2@x", "ES", "https://provider2.example.com/auth");
    }

    function _mintLab1() internal {
        vm.prank(provider1);
        labAdmin.addLab("ipfs://lab1", 50 ether, "https://access.lab1.com", "key-abc");
    }

    // ──────────────────────────────────────────────
    //  getLabReputation / getLabScore / getLabRating
    // ──────────────────────────────────────────────

    function test_getLabReputation_defaults_for_new_lab() public {
        _mintLab1();
        (int32 score, uint32 totalEvents, uint32 ownerCan, uint32 instCan, uint64 lastUpdated) =
            labReputation.getLabReputation(1);
        assertEq(score, 0);
        assertEq(totalEvents, 0);
        assertEq(ownerCan, 0);
        assertEq(instCan, 0);
        assertEq(lastUpdated, 0);
    }

    function test_getLabScore_defaults_to_zero() public {
        _mintLab1();
        assertEq(labReputation.getLabScore(1), int32(0));
    }

    function test_getLabRating_zero_events_returns_neutral() public {
        _mintLab1();
        assertEq(labReputation.getLabRating(1), int32(0));
    }

    function test_getLabRating_after_adjust_uses_ratio_and_caps_high() public {
        _mintLab1();
        vm.prank(admin);
        labReputation.adjustLabReputation(1, 20, "boost");
        assertEq(labReputation.getLabRating(1), int32(1000));
        assertEq(labReputation.getLabScore(1), int32(20));
    }

    function test_getLabRating_negative_ratio_caps_low() public {
        _mintLab1();
        vm.prank(admin);
        labReputation.adjustLabReputation(1, -20, "penalty");
        assertEq(labReputation.getLabScore(1), int32(-20));
        assertEq(labReputation.getLabRating(1), int32(-1000));
    }

    // ──────────────────────────────────────────────
    //  adjustLabReputation
    // ──────────────────────────────────────────────

    function test_adjustLabReputation_as_default_admin() public {
        _mintLab1();
        vm.prank(admin);
        vm.expectEmit(true, true, true, true);
        emit LabReputationAdjusted(1, int32(3), int32(3), uint32(1), "unit");
        labReputation.adjustLabReputation(1, 3, "unit");

        (int32 score, uint32 totalEvents,,,) = labReputation.getLabReputation(1);
        assertEq(score, 3);
        assertEq(totalEvents, 1);
    }

    function test_adjustLabReputation_reverts_for_non_admin() public {
        _mintLab1();
        vm.prank(outsider);
        vm.expectRevert(bytes("Only default admin"));
        labReputation.adjustLabReputation(1, 1, "x");
    }

    function test_adjustLabReputation_reverts_for_provider_not_admin() public {
        _mintLab1();
        vm.prank(provider1);
        vm.expectRevert(bytes("Only default admin"));
        labReputation.adjustLabReputation(1, 1, "x");
    }

    function test_adjustLabReputation_accumulates_and_increments_events() public {
        _mintLab1();
        vm.startPrank(admin);
        labReputation.adjustLabReputation(1, 5, "a");
        labReputation.adjustLabReputation(1, -2, "b");
        vm.stopPrank();
        (int32 score, uint32 totalEvents,,,) = labReputation.getLabReputation(1);
        assertEq(score, 3);
        assertEq(totalEvents, 2);
    }

    // ──────────────────────────────────────────────
    //  setLabReputation
    // ──────────────────────────────────────────────

    function test_setLabReputation_as_default_admin() public {
        _mintLab1();
        vm.prank(admin);
        vm.expectEmit(true, true, true, true);
        emit LabReputationSet(1, int32(42), "reset");
        labReputation.setLabReputation(1, 42, "reset");

        assertEq(labReputation.getLabScore(1), int32(42));
        (,, uint32 totalEvents,,) = labReputation.getLabReputation(1);
        assertEq(totalEvents, 0);
    }

    function test_setLabReputation_reverts_for_non_admin() public {
        _mintLab1();
        vm.prank(outsider);
        vm.expectRevert(bytes("Only default admin"));
        labReputation.setLabReputation(1, 0, "x");
    }

    function test_setLabReputation_clamps_to_max() public {
        _mintLab1();
        vm.prank(admin);
        labReputation.setLabReputation(1, type(int32).max, "max");
        assertEq(labReputation.getLabScore(1), int32(10_000));
    }

    function test_setLabReputation_clamps_to_min() public {
        _mintLab1();
        vm.prank(admin);
        labReputation.setLabReputation(1, type(int32).min, "min");
        assertEq(labReputation.getLabScore(1), int32(-10_000));
    }

    // ──────────────────────────────────────────────
    //  tokenURIWithReputation
    // ──────────────────────────────────────────────

    function test_tokenURIWithReputation_includes_traits_and_uri() public {
        _mintLab1();
        vm.prank(admin);
        labReputation.adjustLabReputation(1, 10, "t");

        string memory uri = labReputation.tokenURIWithReputation(1);
        assertTrue(_contains(uri, "data:application/json;utf8,"));
        assertTrue(_contains(uri, "reputation_rating"));
        assertTrue(_contains(uri, "total_score"));
        assertTrue(_contains(uri, "reputation_events"));
        assertTrue(_contains(uri, "owner_cancellations"));
        assertTrue(_contains(uri, "institution_cancellations"));
        assertTrue(_contains(uri, "ipfs://lab1"));
    }

    function test_tokenURIWithReputation_negative_score_string() public {
        _mintLab1();
        vm.prank(admin);
        labReputation.setLabReputation(1, -7, "neg");
        string memory uri = labReputation.tokenURIWithReputation(1);
        assertTrue(_contains(uri, "-7"));
    }

    function test_tokenURIWithReputation_reverts_nonexistent_token() public {
        vm.expectRevert();
        labReputation.tokenURIWithReputation(999);
    }

    function _contains(
        string memory haystack,
        string memory needle
    ) internal pure returns (bool) {
        bytes memory h = bytes(haystack);
        bytes memory n = bytes(needle);
        if (n.length == 0 || n.length > h.length) return false;
        for (uint256 i = 0; i <= h.length - n.length; i++) {
            bool allMatch = true;
            for (uint256 j = 0; j < n.length; j++) {
                if (h[i + j] != n[j]) {
                    allMatch = false;
                    break;
                }
            }
            if (allMatch) return true;
        }
        return false;
    }
}
