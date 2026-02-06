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

    function _onlyDiamondCanCallRevertData() internal pure returns (bytes memory) {
        return abi.encodeWithSelector(bytes4(keccak256("Error(string)")), "Only diamond can call");
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

    /// @notice Security: External callers cannot mint directly via LabFacet helper
    function test_safeMintTo_reverts_for_external_caller() public {
        vm.prank(attacker);
        vm.expectRevert(_onlyDiamondCanCallRevertData());
        LabFacet(address(diamond)).safeMintTo(attacker, 999);
    }

    /// @notice Security: External callers cannot burn directly via LabFacet helper
    function test_burnToken_reverts_for_external_caller() public {
        vm.prank(provider1);
        LabAdminFacet(address(diamond)).addLab(
            "ipfs://metadata",
            100 ether,
            "https://access.example.com",
            "key123"
        );

        uint256 labId = 1;
        vm.prank(attacker);
        vm.expectRevert(_onlyDiamondCanCallRevertData());
        LabFacet(address(diamond)).burnToken(labId);
    }

    /// @notice Security: helper mint must reject external callers with exact reason
    function test_safeMintTo_reverts_with_expected_reason() public {
        vm.prank(attacker);
        vm.expectRevert(_onlyDiamondCanCallRevertData());
        LabFacet(address(diamond)).safeMintTo(attacker, 999);
    }

    /// @notice Security: helper burn must reject external callers with exact reason
    function test_burnToken_reverts_with_expected_reason() public {
        vm.prank(provider1);
        LabAdminFacet(address(diamond)).addLab(
            "ipfs://metadata",
            100 ether,
            "https://access.example.com",
            "key123"
        );

        vm.prank(attacker);
        vm.expectRevert(_onlyDiamondCanCallRevertData());
        LabFacet(address(diamond)).burnToken(1);
    }
}
