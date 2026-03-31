// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.33;

import "forge-std/Test.sol";
import "./BaseTest.sol";
import "../contracts/Diamond.sol";
import "../contracts/facets/diamond/DiamondCutFacet.sol";
import "../contracts/facets/InitFacet.sol";
import "../contracts/facets/ProviderFacet.sol";
import "../contracts/facets/lab/LabFacet.sol";
import {IDiamondCut} from "../contracts/interfaces/IDiamondCut.sol";
import "../contracts/interfaces/IDiamond.sol";
import {ProviderNetworkStatus} from "../contracts/libraries/LibAppStorage.sol";

/// @title Provider Network Status Tests (MiCA 4.3.d — Limited-Network Enforcement)
/// @notice Tests that providers must have ACTIVE network status to participate
contract ProviderNetworkStatusTest is BaseTest {
    Diamond diamond;
    ProviderFacet providerFacet;

    address admin = address(0xA11CE);
    address prov1 = address(0xDEAD);
    address prov2 = address(0xBEEF);
    address nonAdmin = address(0xBAD);

    function _selector(string memory sig) internal pure returns (bytes4) {
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
        LabFacet labFacet = new LabFacet();

        IDiamond.FacetCut[] memory cut2 = new IDiamond.FacetCut[](3);

        bytes4[] memory initSelectors = new bytes4[](1);
        initSelectors[0] = _selector("initializeDiamond(string,string,string,string,string)");
        cut2[0] = IDiamond.FacetCut({
            facetAddress: address(initFacet), action: IDiamond.FacetCutAction.Add, functionSelectors: initSelectors
        });

        bytes4[] memory providerSelectors = new bytes4[](8);
        providerSelectors[0] = _selector("initialize(string,string,string)");
        providerSelectors[1] = _selector("addProvider(string,address,string,string,string)");
        providerSelectors[2] = _selector("removeProvider(address)");
        providerSelectors[3] = _selector("updateProvider(string,string,string)");
        providerSelectors[4] = _selector("isLabProvider(address)");
        providerSelectors[5] = _selector("setProviderNetworkStatus(address,uint8)");
        providerSelectors[6] = _selector("getProviderNetworkStatus(address)");
        providerSelectors[7] = _selector("isProviderNetworkActive(address)");
        cut2[1] = IDiamond.FacetCut({
            facetAddress: address(providerFacetImpl),
            action: IDiamond.FacetCutAction.Add,
            functionSelectors: providerSelectors
        });

        bytes4[] memory labSelectors = new bytes4[](1);
        labSelectors[0] = _selector("initialize(string,string)");
        cut2[2] = IDiamond.FacetCut({
            facetAddress: address(labFacet), action: IDiamond.FacetCutAction.Add, functionSelectors: labSelectors
        });

        vm.prank(admin);
        IDiamondCut(address(diamond)).diamondCut(cut2, address(0), "");

        vm.prank(admin);
        InitFacet(address(diamond)).initializeDiamond("Admin", "admin@x", "ES", "Labs", "LS");

        providerFacet = ProviderFacet(address(diamond));
    }

    // ── addProvider sets ACTIVE ──────────────────────────────────────────
    function test_addProvider_sets_active_network_status() public {
        vm.prank(admin);
        providerFacet.addProvider("Provider1", prov1, "p1@x.com", "ES", "");

        assertEq(
            uint8(providerFacet.getProviderNetworkStatus(prov1)),
            uint8(ProviderNetworkStatus.ACTIVE)
        );
        assertTrue(providerFacet.isProviderNetworkActive(prov1));
    }

    // ── removeProvider sets TERMINATED ───────────────────────────────────
    function test_removeProvider_sets_terminated_status() public {
        vm.startPrank(admin);
        providerFacet.addProvider("Provider1", prov1, "p1@x.com", "ES", "");
        providerFacet.removeProvider(prov1);
        vm.stopPrank();

        assertEq(
            uint8(providerFacet.getProviderNetworkStatus(prov1)),
            uint8(ProviderNetworkStatus.TERMINATED)
        );
        assertFalse(providerFacet.isProviderNetworkActive(prov1));
    }

    // ── Admin can suspend provider ──────────────────────────────────────
    function test_admin_can_suspend_provider() public {
        vm.startPrank(admin);
        providerFacet.addProvider("Provider1", prov1, "p1@x.com", "ES", "");
        providerFacet.setProviderNetworkStatus(prov1, ProviderNetworkStatus.SUSPENDED);
        vm.stopPrank();

        assertEq(
            uint8(providerFacet.getProviderNetworkStatus(prov1)),
            uint8(ProviderNetworkStatus.SUSPENDED)
        );
        assertFalse(providerFacet.isProviderNetworkActive(prov1));
    }

    // ── Admin can reactivate suspended provider ─────────────────────────
    function test_admin_can_reactivate_suspended_provider() public {
        vm.startPrank(admin);
        providerFacet.addProvider("Provider1", prov1, "p1@x.com", "ES", "");
        providerFacet.setProviderNetworkStatus(prov1, ProviderNetworkStatus.SUSPENDED);
        providerFacet.setProviderNetworkStatus(prov1, ProviderNetworkStatus.ACTIVE);
        vm.stopPrank();

        assertTrue(providerFacet.isProviderNetworkActive(prov1));
    }

    // ── Cannot set status to NONE ───────────────────────────────────────
    function test_cannot_set_status_to_none() public {
        vm.startPrank(admin);
        providerFacet.addProvider("Provider1", prov1, "p1@x.com", "ES", "");
        vm.expectRevert(bytes("Cannot set status to NONE"));
        providerFacet.setProviderNetworkStatus(prov1, ProviderNetworkStatus.NONE);
        vm.stopPrank();
    }

    // ── Cannot change terminated provider ───────────────────────────────
    function test_cannot_change_terminated_provider() public {
        vm.startPrank(admin);
        providerFacet.addProvider("Provider1", prov1, "p1@x.com", "ES", "");
        providerFacet.setProviderNetworkStatus(prov1, ProviderNetworkStatus.TERMINATED);
        vm.expectRevert(bytes("Cannot change status of terminated provider"));
        providerFacet.setProviderNetworkStatus(prov1, ProviderNetworkStatus.ACTIVE);
        vm.stopPrank();
    }

    // ── Cannot set same status ──────────────────────────────────────────
    function test_cannot_set_same_status() public {
        vm.startPrank(admin);
        providerFacet.addProvider("Provider1", prov1, "p1@x.com", "ES", "");
        vm.expectRevert(bytes("Status already set"));
        providerFacet.setProviderNetworkStatus(prov1, ProviderNetworkStatus.ACTIVE);
        vm.stopPrank();
    }

    // ── Non-admin cannot set network status ─────────────────────────────
    function test_nonAdmin_cannot_set_network_status() public {
        vm.prank(admin);
        providerFacet.addProvider("Provider1", prov1, "p1@x.com", "ES", "");

        vm.prank(nonAdmin);
        vm.expectRevert();
        providerFacet.setProviderNetworkStatus(prov1, ProviderNetworkStatus.SUSPENDED);
    }

    // ── Non-existent provider cannot have status set ────────────────────
    function test_cannot_set_status_for_nonexistent_provider() public {
        vm.prank(admin);
        vm.expectRevert(bytes("Provider does not exist"));
        providerFacet.setProviderNetworkStatus(prov1, ProviderNetworkStatus.ACTIVE);
    }

    // ── Default status for non-registered address is NONE ───────────────
    function test_default_status_is_none() public view {
        assertEq(
            uint8(providerFacet.getProviderNetworkStatus(prov1)),
            uint8(ProviderNetworkStatus.NONE)
        );
        assertFalse(providerFacet.isProviderNetworkActive(prov1));
    }

    // ── ProviderNetworkStatusChanged event emitted on add ───────────────
    function test_event_emitted_on_add_provider() public {
        vm.expectEmit(true, false, false, true);
        emit ProviderFacet.ProviderNetworkStatusChanged(
            prov1, ProviderNetworkStatus.NONE, ProviderNetworkStatus.ACTIVE
        );

        vm.prank(admin);
        providerFacet.addProvider("Provider1", prov1, "p1@x.com", "ES", "");
    }

    // ── ProviderNetworkStatusChanged event emitted on suspend ───────────
    function test_event_emitted_on_suspend() public {
        vm.prank(admin);
        providerFacet.addProvider("Provider1", prov1, "p1@x.com", "ES", "");

        vm.expectEmit(true, false, false, true);
        emit ProviderFacet.ProviderNetworkStatusChanged(
            prov1, ProviderNetworkStatus.ACTIVE, ProviderNetworkStatus.SUSPENDED
        );

        vm.prank(admin);
        providerFacet.setProviderNetworkStatus(prov1, ProviderNetworkStatus.SUSPENDED);
    }

    // ── ProviderNetworkStatusChanged event emitted on remove ────────────
    function test_event_emitted_on_remove_provider() public {
        vm.prank(admin);
        providerFacet.addProvider("Provider1", prov1, "p1@x.com", "ES", "");

        vm.expectEmit(true, false, false, true);
        emit ProviderFacet.ProviderNetworkStatusChanged(
            prov1, ProviderNetworkStatus.ACTIVE, ProviderNetworkStatus.TERMINATED
        );

        vm.prank(admin);
        providerFacet.removeProvider(prov1);
    }
}
