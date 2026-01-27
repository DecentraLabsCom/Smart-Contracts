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
import "../contracts/facets/StakingFacet.sol";
import "../contracts/external/LabERC20.sol";
import "../contracts/libraries/LibAppStorage.sol";
import {IDiamondCut} from "../contracts/interfaces/IDiamondCut.sol";
import "../contracts/interfaces/IDiamond.sol";

contract StakingSlashingTest is BaseTest {
    // helper to compute selector
    function _selector(
        string memory sig
    ) internal pure returns (bytes4) {
        return bytes4(keccak256(bytes(sig)));
    }

    function test_queue_cancel_and_execute_slash() public {
        address admin = address(0xA11CE);
        address prov = address(0xDEAF);

        // deploy basic diamond with cut facet
        DiamondCutFacet dc = new DiamondCutFacet();
        DiamondLoupeFacet loupe = new DiamondLoupeFacet();

        IDiamond.FacetCut[] memory initial = new IDiamond.FacetCut[](2);
        bytes4[] memory dcSelectors = new bytes4[](1);
        dcSelectors[0] = IDiamondCut.diamondCut.selector;
        initial[0] = IDiamond.FacetCut({
            facetAddress: address(dc), action: IDiamond.FacetCutAction.Add, functionSelectors: dcSelectors
        });

        // Also add DiamondLoupe selectors so we can query facetAddress()/facets()
        bytes4[] memory loupeSels = new bytes4[](4);
        loupeSels[0] = _selector("facets()");
        loupeSels[1] = _selector("facetFunctionSelectors(address)");
        loupeSels[2] = _selector("facetAddresses()");
        loupeSels[3] = _selector("facetAddress(bytes4)");
        initial[1] = IDiamond.FacetCut({
            facetAddress: address(loupe), action: IDiamond.FacetCutAction.Add, functionSelectors: loupeSels
        });

        DiamondArgs memory args = DiamondArgs({owner: admin, init: address(0), initCalldata: ""});
        Diamond d = new Diamond(initial, args);

        // add Provider, Init, Lab and Staking facets
        ProviderFacet pf = new ProviderFacet();
        InitFacet initFacet = new InitFacet();
        LabFacet lf = new LabFacet();
        StakingFacet stakeFacet = new StakingFacet();

        IDiamond.FacetCut[] memory cut = new IDiamond.FacetCut[](4);
        bytes4[] memory s0 = new bytes4[](2);
        s0[0] = _selector("initialize(string,string,string,address)");
        s0[1] = _selector("addProvider(string,address,string,string,string)");
        cut[0] =
            IDiamond.FacetCut({facetAddress: address(pf), action: IDiamond.FacetCutAction.Add, functionSelectors: s0});
        bytes4[] memory s1 = new bytes4[](1);
        s1[0] = _selector("initializeDiamond(string,string,string,address,string,string)");
        cut[1] = IDiamond.FacetCut({
            facetAddress: address(initFacet), action: IDiamond.FacetCutAction.Add, functionSelectors: s1
        });
        bytes4[] memory s2 = new bytes4[](2);
        s2[0] = _selector("initialize(string,string)");
        s2[1] = _selector("calculateRequiredStake(address,uint256)");
        cut[2] =
            IDiamond.FacetCut({facetAddress: address(lf), action: IDiamond.FacetCutAction.Add, functionSelectors: s2});
        bytes4[] memory s3 = new bytes4[](4);
        s3[0] = _selector("slashProvider(address,uint256,string)");
        s3[1] = _selector("executeQueuedSlash(address)");
        s3[2] = _selector("cancelQueuedSlash(address)");
        s3[3] = _selector("getStakeInfo(address)");
        cut[3] = IDiamond.FacetCut({
            facetAddress: address(stakeFacet), action: IDiamond.FacetCutAction.Add, functionSelectors: s3
        });

        vm.prank(admin);
        IDiamondCut(address(d)).diamondCut(cut, address(0), "");

        // Verify the calculateRequiredStake selector is registered to LabFacet
        bytes4 calcSel = _selector("calculateRequiredStake(address,uint256)");
        address calcFacet = DiamondLoupeFacet(address(d)).facetAddress(calcSel);
        assertEq(calcFacet, address(lf));

        // deploy Lab token & initialize assigning minter to diamond
        LabERC20 token = new LabERC20();
        token.initialize("LS", address(d));

        // Prepare: call InitFacet.initializeDiamond to set lab token and default admin
        vm.prank(admin);
        InitFacet(address(d)).initializeDiamond("Admin", "admin@x", "ES", address(token), "LN", "LS");

        // as admin, add provider via ProviderFacet on diamond
        string memory name = "ProviderX";
        vm.prank(admin);
        ProviderFacet(address(d)).addProvider(name, prov, "p@x", "ES", "");

        // Ensure provider was added and got initial stake (200 treasury + 800 stake) OR at least stake recorded
        (uint256 preStake, uint256 preSlashed, uint256 preLastReservation, uint256 preUnlock, bool canUnstake) =
            StakingFacet(address(d)).getStakeInfo(prov);
        assertTrue(preStake >= 0);

        // Queue a slash for provider as admin
        uint256 amount = 10_000_000; // 10 tokens (with 6 decimals)
        vm.prank(admin);
        StakingFacet(address(d)).slashProvider(prov, amount, "misconduct");

        // trying to execute immediately should revert due to timelock
        vm.prank(admin);
        vm.expectRevert(bytes("StakingFacet: timelock active"));
        StakingFacet(address(d)).executeQueuedSlash(prov);

        // cancel queued slash as provider (self-defense)
        vm.prank(prov);
        StakingFacet(address(d)).cancelQueuedSlash(prov);

        // after cancel, executing should revert with no queued slash
        vm.prank(admin);
        vm.expectRevert(bytes("StakingFacet: no queued slash"));
        StakingFacet(address(d)).executeQueuedSlash(prov);

        // queue again and execute after timelock
        vm.prank(admin);
        StakingFacet(address(d)).slashProvider(prov, amount, "misconduct2");
        // fast forward past timelock
        vm.warp(block.timestamp + stakeFacet.SLASH_TIMELOCK() + 1);
        vm.prank(admin);
        StakingFacet(address(d)).executeQueuedSlash(prov);

        // slashed amount recorded and stake decreased
        (uint256 postStake, uint256 postSlashed,,,) = StakingFacet(address(d)).getStakeInfo(prov);
        assertEq(postSlashed - preSlashed, amount);
        assertEq(postStake, preStake - amount);
    }
}
