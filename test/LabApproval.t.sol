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
import {IDiamondCut} from "../contracts/interfaces/IDiamondCut.sol";
import "../contracts/interfaces/IDiamond.sol";

contract LabApprovalTest is BaseTest {
    Diamond diamond;
    ProviderFacet providerFacet;
    LabFacet labFacet;
    LabAdminFacet labAdminFacet;

    address admin = address(0xA11CE);
    address provider1 = address(0xDEAD);
    address provider2 = address(0xBEEF);
    uint256 constant LAB_ID = 1;

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
        LabAdminFacet labAdminFacetImpl = new LabAdminFacet();

        IDiamond.FacetCut[] memory cut2 = new IDiamond.FacetCut[](4);

        bytes4[] memory initSelectors = new bytes4[](1);
        initSelectors[0] = _selector("initializeDiamond(string,string,string,string,string)");
        cut2[0] = IDiamond.FacetCut({
            facetAddress: address(initFacet), action: IDiamond.FacetCutAction.Add, functionSelectors: initSelectors
        });

        bytes4[] memory providerSelectors = new bytes4[](2);
        providerSelectors[0] = _selector("initialize(string,string,string)");
        providerSelectors[1] = _selector("addProvider(string,address,string,string,string)");
        cut2[1] = IDiamond.FacetCut({
            facetAddress: address(providerFacetImpl),
            action: IDiamond.FacetCutAction.Add,
            functionSelectors: providerSelectors
        });

        bytes4[] memory labSelectors = new bytes4[](6);
        labSelectors[0] = _selector("initialize(string,string)");
        labSelectors[1] = _selector("approve(address,uint256)");
        labSelectors[2] = _selector("setApprovalForAll(address,bool)");
        labSelectors[3] = _selector("getApproved(uint256)");
        labSelectors[4] = _selector("safeMintTo(address,uint256)");
        labSelectors[5] = _selector("balanceOf(address)");
        cut2[2] = IDiamond.FacetCut({
            facetAddress: address(labFacetImpl), action: IDiamond.FacetCutAction.Add, functionSelectors: labSelectors
        });

        bytes4[] memory labAdminSelectors = new bytes4[](1);
        labAdminSelectors[0] = _selector("addLab(string,uint96,string,string,uint8)");
        cut2[3] = IDiamond.FacetCut({
            facetAddress: address(labAdminFacetImpl),
            action: IDiamond.FacetCutAction.Add,
            functionSelectors: labAdminSelectors
        });

        vm.prank(admin);
        IDiamondCut(address(diamond)).diamondCut(cut2, address(0), "");

        vm.prank(admin);
        InitFacet(address(diamond)).initializeDiamond("Admin", "admin@x", "ES", "Labs", "LS");

        providerFacet = ProviderFacet(address(diamond));
        labFacet = LabFacet(address(diamond));
        labAdminFacet = LabAdminFacet(address(diamond));

        vm.prank(admin);
        providerFacet.addProvider("Provider1", provider1, "p1@x", "ES", "");
        vm.prank(admin);
        providerFacet.addProvider("Provider2", provider2, "p2@x", "ES", "");

        vm.prank(provider1);
        labAdminFacet.addLab("ipfs://lab-1", 100, "https://lab.example/access", "key-1", 0);
    }

    function test_approve_allows_clearing_existing_approval() public {
        vm.prank(provider1);
        labFacet.approve(provider2, LAB_ID);

        assertEq(labFacet.getApproved(LAB_ID), provider2);

        vm.prank(provider1);
        labFacet.approve(address(0), LAB_ID);

        assertEq(labFacet.getApproved(LAB_ID), address(0));
    }

    function test_setApprovalForAll_allows_revoking_non_provider_operator() public {
        address externalOperator = address(0xCAFE);

        vm.prank(provider1);
        labFacet.setApprovalForAll(provider2, true);

        vm.prank(provider1);
        labFacet.setApprovalForAll(externalOperator, false);
    }
}
