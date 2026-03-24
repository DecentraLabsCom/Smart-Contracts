// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.33;

import "forge-std/Test.sol";
import "./BaseTest.sol";
import "../contracts/Diamond.sol";
import "../contracts/facets/diamond/DiamondCutFacet.sol";
import "../contracts/facets/lab/LabFacet.sol";
import "../contracts/facets/StakingFacet.sol";
import {IDiamondCut} from "../contracts/interfaces/IDiamondCut.sol";
import "../contracts/interfaces/IDiamond.sol";

contract StakingSlashingTest is BaseTest {
    // helper to compute selector
    function _selector(
        string memory sig
    ) internal pure returns (bytes4) {
        return bytes4(keccak256(bytes(sig)));
    }

    function test_read_functions_still_work() public {
        address admin = address(0xA11CE);
        address prov = address(0xDEAF);

        DiamondCutFacet dc = new DiamondCutFacet();
        IDiamond.FacetCut[] memory initial = new IDiamond.FacetCut[](1);
        bytes4[] memory dcSelectors = new bytes4[](1);
        dcSelectors[0] = IDiamondCut.diamondCut.selector;
        initial[0] = IDiamond.FacetCut({
            facetAddress: address(dc), action: IDiamond.FacetCutAction.Add, functionSelectors: dcSelectors
        });
        DiamondArgs memory args = DiamondArgs({owner: admin, init: address(0), initCalldata: ""});
        Diamond d = new Diamond(initial, args);

        // add Staking facet with read functions
        StakingFacet stakeFacet = new StakingFacet();
        LabFacet lf = new LabFacet();
        IDiamond.FacetCut[] memory cut = new IDiamond.FacetCut[](2);
        bytes4[] memory s0 = new bytes4[](3);
        s0[0] = _selector("getStakeInfo(address)");
        s0[1] = _selector("canProvideService(address)");
        s0[2] = _selector("getRequiredStake(address)");
        cut[0] = IDiamond.FacetCut({
            facetAddress: address(stakeFacet), action: IDiamond.FacetCutAction.Add, functionSelectors: s0
        });
        bytes4[] memory s1 = new bytes4[](1);
        s1[0] = _selector("calculateRequiredStake(address,uint256)");
        cut[1] = IDiamond.FacetCut({
            facetAddress: address(lf), action: IDiamond.FacetCutAction.Add, functionSelectors: s1
        });
        vm.prank(admin);
        IDiamondCut(address(d)).diamondCut(cut, address(0), "");

        // Read functions still work
        (uint256 stakedAmount, uint256 slashedAmount, uint256 lastRes, uint256 unlock, bool unstake) =
            StakingFacet(address(d)).getStakeInfo(prov);
        assertEq(stakedAmount, 0);
        assertEq(slashedAmount, 0);

        // canProvideService returns true (required stake is 0)
        assertTrue(StakingFacet(address(d)).canProvideService(prov));

        // getRequiredStake returns 0
        assertEq(StakingFacet(address(d)).getRequiredStake(prov), 0);
    }
}
