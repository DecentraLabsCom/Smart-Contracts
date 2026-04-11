// SPDX-License-Identifier: MIT
pragma solidity ^0.8.33;

import {Test} from "forge-std/Test.sol";
import {ERC721} from "@openzeppelin/contracts/token/ERC721/ERC721.sol";
import {EnumerableSet} from "@openzeppelin/contracts/utils/structs/EnumerableSet.sol";
import {ProviderSettlementFacet} from "../contracts/facets/reservation/ProviderSettlementFacet.sol";
import {AppStorage, LibAppStorage} from "../contracts/libraries/LibAppStorage.sol";
import {LibAccessControlEnumerable} from "../contracts/libraries/LibAccessControlEnumerable.sol";
import {LibProviderReceivable, SETTLEMENT_OPERATOR_ROLE} from "../contracts/libraries/LibProviderReceivable.sol";
import {LibERC721StorageTestHelper} from "./LibERC721StorageTestHelper.sol";

// ---------------------------------------------------------------------------
// Harness: exposes LibProviderReceivable helpers + ProviderSettlementFacet for role
// and lifecycle tests, plus ERC721 transfer for the unsettled-receivable guard.
// ---------------------------------------------------------------------------
contract ReceivableHardeningHarness is ERC721, ProviderSettlementFacet {
    using LibAccessControlEnumerable for AppStorage;
    using EnumerableSet for EnumerableSet.AddressSet;

    constructor() ERC721("Labs", "LAB") {}

    // ---- Setup helpers ----

    function initialize(address admin, address provider, uint256 labId) external {
        AppStorage storage s = LibAppStorage.diamondStorage();
        s.DEFAULT_ADMIN_ROLE = keccak256("DEFAULT_ADMIN_ROLE");
        s.roleMembers[s.DEFAULT_ADMIN_ROLE].add(admin);
        s._addProviderRole(provider, "provider", "p@x.com", "ES", "");
        _mint(provider, labId);
        LibERC721StorageTestHelper.setOwnerForTest(labId, provider);
    }

    function addProvider(address provider) external {
        AppStorage storage s = LibAppStorage.diamondStorage();
        s._addProviderRole(provider, "provider2", "p2@x.com", "ES", "");
    }

    function grantSettlementOperatorRole(address account) external {
        AppStorage storage s = LibAppStorage.diamondStorage();
        s.roleMembers[SETTLEMENT_OPERATOR_ROLE].add(account);
    }

    // ---- Storage setters ----

    function setReceivableBucket(uint256 labId, uint8 state, uint256 amount) external {
        AppStorage storage s = LibAppStorage.diamondStorage();
        if (state == 1) s.providerReceivableAccrued[labId] = amount;
        else if (state == 2) s.providerSettlementQueue[labId] = amount;
        else if (state == 3) s.providerReceivableInvoiced[labId] = amount;
        else if (state == 4) s.providerReceivableApproved[labId] = amount;
        else if (state == 5) s.providerReceivablePaid[labId] = amount;
        else if (state == 6) s.providerReceivableReversed[labId] = amount;
        else if (state == 7) s.providerReceivableDisputed[labId] = amount;
        else revert("bad state");
    }

    // ---- LibProviderReceivable wrappers ----

    function hasUnsettledReceivable(uint256 labId) external view returns (bool) {
        return LibProviderReceivable.hasUnsettledReceivable(labId);
    }

    function accrueReceivable(uint256 labId, uint256 amount, bytes32 key) external {
        LibProviderReceivable.accrueReceivable(labId, amount, key);
    }

    function updateAccruedTimestamp(uint256 labId, uint256 ts) external {
        LibProviderReceivable.updateAccruedTimestamp(labId, ts);
    }

    // ---- Transfer guard (mirrors LabFacet._update logic) ----

    function transferLabToken(address from, address to, uint256 tokenId) external {
        AppStorage storage s = LibAppStorage.diamondStorage();
        require(
            !LibProviderReceivable.hasUnsettledReceivable(tokenId),
            "Lab has unsettled receivables"
        );
        _transfer(from, to, tokenId);
    }

    // ---- Staking stub required by ProviderSettlementFacet ----

    function updateLastReservation(address) external {}
}

