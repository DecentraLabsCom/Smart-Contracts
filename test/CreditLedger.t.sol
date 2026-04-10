// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.33;

import "forge-std/Test.sol";
import "./BaseTest.sol";
import "../contracts/Diamond.sol";
import "../contracts/facets/diamond/DiamondCutFacet.sol";
import "../contracts/facets/InitFacet.sol";
import "../contracts/facets/ProviderFacet.sol";
import "../contracts/facets/ServiceCreditFacet.sol";
import "../contracts/facets/lab/LabFacet.sol";
import {IDiamondCut} from "../contracts/interfaces/IDiamondCut.sol";
import "../contracts/interfaces/IDiamond.sol";
import {CreditLot, CreditMovement, CreditMovementKind} from "../contracts/libraries/LibAppStorage.sol";
import {LibCreditLedger} from "../contracts/libraries/LibCreditLedger.sol";

/// @title Credit Ledger Tests (MiCA 4.3.d — Lot-based credit model)
/// @notice Tests lot-based mint, lock, capture, release, cancel, expire, adjust
contract CreditLedgerTest is BaseTest {
    Diamond diamond;
    ServiceCreditFacet creditFacet;

    address admin = address(0xA11CE);
    address alice = address(0xA1);
    address bob = address(0xB0B);
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
        ServiceCreditFacet creditFacetImpl = new ServiceCreditFacet();
        LabFacet labFacet = new LabFacet();

        IDiamond.FacetCut[] memory cut2 = new IDiamond.FacetCut[](4);

        // InitFacet
        bytes4[] memory initSelectors = new bytes4[](1);
        initSelectors[0] = _selector("initializeDiamond(string,string,string,string,string)");
        cut2[0] = IDiamond.FacetCut({
            facetAddress: address(initFacet), action: IDiamond.FacetCutAction.Add, functionSelectors: initSelectors
        });

        // ProviderFacet (minimal)
        bytes4[] memory provSelectors = new bytes4[](1);
        provSelectors[0] = _selector("initialize(string,string,string)");
        cut2[1] = IDiamond.FacetCut({
            facetAddress: address(providerFacetImpl), action: IDiamond.FacetCutAction.Add, functionSelectors: provSelectors
        });

        // ServiceCreditFacet (all new + legacy functions)
        bytes4[] memory creditSelectors = new bytes4[](16);
        creditSelectors[0] = _selector("issueServiceCredits(address,uint256,bytes32)");
        creditSelectors[1] = _selector("adjustServiceCredits(address,int256,bytes32)");
        creditSelectors[2] = _selector("getServiceCreditBalance(address)");
        creditSelectors[3] = _selector("getMyServiceCreditBalance()");
        creditSelectors[4] = _selector("mintCredits(address,uint256,bytes32,uint256,uint48)");
        creditSelectors[5] = _selector("lockCredits(address,uint256,bytes32)");
        creditSelectors[6] = _selector("captureLockedCredits(address,uint256,bytes32)");
        creditSelectors[7] = _selector("releaseLockedCredits(address,uint256,bytes32)");
        creditSelectors[8] = _selector("cancelCredits(address,uint256,bytes32)");
        creditSelectors[9] = _selector("expireCredits(address,uint256)");
        creditSelectors[10] = _selector("ledgerAdjustCredits(address,int256,bytes32)");
        creditSelectors[11] = _selector("availableBalanceOf(address)");
        creditSelectors[12] = _selector("lockedBalanceOf(address)");
        creditSelectors[13] = _selector("totalBalanceOf(address)");
        creditSelectors[14] = _selector("getCreditLots(address,uint256,uint256)");
        creditSelectors[15] = _selector("getCreditMovements(address,uint256,uint256)");
        cut2[2] = IDiamond.FacetCut({
            facetAddress: address(creditFacetImpl), action: IDiamond.FacetCutAction.Add, functionSelectors: creditSelectors
        });

        // LabFacet
        bytes4[] memory labSelectors = new bytes4[](1);
        labSelectors[0] = _selector("initialize(string,string)");
        cut2[3] = IDiamond.FacetCut({
            facetAddress: address(labFacet), action: IDiamond.FacetCutAction.Add, functionSelectors: labSelectors
        });

        vm.prank(admin);
        IDiamondCut(address(diamond)).diamondCut(cut2, address(0), "");

        vm.prank(admin);
        InitFacet(address(diamond)).initializeDiamond("Admin", "admin@x", "ES", "Labs", "LS");

        creditFacet = ServiceCreditFacet(address(diamond));
    }

    // ═══════════════════════════════════════════════════════════════════════
    //  mintCredits
    // ═══════════════════════════════════════════════════════════════════════

    function test_mintCredits_creates_lot_and_increases_balance() public {
        bytes32 fundingOrder = keccak256("FO-001");

        vm.prank(admin);
        uint256 lotId = creditFacet.mintCredits(alice, 1000, fundingOrder, 950, 0);

        assertEq(creditFacet.totalBalanceOf(alice), 1000);
        assertEq(creditFacet.availableBalanceOf(alice), 1000);
        assertEq(creditFacet.lockedBalanceOf(alice), 0);

        (CreditLot[] memory lots, uint256 total) = creditFacet.getCreditLots(alice, 0, 10);
        assertEq(total, 1);
        assertEq(lots[0].lotId, lotId);
        assertEq(lots[0].creditAmount, 1000);
        assertEq(lots[0].remaining, 1000);
        assertEq(lots[0].eurGrossAmount, 950);
        assertEq(lots[0].fundingOrderId, fundingOrder);
        assertFalse(lots[0].expired);
    }

    function test_mintCredits_emits_event() public {
        bytes32 fundingOrder = keccak256("FO-002");

        vm.expectEmit(true, true, false, true);
        emit ServiceCreditFacet.CreditLotMinted(alice, 0, 500, 490, fundingOrder, 0);

        vm.prank(admin);
        creditFacet.mintCredits(alice, 500, fundingOrder, 490, 0);
    }

    function test_mintCredits_multiple_lots() public {
        vm.startPrank(admin);
        creditFacet.mintCredits(alice, 100, keccak256("FO-1"), 95, 0);
        creditFacet.mintCredits(alice, 200, keccak256("FO-2"), 190, 0);
        creditFacet.mintCredits(alice, 300, keccak256("FO-3"), 285, 0);
        vm.stopPrank();

        assertEq(creditFacet.totalBalanceOf(alice), 600);

        (CreditLot[] memory lots, uint256 total) = creditFacet.getCreditLots(alice, 0, 10);
        assertEq(total, 3);
        assertEq(lots[0].creditAmount, 100);
        assertEq(lots[1].creditAmount, 200);
        assertEq(lots[2].creditAmount, 300);
    }

    function test_mintCredits_only_admin() public {
        vm.prank(nonAdmin);
        vm.expectRevert();
        creditFacet.mintCredits(alice, 100, bytes32(0), 0, 0);
    }

    // ═══════════════════════════════════════════════════════════════════════
    //  lockCredits
    // ═══════════════════════════════════════════════════════════════════════

    function test_lockCredits_increases_locked_decreases_available() public {
        vm.startPrank(admin);
        creditFacet.mintCredits(alice, 1000, bytes32(0), 0, 0);

        bytes32 resRef = keccak256("RES-001");
        creditFacet.lockCredits(alice, 300, resRef);
        vm.stopPrank();

        assertEq(creditFacet.totalBalanceOf(alice), 1000);
        assertEq(creditFacet.availableBalanceOf(alice), 700);
        assertEq(creditFacet.lockedBalanceOf(alice), 300);
    }

    function test_lockCredits_reverts_insufficient() public {
        vm.startPrank(admin);
        creditFacet.mintCredits(alice, 100, bytes32(0), 0, 0);

        vm.expectRevert();
        creditFacet.lockCredits(alice, 200, bytes32(0));
        vm.stopPrank();
    }

    function test_lockCredits_reverts_when_already_locked() public {
        vm.startPrank(admin);
        creditFacet.mintCredits(alice, 100, bytes32(0), 0, 0);
        creditFacet.lockCredits(alice, 80, bytes32(0));

        // Only 20 available
        vm.expectRevert();
        creditFacet.lockCredits(alice, 30, bytes32(0));
        vm.stopPrank();
    }

    // ═══════════════════════════════════════════════════════════════════════
    //  captureLockedCredits
    // ═══════════════════════════════════════════════════════════════════════

    function test_capture_reduces_locked_and_total() public {
        vm.startPrank(admin);
        creditFacet.mintCredits(alice, 1000, bytes32(0), 0, 0);
        creditFacet.lockCredits(alice, 500, bytes32(0));
        creditFacet.captureLockedCredits(alice, 500, keccak256("RES-DONE"));
        vm.stopPrank();

        assertEq(creditFacet.totalBalanceOf(alice), 500);
        assertEq(creditFacet.availableBalanceOf(alice), 500);
        assertEq(creditFacet.lockedBalanceOf(alice), 0);
    }

    function test_capture_consumes_lots_fifo() public {
        vm.startPrank(admin);
        creditFacet.mintCredits(alice, 100, keccak256("FO-1"), 0, 0);
        creditFacet.mintCredits(alice, 200, keccak256("FO-2"), 0, 0);

        creditFacet.lockCredits(alice, 150, bytes32(0));
        creditFacet.captureLockedCredits(alice, 150, bytes32(0));
        vm.stopPrank();

        (CreditLot[] memory lots,) = creditFacet.getCreditLots(alice, 0, 10);
        // First lot fully consumed (100 - 100 = 0), second partially (200 - 50 = 150)
        assertEq(lots[0].remaining, 0);
        assertEq(lots[1].remaining, 150);
    }

    function test_capture_reverts_when_not_enough_locked() public {
        vm.startPrank(admin);
        creditFacet.mintCredits(alice, 1000, bytes32(0), 0, 0);
        creditFacet.lockCredits(alice, 100, bytes32(0));

        vm.expectRevert();
        creditFacet.captureLockedCredits(alice, 200, bytes32(0));
        vm.stopPrank();
    }

    // ═══════════════════════════════════════════════════════════════════════
    //  releaseLockedCredits
    // ═══════════════════════════════════════════════════════════════════════

    function test_release_returns_locked_to_available() public {
        vm.startPrank(admin);
        creditFacet.mintCredits(alice, 1000, bytes32(0), 0, 0);
        creditFacet.lockCredits(alice, 400, bytes32(0));
        creditFacet.releaseLockedCredits(alice, 400, keccak256("RES-DENIED"));
        vm.stopPrank();

        assertEq(creditFacet.totalBalanceOf(alice), 1000);
        assertEq(creditFacet.availableBalanceOf(alice), 1000);
        assertEq(creditFacet.lockedBalanceOf(alice), 0);
    }

    function test_release_partial() public {
        vm.startPrank(admin);
        creditFacet.mintCredits(alice, 1000, bytes32(0), 0, 0);
        creditFacet.lockCredits(alice, 400, bytes32(0));
        creditFacet.releaseLockedCredits(alice, 100, bytes32(0));
        vm.stopPrank();

        assertEq(creditFacet.availableBalanceOf(alice), 700);
        assertEq(creditFacet.lockedBalanceOf(alice), 300);
    }

    // ═══════════════════════════════════════════════════════════════════════
    //  cancelCredits (refund)
    // ═══════════════════════════════════════════════════════════════════════

    function test_cancel_refunds_and_creates_lot() public {
        vm.startPrank(admin);
        creditFacet.mintCredits(alice, 1000, bytes32(0), 0, 0);
        creditFacet.lockCredits(alice, 500, bytes32(0));
        creditFacet.captureLockedCredits(alice, 500, bytes32(0));

        // Balance now 500. Refund 200.
        bytes32 resRef = keccak256("RES-CANCEL");
        creditFacet.cancelCredits(alice, 200, resRef);
        vm.stopPrank();

        assertEq(creditFacet.totalBalanceOf(alice), 700);

        (CreditLot[] memory lots, uint256 total) = creditFacet.getCreditLots(alice, 0, 10);
        // Original lot + refund lot
        assertEq(total, 2);
        assertEq(lots[1].creditAmount, 200);
        assertEq(lots[1].remaining, 200);
        assertEq(lots[1].eurGrossAmount, 0); // Refund has no EUR
    }

    // ═══════════════════════════════════════════════════════════════════════
    //  expireCredits
    // ═══════════════════════════════════════════════════════════════════════

    function test_expire_lot_deducts_remaining() public {
        vm.startPrank(admin);
        uint48 expiry = uint48(block.timestamp + 100);
        creditFacet.mintCredits(alice, 1000, bytes32(0), 0, expiry);
        vm.stopPrank();

        // Warp past expiry
        vm.warp(block.timestamp + 200);

        vm.prank(admin);
        uint256 expired = creditFacet.expireCredits(alice, 0);

        assertEq(expired, 1000);
        assertEq(creditFacet.totalBalanceOf(alice), 0);
    }

    function test_expire_partial_consumption_then_expire() public {
        vm.startPrank(admin);
        uint48 expiry = uint48(block.timestamp + 100);
        creditFacet.mintCredits(alice, 1000, bytes32(0), 0, expiry);

        // Consume some
        creditFacet.lockCredits(alice, 300, bytes32(0));
        creditFacet.captureLockedCredits(alice, 300, bytes32(0));
        vm.stopPrank();

        // Warp past expiry
        vm.warp(block.timestamp + 200);

        vm.prank(admin);
        uint256 expired = creditFacet.expireCredits(alice, 0);

        assertEq(expired, 700);
        assertEq(creditFacet.totalBalanceOf(alice), 0);
    }

    function test_expire_reverts_when_lot_balance_is_locked() public {
        vm.startPrank(admin);
        uint48 expiry = uint48(block.timestamp + 100);
        creditFacet.mintCredits(alice, 1000, bytes32(0), 0, expiry);
        creditFacet.lockCredits(alice, 400, bytes32("RES-LOCKED"));
        vm.stopPrank();

        vm.warp(block.timestamp + 200);

        vm.prank(admin);
        vm.expectRevert(LibCreditLedger.InsufficientAvailableCredits.selector);
        creditFacet.expireCredits(alice, 0);

        assertEq(creditFacet.totalBalanceOf(alice), 1000);
        assertEq(creditFacet.availableBalanceOf(alice), 600);
        assertEq(creditFacet.lockedBalanceOf(alice), 400);
    }

    function test_expire_reverts_if_not_expired_yet() public {
        vm.startPrank(admin);
        uint48 expiry = uint48(block.timestamp + 1000);
        creditFacet.mintCredits(alice, 100, bytes32(0), 0, expiry);

        vm.expectRevert();
        creditFacet.expireCredits(alice, 0);
        vm.stopPrank();
    }

    function test_expire_reverts_if_no_expiry() public {
        vm.startPrank(admin);
        creditFacet.mintCredits(alice, 100, bytes32(0), 0, 0); // no expiry

        vm.expectRevert();
        creditFacet.expireCredits(alice, 0);
        vm.stopPrank();
    }

    function test_expire_reverts_if_already_expired() public {
        vm.startPrank(admin);
        uint48 expiry = uint48(block.timestamp + 100);
        creditFacet.mintCredits(alice, 100, bytes32(0), 0, expiry);
        vm.stopPrank();

        vm.warp(block.timestamp + 200);

        vm.startPrank(admin);
        creditFacet.expireCredits(alice, 0);

        vm.expectRevert();
        creditFacet.expireCredits(alice, 0);
        vm.stopPrank();
    }

    // ═══════════════════════════════════════════════════════════════════════
    //  ledgerAdjustCredits
    // ═══════════════════════════════════════════════════════════════════════

    function test_adjust_positive_adds_balance_and_lot() public {
        vm.prank(admin);
        uint256 newBal = creditFacet.ledgerAdjustCredits(alice, 500, keccak256("ADJ-001"));

        assertEq(newBal, 500);
        assertEq(creditFacet.totalBalanceOf(alice), 500);

        (CreditLot[] memory lots, uint256 total) = creditFacet.getCreditLots(alice, 0, 10);
        assertEq(total, 1);
        assertEq(lots[0].creditAmount, 500);
    }

    function test_adjust_negative_deducts_from_available() public {
        vm.startPrank(admin);
        creditFacet.mintCredits(alice, 1000, bytes32(0), 0, 0);
        uint256 newBal = creditFacet.ledgerAdjustCredits(alice, -300, keccak256("ADJ-002"));
        vm.stopPrank();

        assertEq(newBal, 700);
        assertEq(creditFacet.totalBalanceOf(alice), 700);
    }

    function test_adjust_negative_reverts_insufficient() public {
        vm.startPrank(admin);
        creditFacet.mintCredits(alice, 100, bytes32(0), 0, 0);
        creditFacet.lockCredits(alice, 80, bytes32(0)); // only 20 available

        vm.expectRevert();
        creditFacet.ledgerAdjustCredits(alice, -50, bytes32(0));
        vm.stopPrank();
    }

    // ═══════════════════════════════════════════════════════════════════════
    //  Credit movements audit trail
    // ═══════════════════════════════════════════════════════════════════════

    function test_movements_recorded_for_full_lifecycle() public {
        bytes32 fo = keccak256("FO-AUDIT");
        bytes32 res = keccak256("RES-AUDIT");

        vm.startPrank(admin);
        creditFacet.mintCredits(alice, 1000, fo, 950, 0);       // MINT
        creditFacet.lockCredits(alice, 300, res);                 // LOCK
        creditFacet.captureLockedCredits(alice, 200, res);        // CAPTURE
        creditFacet.releaseLockedCredits(alice, 100, res);        // RELEASE
        creditFacet.cancelCredits(alice, 50, res);                // CANCEL
        creditFacet.ledgerAdjustCredits(alice, -10, keccak256("ADJ")); // ADJUST
        vm.stopPrank();

        (CreditMovement[] memory mvs, uint256 total) = creditFacet.getCreditMovements(alice, 0, 50);
        assertEq(total, 6);
        assertEq(uint8(mvs[0].kind), uint8(CreditMovementKind.MINT));
        assertEq(uint8(mvs[1].kind), uint8(CreditMovementKind.LOCK));
        assertEq(uint8(mvs[2].kind), uint8(CreditMovementKind.CAPTURE));
        assertEq(uint8(mvs[3].kind), uint8(CreditMovementKind.RELEASE));
        assertEq(uint8(mvs[4].kind), uint8(CreditMovementKind.CANCEL));
        assertEq(uint8(mvs[5].kind), uint8(CreditMovementKind.ADJUST));
    }

    function test_movement_balance_snapshots_correct() public {
        vm.startPrank(admin);
        creditFacet.mintCredits(alice, 1000, bytes32(0), 0, 0);
        creditFacet.lockCredits(alice, 400, bytes32(0));
        vm.stopPrank();

        (CreditMovement[] memory mvs,) = creditFacet.getCreditMovements(alice, 0, 10);
        // After MINT: balance=1000, locked=0
        assertEq(mvs[0].balanceAfter, 1000);
        assertEq(mvs[0].lockedAfter, 0);
        // After LOCK: balance=1000, locked=400
        assertEq(mvs[1].balanceAfter, 1000);
        assertEq(mvs[1].lockedAfter, 400);
    }

    // ═══════════════════════════════════════════════════════════════════════
    //  Pagination
    // ═══════════════════════════════════════════════════════════════════════

    function test_getCreditLots_pagination() public {
        vm.startPrank(admin);
        for (uint256 i; i < 5; i++) {
            creditFacet.mintCredits(alice, 100 * (i + 1), bytes32(i), 0, 0);
        }
        vm.stopPrank();

        (CreditLot[] memory page1, uint256 total) = creditFacet.getCreditLots(alice, 0, 3);
        assertEq(total, 5);
        assertEq(page1.length, 3);
        assertEq(page1[0].creditAmount, 100);
        assertEq(page1[2].creditAmount, 300);

        (CreditLot[] memory page2,) = creditFacet.getCreditLots(alice, 3, 10);
        assertEq(page2.length, 2);
        assertEq(page2[0].creditAmount, 400);
        assertEq(page2[1].creditAmount, 500);
    }

    function test_getCreditLots_offset_beyond_total_returns_empty() public {
        vm.prank(admin);
        creditFacet.mintCredits(alice, 100, bytes32(0), 0, 0);

        (CreditLot[] memory lots, uint256 total) = creditFacet.getCreditLots(alice, 10, 5);
        assertEq(total, 1);
        assertEq(lots.length, 0);
    }

    // ═══════════════════════════════════════════════════════════════════════
    //  Legacy API backward compatibility
    // ═══════════════════════════════════════════════════════════════════════

    function test_legacy_issueServiceCredits_still_works() public {
        vm.prank(admin);
        uint256 bal = creditFacet.issueServiceCredits(alice, 500, keccak256("LEGACY"));

        assertEq(bal, 500);
        assertEq(creditFacet.getServiceCreditBalance(alice), 500);
        // Legacy credits appear in totalBalance too
        assertEq(creditFacet.totalBalanceOf(alice), 500);
    }

    function test_legacy_adjustServiceCredits_still_works() public {
        vm.startPrank(admin);
        creditFacet.issueServiceCredits(alice, 1000, bytes32(0));
        uint256 bal = creditFacet.adjustServiceCredits(alice, -200, keccak256("ADJ-L"));
        vm.stopPrank();

        assertEq(bal, 800);
    }

    // ═══════════════════════════════════════════════════════════════════════
    //  Access control
    // ═══════════════════════════════════════════════════════════════════════

    function test_nonAdmin_cannot_mintCredits() public {
        vm.prank(nonAdmin);
        vm.expectRevert();
        creditFacet.mintCredits(alice, 100, bytes32(0), 0, 0);
    }

    function test_nonAdmin_cannot_lockCredits() public {
        vm.prank(nonAdmin);
        vm.expectRevert();
        creditFacet.lockCredits(alice, 100, bytes32(0));
    }

    function test_nonAdmin_cannot_captureCredits() public {
        vm.prank(nonAdmin);
        vm.expectRevert();
        creditFacet.captureLockedCredits(alice, 100, bytes32(0));
    }

    function test_nonAdmin_cannot_releaseCredits() public {
        vm.prank(nonAdmin);
        vm.expectRevert();
        creditFacet.releaseLockedCredits(alice, 100, bytes32(0));
    }

    function test_nonAdmin_cannot_expireCredits() public {
        vm.prank(nonAdmin);
        vm.expectRevert();
        creditFacet.expireCredits(alice, 0);
    }

    // ═══════════════════════════════════════════════════════════════════════
    //  Full lifecycle scenario
    // ═══════════════════════════════════════════════════════════════════════

    function test_full_lifecycle_mint_lock_capture_cancel() public {
        vm.startPrank(admin);

        // 1. Mint 1000 credits from funding order
        creditFacet.mintCredits(alice, 1000, keccak256("FO-LIFE"), 950, 0);
        assertEq(creditFacet.availableBalanceOf(alice), 1000);

        // 2. Lock 300 for a reservation
        bytes32 res1 = keccak256("RES-1");
        creditFacet.lockCredits(alice, 300, res1);
        assertEq(creditFacet.availableBalanceOf(alice), 700);
        assertEq(creditFacet.lockedBalanceOf(alice), 300);

        // 3. Lock another 200 for a second reservation
        bytes32 res2 = keccak256("RES-2");
        creditFacet.lockCredits(alice, 200, res2);
        assertEq(creditFacet.availableBalanceOf(alice), 500);
        assertEq(creditFacet.lockedBalanceOf(alice), 500);

        // 4. Capture first reservation
        creditFacet.captureLockedCredits(alice, 300, res1);
        assertEq(creditFacet.totalBalanceOf(alice), 700);
        assertEq(creditFacet.lockedBalanceOf(alice), 200);
        assertEq(creditFacet.availableBalanceOf(alice), 500);

        // 5. Release (deny) second reservation
        creditFacet.releaseLockedCredits(alice, 200, res2);
        assertEq(creditFacet.totalBalanceOf(alice), 700);
        assertEq(creditFacet.lockedBalanceOf(alice), 0);
        assertEq(creditFacet.availableBalanceOf(alice), 700);

        // 6. Cancel partial refund from first reservation
        creditFacet.cancelCredits(alice, 100, res1);
        assertEq(creditFacet.totalBalanceOf(alice), 800);

        vm.stopPrank();

        // Verify lot state
        (CreditLot[] memory lots,) = creditFacet.getCreditLots(alice, 0, 10);
        assertEq(lots.length, 2); // original + refund
        assertEq(lots[0].remaining, 700); // 1000 - 300 captured
        assertEq(lots[1].remaining, 100); // refund lot
    }
}
