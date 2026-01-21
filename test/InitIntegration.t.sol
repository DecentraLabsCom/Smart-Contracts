// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.33;

import "forge-std/Test.sol";
import "./BaseTest.sol";
import "../contracts/Diamond.sol";
import "../contracts/facets/diamond/DiamondCutFacet.sol";
import "../contracts/facets/diamond/DiamondLoupeFacet.sol";
import "../contracts/facets/InitFacet.sol";
import "../contracts/facets/ProviderFacet.sol";
import "../contracts/facets/lab/LabFacet.sol";
import "../contracts/external/LabERC20.sol";
import "../contracts/libraries/LibAppStorage.sol";
import {IDiamondCut} from "../contracts/interfaces/IDiamondCut.sol";
import "../contracts/interfaces/IDiamond.sol";
import "./TestReaderFacet.sol";

contract InitIntegrationTest is BaseTest {
    using EnumerableSet for EnumerableSet.AddressSet;

    function _selector(string memory sig) internal pure returns (bytes4) {
        return bytes4(keccak256(bytes(sig)));
    }

    function test_initializeDiamond_happy_path() public {
        address admin = address(0xA11CE);

        // Deploy core diamond facets
        DiamondCutFacet dc = new DiamondCutFacet();
        DiamondLoupeFacet loupe = new DiamondLoupeFacet();

        // Prepare initial cut: add diamondCut function from DiamondCutFacet and loupe selectors
        IDiamond.FacetCut[] memory cut = new IDiamond.FacetCut[](2);
        bytes4[] memory selsDC = new bytes4[](1);
        selsDC[0] = IDiamondCut.diamondCut.selector;
        cut[0] = IDiamond.FacetCut({facetAddress: address(dc), action: IDiamond.FacetCutAction.Add, functionSelectors: selsDC});

        // add loupe selectors (only a couple used for sanity)
        bytes4[] memory selsLoupe = new bytes4[](4);
        selsLoupe[0] = bytes4(keccak256("facets()"));
        selsLoupe[1] = bytes4(keccak256("facetFunctionSelectors(address)"));
        selsLoupe[2] = bytes4(keccak256("facetAddresses()"));
        selsLoupe[3] = bytes4(keccak256("facetAddress(bytes4)"));
        cut[1] = IDiamond.FacetCut({facetAddress: address(loupe), action: IDiamond.FacetCutAction.Add, functionSelectors: selsLoupe});

        // Deploy Diamond with initial cut (sets owner to admin)
        DiamondArgs memory args = DiamondArgs({owner: admin, init: address(0), initCalldata: ""});
        Diamond d = new Diamond(cut, args);

        // Now add InitFacet, ProviderFacet and LabFacet with their initialize selectors
        IDiamond.FacetCut[] memory cut2 = new IDiamond.FacetCut[](3);

        InitFacet initFacet = new InitFacet();
        bytes4[] memory initSels = new bytes4[](1);
        initSels[0] = _selector("initializeDiamond(string,string,string,address,string,string)");
        cut2[0] = IDiamond.FacetCut({facetAddress: address(initFacet), action: IDiamond.FacetCutAction.Add, functionSelectors: initSels});

        ProviderFacet prov = new ProviderFacet();
        bytes4[] memory provSels = new bytes4[](1);
        provSels[0] = _selector("initialize(string,string,string,address)");
        cut2[1] = IDiamond.FacetCut({facetAddress: address(prov), action: IDiamond.FacetCutAction.Add, functionSelectors: provSels});

        LabFacet labFacet = new LabFacet();
        bytes4[] memory labSels = new bytes4[](1);
        labSels[0] = _selector("initialize(string,string)");
        cut2[2] = IDiamond.FacetCut({facetAddress: address(labFacet), action: IDiamond.FacetCutAction.Add, functionSelectors: labSels});

        // Perform diamond cut as owner
        vm.prank(admin);
        IDiamondCut(address(d)).diamondCut(cut2, address(0), "");

        // Deploy token and initialize it granting MINTER to diamond
        LabERC20 token = new LabERC20();
        token.initialize("LS", address(d));

        // Call initializeDiamond via InitFacet on diamond as admin
        vm.prank(admin);
        InitFacet(address(d)).initializeDiamond("Admin","admin@x","ES", address(token), "LN", "LS");

        // Add a test-only reader facet to fetch diamond storage and verify initialization
        TestReaderFacet reader = new TestReaderFacet();
        IDiamond.FacetCut[] memory addReader = new IDiamond.FacetCut[](1);
        bytes4[] memory readerSels = new bytes4[](2);
        readerSels[0] = _selector("readLabTokenAddress()");
        readerSels[1] = _selector("isDefaultAdmin(address)");
        addReader[0] = IDiamond.FacetCut({facetAddress: address(reader), action: IDiamond.FacetCutAction.Add, functionSelectors: readerSels});

        vm.prank(admin);
        IDiamondCut(address(d)).diamondCut(addReader, address(0), "");

        // Verify via reader
        address readToken = TestReaderFacet(address(d)).readLabTokenAddress();
        assertEq(readToken, address(token));
        assertTrue(TestReaderFacet(address(d)).isDefaultAdmin(admin));
    }
}
