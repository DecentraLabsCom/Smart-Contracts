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
import "../contracts/external/LabERC20.sol";
import {IDiamondCut} from "../contracts/interfaces/IDiamondCut.sol";
import "../contracts/interfaces/IDiamond.sol";

/// @title LabSecurity Test
/// @notice Tests security vulnerabilities in Lab facets
/// @dev Tests critical access control issues found during security analysis
contract LabSecurityTest is BaseTest {
    Diamond diamond;
    LabFacet labFacet;
    LabAdminFacet labAdminFacet;
    ProviderFacet providerFacet;
    LabERC20 token;

    address admin = address(0xA11CE);
    address provider1 = address(0xDEAD);
    address attacker = address(0xBAD);

    function _selector(string memory sig) internal pure returns (bytes4) {
        return bytes4(keccak256(bytes(sig)));
    }

    function setUp() public override {
        super.setUp();

        // Deploy diamond with Lab and Provider facets
        DiamondCutFacet dc = new DiamondCutFacet();

        IDiamond.FacetCut[] memory cut = new IDiamond.FacetCut[](1);
        bytes4[] memory selsDC = new bytes4[](1);
        selsDC[0] = IDiamondCut.diamondCut.selector;
        cut[0] = IDiamond.FacetCut({
            facetAddress: address(dc),
            action: IDiamond.FacetCutAction.Add,
            functionSelectors: selsDC
        });

        DiamondArgs memory args = DiamondArgs({
            owner: admin,
            init: address(0),
            initCalldata: ""
        });
        diamond = new Diamond(cut, args);

        // Deploy facets
        InitFacet initFacet = new InitFacet();
        providerFacet = new ProviderFacet();
        labFacet = new LabFacet();
        labAdminFacet = new LabAdminFacet();

        // Add facets to diamond
        IDiamond.FacetCut[] memory cut2 = new IDiamond.FacetCut[](4);

        bytes4[] memory initSels = new bytes4[](1);
        initSels[0] = _selector(
            "initializeDiamond(string,string,string,address,string,string)"
        );
        cut2[0] = IDiamond.FacetCut({
            facetAddress: address(initFacet),
            action: IDiamond.FacetCutAction.Add,
            functionSelectors: initSels
        });

        bytes4[] memory provSels = new bytes4[](2);
        provSels[0] = _selector("initialize(string,string,string,address)");
        provSels[1] = _selector(
            "addProvider(string,address,string,string,string)"
        );
        cut2[1] = IDiamond.FacetCut({
            facetAddress: address(providerFacet),
            action: IDiamond.FacetCutAction.Add,
            functionSelectors: provSels
        });

        bytes4[] memory labSels = new bytes4[](3);
        labSels[0] = _selector("initialize(string,string)");
        labSels[1] = _selector("safeMintTo(address,uint256)");
        labSels[2] = _selector("burnToken(uint256)");
        cut2[2] = IDiamond.FacetCut({
            facetAddress: address(labFacet),
            action: IDiamond.FacetCutAction.Add,
            functionSelectors: labSels
        });

        bytes4[] memory adminSels = new bytes4[](1);
        adminSels[0] = _selector("addLab(string,uint96,string,string)");
        cut2[3] = IDiamond.FacetCut({
            facetAddress: address(labAdminFacet),
            action: IDiamond.FacetCutAction.Add,
            functionSelectors: adminSels
        });

        vm.prank(admin);
        IDiamondCut(address(diamond)).diamondCut(cut2, address(0), "");

        // Deploy and initialize token
        token = new LabERC20();
        token.initialize("LS", address(diamond));

        // Initialize diamond
        vm.prank(admin);
        InitFacet(address(diamond)).initializeDiamond(
            "Admin",
            "admin@x",
            "ES",
            address(token),
            "LN",
            "LS"
        );

        // Add a provider for legitimate operations
        vm.prank(admin);
        ProviderFacet(address(diamond)).addProvider(
            "Provider1",
            provider1,
            "p@x",
            "ES",
            ""
        );
    }

    /// @notice CRITICAL: Test that anyone can call safeMintTo
    function test_CRITICAL_safeMintTo_no_access_control() public {
        // ATTACK: Attacker calls safeMintTo directly
        vm.prank(attacker);
        LabFacet(address(diamond)).safeMintTo(attacker, 999);

        // VERIFY: Attacker now owns the NFT
        assertEq(LabFacet(address(diamond)).ownerOf(999), attacker);

        // This test PASSES = vulnerability confirmed
    }

    /// @notice CRITICAL: Test that anyone can burn any lab
    function test_CRITICAL_burnToken_no_access_control() public {
        // Setup: Provider creates legitimate lab
        vm.prank(provider1);
        LabAdminFacet(address(diamond)).addLab(
            "ipfs://metadata",
            100 ether,
            "https://access.example.com",
            "key123"
        );

        uint256 labId = 1;
        address legitOwner = LabFacet(address(diamond)).ownerOf(labId);
        assertEq(legitOwner, provider1);

        // ATTACK: Attacker burns someone else's lab
        vm.prank(attacker);
        LabFacet(address(diamond)).burnToken(labId);

        // VERIFY: Lab is destroyed
        vm.expectRevert();
        LabFacet(address(diamond)).ownerOf(labId);

        // This test PASSES = vulnerability confirmed
    }

    /// @notice Test that safeMintTo should only be callable by diamond
    function test_safeMintTo_should_require_internal_calls() public {
        // This is how it SHOULD work after fix
        vm.prank(attacker);
        vm.expectRevert(); // Should revert with "Only diamond" or similar
        LabFacet(address(diamond)).safeMintTo(attacker, 999);

        // This test will FAIL now (proving vulnerability)
        // After fix is applied, this test will PASS
    }

    /// @notice Test that burnToken should only be callable by diamond
    function test_burnToken_should_require_internal_calls() public {
        // Setup: Create lab first
        vm.prank(provider1);
        LabAdminFacet(address(diamond)).addLab(
            "ipfs://metadata",
            100 ether,
            "https://access.example.com",
            "key123"
        );

        // This is how it SHOULD work after fix
        vm.prank(attacker);
        vm.expectRevert(); // Should revert with "Only diamond" or similar
        LabFacet(address(diamond)).burnToken(1);

        // This test will FAIL now (proving vulnerability)
        // After fix is applied, this test will PASS
    }
}