// ---------------------------------------------------------------------------
// Minimal ERC20 mock for the lab-token address
// ---------------------------------------------------------------------------
contract MockERC20 is ERC721("Mock", "M") {
    // Nothing needed — only used as labTokenAddress placeholder.
}

// ---------------------------------------------------------------------------
// Tests
// ---------------------------------------------------------------------------
contract ProviderReceivableHardeningTest is Test {
    ReceivableHardeningHarness internal h;

    address internal constant ADMIN = address(0xAD);
    address internal constant PROVIDER = address(0xABCD);
    address internal constant PROVIDER2 = address(0xBBBB);
    address internal constant SETTLER = address(0x5E77);
    address internal constant NOBODY = address(0xDEAD);
    uint256 internal constant LAB = 7;
    uint256 internal constant ONE_CREDIT = 100_000;
    uint256 internal constant THREE_CREDITS = 300_000;
    uint256 internal constant FIVE_CREDITS = 500_000;
    uint256 internal constant SEVEN_CREDITS = 700_000;
    uint256 internal constant TEN_CREDITS = 1_000_000;
    uint256 internal constant FORTY_TWO_CREDITS = 4_200_000;
    uint256 internal constant FIFTY_CREDITS = 5_000_000;
    uint256 internal constant NINETY_NINE_CREDITS = 9_900_000;
    uint256 internal constant ONE_HUNDRED_CREDITS = 10_000_000;

    event ProviderReceivableAccrued(
        uint256 indexed labId,
        uint256 amount,
        bytes32 indexed reservationKey
    );

    function setUp() public {
        h = new ReceivableHardeningHarness();
        h.initialize(ADMIN, PROVIDER, LAB);
        h.addProvider(PROVIDER2);
    }

    // =====================================================================
    //  1. hasUnsettledReceivable — true for every non-terminal bucket
    // =====================================================================

    function test_hasUnsettled_accrued() public {
        h.setReceivableBucket(LAB, 1, ONE_CREDIT);
        assertTrue(h.hasUnsettledReceivable(LAB));
    }

    function test_hasUnsettled_queued() public {
        h.setReceivableBucket(LAB, 2, ONE_CREDIT);
        assertTrue(h.hasUnsettledReceivable(LAB));
    }

    function test_hasUnsettled_invoiced() public {
        h.setReceivableBucket(LAB, 3, ONE_CREDIT);
        assertTrue(h.hasUnsettledReceivable(LAB));
    }

    function test_hasUnsettled_approved() public {
        h.setReceivableBucket(LAB, 4, ONE_CREDIT);
        assertTrue(h.hasUnsettledReceivable(LAB));
    }

    function test_hasUnsettled_disputed() public {
        h.setReceivableBucket(LAB, 7, ONE_CREDIT);
        assertTrue(h.hasUnsettledReceivable(LAB));
    }

    // =====================================================================
    //  2. hasUnsettledReceivable — false for terminal-only states
    // =====================================================================

    function test_noUnsettled_zero() public view {
        assertFalse(h.hasUnsettledReceivable(LAB));
    }

    function test_noUnsettled_paid_only() public {
        h.setReceivableBucket(LAB, 5, NINETY_NINE_CREDITS);
        assertFalse(h.hasUnsettledReceivable(LAB));
    }

    function test_noUnsettled_reversed_only() public {
        h.setReceivableBucket(LAB, 6, FORTY_TWO_CREDITS);
        assertFalse(h.hasUnsettledReceivable(LAB));
    }

    function test_noUnsettled_both_terminal() public {
        h.setReceivableBucket(LAB, 5, FIFTY_CREDITS);
        h.setReceivableBucket(LAB, 6, TEN_CREDITS);
        assertFalse(h.hasUnsettledReceivable(LAB));
    }

    // =====================================================================
    //  3. Transfer guard — blocked when any unsettled bucket > 0
    // =====================================================================

    function test_transfer_blocked_accrued() public {
        h.setReceivableBucket(LAB, 1, 1);
        vm.prank(PROVIDER);
        vm.expectRevert("Lab has unsettled receivables");
        h.transferLabToken(PROVIDER, PROVIDER2, LAB);
    }

    function test_transfer_blocked_invoiced() public {
        h.setReceivableBucket(LAB, 3, 1);
        vm.prank(PROVIDER);
        vm.expectRevert("Lab has unsettled receivables");
        h.transferLabToken(PROVIDER, PROVIDER2, LAB);
    }

    function test_transfer_blocked_disputed() public {
        h.setReceivableBucket(LAB, 7, 1);
        vm.prank(PROVIDER);
        vm.expectRevert("Lab has unsettled receivables");
        h.transferLabToken(PROVIDER, PROVIDER2, LAB);
    }

    // =====================================================================
    //  4. Transfer guard — allowed when only terminal balances exist
    // =====================================================================

    function test_transfer_allowed_zero() public {
        vm.prank(PROVIDER);
        h.transferLabToken(PROVIDER, PROVIDER2, LAB);
        assertEq(h.ownerOf(LAB), PROVIDER2);
    }

    function test_transfer_allowed_only_paid() public {
        h.setReceivableBucket(LAB, 5, ONE_HUNDRED_CREDITS);
        vm.prank(PROVIDER);
        h.transferLabToken(PROVIDER, PROVIDER2, LAB);
        assertEq(h.ownerOf(LAB), PROVIDER2);
    }

    // =====================================================================
    //  5. accrueReceivable — event emission with correct fields
    // =====================================================================

    function test_accrueReceivable_emits_event() public {
        bytes32 key = keccak256(abi.encodePacked(uint256(LAB), uint256(1000)));

        vm.expectEmit(true, true, false, true);
        emit ProviderReceivableAccrued(LAB, FIVE_CREDITS, key);
        h.accrueReceivable(LAB, FIVE_CREDITS, key);
    }

    function test_accrueReceivable_increments_bucket() public {
        bytes32 key = bytes32("r1");
        h.accrueReceivable(LAB, THREE_CREDITS, key);
        h.accrueReceivable(LAB, SEVEN_CREDITS, bytes32("r2"));

        // Bucket should now total 10 credits.
        assertTrue(h.hasUnsettledReceivable(LAB));
    }

    // =====================================================================
    //  6. updateAccruedTimestamp — monotonic (max) semantics
    // =====================================================================

    function test_updateAccruedTimestamp_max_semantics() public {
        h.updateAccruedTimestamp(LAB, 100);
        h.updateAccruedTimestamp(LAB, 50); // should NOT decrease

        // Read via lifecycle view to verify
        (,,,,,,, uint256 lastAccrued) = h.getLabProviderReceivableLifecycle(LAB);
        assertEq(lastAccrued, 100);
    }

    // =====================================================================
    //  7. SETTLEMENT_OPERATOR_ROLE grants access
    // =====================================================================

    function test_settlementOperatorRole_allows_transition() public {
        h.setReceivableBucket(LAB, 2, TEN_CREDITS);
        h.grantSettlementOperatorRole(SETTLER);

        vm.prank(SETTLER);
        h.transitionProviderReceivableState(LAB, 2, 3, FIVE_CREDITS, bytes32("inv-001"));

        (
            ,
            uint256 queued,
            uint256 invoiced,
            ,,,,
        ) = h.getLabProviderReceivableLifecycle(LAB);
        assertEq(queued, FIVE_CREDITS);
        assertEq(invoiced, FIVE_CREDITS);
    }

    function test_settlementOperatorRole_unauthorized_blocked() public {
        h.setReceivableBucket(LAB, 2, TEN_CREDITS);

        vm.prank(NOBODY);
        vm.expectRevert("Not authorized");
        h.transitionProviderReceivableState(LAB, 2, 3, ONE_CREDIT, bytes32("bad"));
    }
}
