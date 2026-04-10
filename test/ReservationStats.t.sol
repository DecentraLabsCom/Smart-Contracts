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
import "../contracts/facets/reservation/ReservationStatsFacet.sol";
import "../contracts/libraries/LibAppStorage.sol";
import "../contracts/libraries/RivalIntervalTreeLibrary.sol";
import {IDiamondCut} from "../contracts/interfaces/IDiamondCut.sol";
import "../contracts/interfaces/IDiamond.sol";

/// @dev TEST ONLY — seeds `AppStorage.calendars[tokenId]` from the diamond context
contract ReservationStatsCalendarSeedFacet {
    using RivalIntervalTreeLibrary for Tree;

    function seedCalendarInterval(
        uint256 tokenId,
        uint32 start,
        uint32 end
    ) external {
        LibAppStorage.diamondStorage().calendars[tokenId].insert(start, end);
    }
}

/// @title ReservationStats Test
/// @notice Dedicated tests for ReservationStatsFacet
/// @dev Same diamond shell as LabQuery.t.sol + calendar seed facet (never deploy seed to prod)
contract ReservationStatsTest is BaseTest {
    Diamond diamond;
    LabAdminFacet labAdmin;
    LabFacet labFacet;
    ReservationStatsFacet stats;
    ReservationStatsCalendarSeedFacet seed;
    ProviderFacet providerFacet;

    address admin = address(0xA11CE);
    address provider1 = address(0xDEAD);
    address outsider = address(0xCAFE);

    uint32 internal constant _T0 = 1_000_000;

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
        ReservationStatsFacet statsImpl = new ReservationStatsFacet();
        ReservationStatsCalendarSeedFacet seedImpl = new ReservationStatsCalendarSeedFacet();

        IDiamond.FacetCut[] memory cut2 = new IDiamond.FacetCut[](6);

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

        bytes4[] memory statsSelectors = new bytes4[](2);
        statsSelectors[0] = _selector("getReservationStats(uint256,uint32,uint32)");
        statsSelectors[1] = _selector("getReservationStatsPaginated(uint256,uint32,uint32,uint32,uint256)");
        cut2[4] = IDiamond.FacetCut({
            facetAddress: address(statsImpl), action: IDiamond.FacetCutAction.Add, functionSelectors: statsSelectors
        });

        bytes4[] memory seedSelectors = new bytes4[](1);
        seedSelectors[0] = _selector("seedCalendarInterval(uint256,uint32,uint32)");
        cut2[5] = IDiamond.FacetCut({
            facetAddress: address(seedImpl), action: IDiamond.FacetCutAction.Add, functionSelectors: seedSelectors
        });

        vm.prank(admin);
        IDiamondCut(address(diamond)).diamondCut(cut2, address(0), "");

        vm.prank(admin);
        InitFacet(address(diamond)).initializeDiamond("Admin", "admin@x", "ES", "Labs", "LS");

        providerFacet = ProviderFacet(address(diamond));
        labFacet = LabFacet(address(diamond));
        labAdmin = LabAdminFacet(address(diamond));
        stats = ReservationStatsFacet(address(diamond));
        seed = ReservationStatsCalendarSeedFacet(address(diamond));

        vm.prank(admin);
        providerFacet.addProvider("Provider1", provider1, "p1@x", "ES", "https://p1.example.com/auth");
    }

    function _mintLab1() internal {
        vm.prank(provider1);
        labAdmin.addLab("ipfs://lab1", 50 ether, "https://access.lab1.com", "key-abc", 0);
    }

    // ──────────────────────────────────────────────
    //  getReservationStats
    // ──────────────────────────────────────────────

    function test_getReservationStats_empty_calendar() public {
        _mintLab1();
        vm.prank(admin);
        (uint32 count, uint32 firstStart, uint32 lastEnd, uint256 totalDuration) =
            stats.getReservationStats(1, _T0, _T0 + 10_000);
        assertEq(count, 0);
        assertEq(firstStart, 0);
        assertEq(lastEnd, 0);
        assertEq(totalDuration, 0);
    }

    function test_getReservationStats_nonexistent_token_reverts() public {
        vm.prank(admin);
        vm.expectRevert();
        stats.getReservationStats(999, _T0, _T0 + 100);
    }

    function test_getReservationStats_invalid_range_reverts() public {
        _mintLab1();
        vm.prank(admin);
        vm.expectRevert(bytes("Invalid time range"));
        stats.getReservationStats(1, _T0 + 100, _T0);
    }

    function test_getReservationStats_non_admin_reverts() public {
        _mintLab1();
        vm.prank(outsider);
        vm.expectRevert(bytes("Only admin can call this function"));
        stats.getReservationStats(1, _T0, _T0 + 10_000);
    }

    function test_getReservationStats_single_interval_full_overlap() public {
        _mintLab1();
        seed.seedCalendarInterval(1, _T0 + 1000, _T0 + 2000);

        vm.prank(admin);
        (uint32 count, uint32 firstStart, uint32 lastEnd, uint256 totalDuration) =
            stats.getReservationStats(1, _T0 + 500, _T0 + 3000);

        assertEq(count, 1);
        assertEq(firstStart, _T0 + 1000);
        assertEq(lastEnd, _T0 + 2000);
        assertEq(totalDuration, 1000);
    }

    function test_getReservationStats_clips_to_query_window() public {
        _mintLab1();
        seed.seedCalendarInterval(1, _T0 + 1000, _T0 + 3000);

        vm.prank(admin);
        (uint32 count,,, uint256 totalDuration) = stats.getReservationStats(1, _T0 + 1500, _T0 + 2000);

        assertEq(count, 1);
        assertEq(totalDuration, 500);
    }

    function test_getReservationStats_two_intervals() public {
        _mintLab1();
        seed.seedCalendarInterval(1, _T0 + 1000, _T0 + 1100);
        seed.seedCalendarInterval(1, _T0 + 1200, _T0 + 1300);

        vm.prank(admin);
        (uint32 count, uint32 firstStart, uint32 lastEnd, uint256 totalDuration) =
            stats.getReservationStats(1, _T0 + 900, _T0 + 2000);

        assertEq(count, 2);
        assertEq(firstStart, _T0 + 1000);
        assertEq(lastEnd, _T0 + 1300);
        assertEq(totalDuration, 200);
    }

    function test_getReservationStats_requires_paginated_when_over_page() public {
        _mintLab1();
        for (uint256 i = 0; i < 501; i++) {
            uint32 s = uint32(_T0 + uint32(i * 30));
            seed.seedCalendarInterval(1, s, s + 10);
        }

        vm.prank(admin);
        vm.expectRevert(bytes("Use getReservationStatsPaginated"));
        stats.getReservationStats(1, _T0, _T0 + 20_000);
    }

    // ──────────────────────────────────────────────
    //  getReservationStatsPaginated
    // ──────────────────────────────────────────────

    function test_getReservationStatsPaginated_invalid_limit_reverts() public {
        _mintLab1();
        vm.startPrank(admin);
        vm.expectRevert(bytes("Invalid limit"));
        stats.getReservationStatsPaginated(1, _T0, _T0 + 1000, 0, 0);

        vm.expectRevert(bytes("Invalid limit"));
        stats.getReservationStatsPaginated(1, _T0, _T0 + 1000, 0, 501);
        vm.stopPrank();
    }

    function test_getReservationStatsPaginated_invalid_cursor_reverts() public {
        _mintLab1();
        vm.prank(admin);
        vm.expectRevert(bytes("Invalid cursor"));
        stats.getReservationStatsPaginated(1, _T0 + 1000, _T0 + 2000, _T0 + 500, 10);
    }

    function test_getReservationStatsPaginated_cursor_zero_uses_range_start() public {
        _mintLab1();
        seed.seedCalendarInterval(1, _T0 + 1000, _T0 + 1100);

        vm.prank(admin);
        (uint32 count,,,, uint32 nextCs, bool more) =
            stats.getReservationStatsPaginated(1, _T0 + 1000, _T0 + 2000, 0, 10);
        assertEq(count, 1);
        assertFalse(more);
        assertEq(nextCs, 0);
    }

    function test_getReservationStatsPaginated_second_page() public {
        _mintLab1();
        seed.seedCalendarInterval(1, _T0 + 1000, _T0 + 1100);
        seed.seedCalendarInterval(1, _T0 + 1200, _T0 + 1300);

        vm.startPrank(admin);
        (uint32 c1,,, uint256 d1, uint32 nextStart, bool more1) =
            stats.getReservationStatsPaginated(1, _T0 + 900, _T0 + 2000, 0, 1);
        assertEq(c1, 1);
        assertTrue(more1);
        assertEq(d1, 100);

        (uint32 c2,,, uint256 d2,, bool more2) =
            stats.getReservationStatsPaginated(1, _T0 + 900, _T0 + 2000, nextStart, 1);
        assertEq(c2, 1);
        assertFalse(more2);
        assertEq(d2, 100);
        vm.stopPrank();
    }

    function test_getReservationStatsPaginated_empty_when_cursor_past_range() public {
        _mintLab1();
        seed.seedCalendarInterval(1, _T0 + 1000, _T0 + 1100);

        vm.prank(admin);
        (uint32 count,,,,, bool more) = stats.getReservationStatsPaginated(1, _T0 + 900, _T0 + 950, _T0 + 2000, 10);
        assertEq(count, 0);
        assertFalse(more);
    }
}
