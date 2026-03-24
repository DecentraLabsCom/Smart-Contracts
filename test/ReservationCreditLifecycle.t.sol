// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.33;

import "forge-std/Test.sol";
import {WalletReservationCoreFacet} from "../contracts/facets/reservation/wallet/WalletReservationCoreFacet.sol";
import {WalletReservationReleaseFacet} from "../contracts/facets/reservation/wallet/WalletReservationReleaseFacet.sol";
import {
    WalletReservationConfirmationFacet
} from "../contracts/facets/reservation/wallet/WalletReservationConfirmationFacet.sol";
import {LibWalletReservationCancellation} from "../contracts/libraries/LibWalletReservationCancellation.sol";
import {AppStorage, LabBase, LibAppStorage, Reservation, ProviderNetworkStatus} from "../contracts/libraries/LibAppStorage.sol";
import {LibWalletReservationConfirmation} from "../contracts/libraries/LibWalletReservationConfirmation.sol";
import {ReservableTokenEnumerable} from "../contracts/abstracts/ReservableTokenEnumerable.sol";
import {LibAccessControlEnumerable} from "../contracts/libraries/LibAccessControlEnumerable.sol";
import {EnumerableSet} from "@openzeppelin/contracts/utils/structs/EnumerableSet.sol";
import {ERC721} from "@openzeppelin/contracts/token/ERC721/ERC721.sol";
import {ERC721Enumerable} from "@openzeppelin/contracts/token/ERC721/extensions/ERC721Enumerable.sol";

/// @dev Harness combining ERC721, reservation, confirmation, cancellation, and release
contract CreditLifecycleHarness is
    ERC721Enumerable,
    WalletReservationCoreFacet,
    WalletReservationReleaseFacet
{
    using LibAccessControlEnumerable for AppStorage;
    using EnumerableSet for EnumerableSet.Bytes32Set;

    constructor() ERC721("Labs", "LAB") {}

    function initializeHarness() external {
        AppStorage storage s = LibAppStorage.diamondStorage();
        s.labTokenAddress = address(0);
        s.DEFAULT_ADMIN_ROLE = keccak256("DEFAULT_ADMIN_ROLE");
        s._addProviderRole(msg.sender, "provider", "provider@example.com", "ES", "");
        s.providerStakes[msg.sender].stakedAmount = type(uint256).max;
        s.providerNetworkStatus[msg.sender] = ProviderNetworkStatus.ACTIVE;
    }

    function setServiceCreditBalance(address account, uint256 amount) external {
        AppStorage storage s = LibAppStorage.diamondStorage();
        s.serviceCreditBalance[account] = amount;
    }

    function getServiceCreditBalance(address account) external view returns (uint256) {
        AppStorage storage s = LibAppStorage.diamondStorage();
        return s.serviceCreditBalance[account];
    }

    function getCreditLockedBalance(address account) external view returns (uint256) {
        AppStorage storage s = LibAppStorage.diamondStorage();
        return s.creditLockedBalance[account];
    }

    function getProviderReceivableAccrued(uint256 labId) external view returns (uint256) {
        AppStorage storage s = LibAppStorage.diamondStorage();
        return s.providerReceivableAccrued[labId];
    }

    function getPendingProjectTreasury() external view returns (uint256) {
        AppStorage storage s = LibAppStorage.diamondStorage();
        return s.pendingProjectTreasury;
    }

    function getPendingSubsidies() external view returns (uint256) {
        AppStorage storage s = LibAppStorage.diamondStorage();
        return s.pendingSubsidies;
    }

    function getPendingGovernance() external view returns (uint256) {
        AppStorage storage s = LibAppStorage.diamondStorage();
        return s.pendingGovernance;
    }

    function getReservationStatus(bytes32 key) external view returns (uint8) {
        AppStorage storage s = LibAppStorage.diamondStorage();
        return s.reservations[key].status;
    }

    function mintAndList(uint96 price) external returns (uint256 id) {
        AppStorage storage s = LibAppStorage.diamondStorage();
        id = s.labId + 1;
        _mint(msg.sender, id);
        s.labId = id;
        s.labs[id] = LabBase({
            uri: "uri",
            price: price,
            accessURI: "accessURI",
            accessKey: "accessKey",
            createdAt: uint32(block.timestamp),
            resourceType: 0
        });
        s.providerStakes[msg.sender].listedLabsCount += 1;
        s.tokenStatus[id] = true;
    }

    function updateLastReservation(address) external {}

    function confirmReservationRequest(
        bytes32 _reservationKey
    ) public override(ReservableTokenEnumerable) {
        LibWalletReservationConfirmation.confirmReservationRequest(_reservationKey);
    }

    function cancelBooking(
        bytes32 _reservationKey
    ) external override(ReservableTokenEnumerable) {
        LibWalletReservationCancellation.cancelBooking(_reservationKey);
    }

    function supportsInterface(
        bytes4 interfaceId
    ) public view override(ERC721Enumerable) returns (bool) {
        return super.supportsInterface(interfaceId);
    }
}

/// @title Reservation Credit Lifecycle Tests (MiCA 8.3.C)
/// @notice Verifies the lock/capture/release credit model across the reservation lifecycle
contract ReservationCreditLifecycleTest is Test {
    CreditLifecycleHarness harness;
    address provider;
    address renter = address(0xBEEF);
    uint256 labId;
    uint96 price = 100; // price per second

    uint8 constant _PENDING = 0;
    uint8 constant _CONFIRMED = 1;
    uint8 constant _SETTLED = 4;
    uint8 constant _CANCELLED = 5;

    function setUp() public {
        provider = address(this);
        harness = new CreditLifecycleHarness();
        harness.initializeHarness();
        labId = harness.mintAndList(price);
        harness.setServiceCreditBalance(renter, 10 ether);
    }

    function _key(uint32 start) internal view returns (bytes32) {
        return keccak256(abi.encodePacked(labId, start));
    }

    // ═══════════════════════════════════════════════════════════════════════
    //  Request → Confirm: credits locked (not debited)
    // ═══════════════════════════════════════════════════════════════════════

    function test_request_does_not_lock_credits() public {
        uint32 start = uint32(block.timestamp + 1000);
        uint32 end = start + 1000;

        vm.prank(renter);
        harness.reservationRequest(labId, start, end);

        // Credits NOT locked at request stage
        assertEq(harness.getCreditLockedBalance(renter), 0);
        assertEq(harness.getServiceCreditBalance(renter), 10 ether);
    }

    function test_confirm_locks_credits_not_debits() public {
        uint32 start = uint32(block.timestamp + 1000);
        uint32 end = start + 1000; // duration = 1000s
        uint256 totalPrice = uint256(price) * 1000; // 100 * 1000 = 100,000

        vm.prank(renter);
        harness.reservationRequest(labId, start, end);

        bytes32 key = _key(start);

        vm.prank(provider);
        harness.confirmReservationRequest(key);

        // Credits locked, not debited
        assertEq(harness.getCreditLockedBalance(renter), totalPrice);
        // Total balance unchanged (locked credits are still in total)
        assertEq(harness.getServiceCreditBalance(renter), 10 ether);
        // Available = total - locked
        uint256 available = harness.getServiceCreditBalance(renter) - harness.getCreditLockedBalance(renter);
        assertEq(available, 10 ether - totalPrice);
    }

    function test_confirm_reverts_when_insufficient_available() public {
        uint32 start = uint32(block.timestamp + 1000);
        uint32 end = start + 1000;

        // Set balance too low for the reservation
        harness.setServiceCreditBalance(renter, 10); // way less than 100,000

        vm.prank(renter);
        // Request itself checks available balance — should revert
        vm.expectRevert();
        harness.reservationRequest(labId, start, end);
    }

    // ═══════════════════════════════════════════════════════════════════════
    //  Cancel pending: no credit change
    // ═══════════════════════════════════════════════════════════════════════

    function test_cancel_pending_no_credit_change() public {
        uint32 start = uint32(block.timestamp + 1000);
        uint32 end = start + 1000;

        vm.prank(renter);
        harness.reservationRequest(labId, start, end);

        bytes32 key = _key(start);

        vm.prank(renter);
        harness.cancelReservationRequest(key);

        assertEq(harness.getCreditLockedBalance(renter), 0);
        assertEq(harness.getServiceCreditBalance(renter), 10 ether);
    }

    // ═══════════════════════════════════════════════════════════════════════
    //  Cancel confirmed: capture fee + release refund
    // ═══════════════════════════════════════════════════════════════════════

    function test_cancel_confirmed_captures_fee_releases_refund() public {
        uint32 start = uint32(block.timestamp + 1000);
        uint32 end = start + 1000;
        uint256 totalPrice = uint256(price) * 1000;

        vm.prank(renter);
        harness.reservationRequest(labId, start, end);

        bytes32 key = _key(start);
        vm.prank(provider);
        harness.confirmReservationRequest(key);

        // Before cancel: locked = totalPrice, total = 10 ether
        assertEq(harness.getCreditLockedBalance(renter), totalPrice);

        vm.prank(renter);
        harness.cancelBooking(key);

        // After cancel: locked should be 0 (fee captured + refund released)
        assertEq(harness.getCreditLockedBalance(renter), 0);
        // Fee = max(3% of price, MIN_CANCELLATION_FEE=10,000)
        // 3% of 100,000 = 3,000 < 10,000 → fee = 10,000
        uint256 expectedFee = 10_000; // MIN_CANCELLATION_FEE applies
        uint256 expectedBalance = 10 ether - expectedFee;
        assertEq(harness.getServiceCreditBalance(renter), expectedBalance);
        assertEq(harness.getReservationStatus(key), _CANCELLED);
    }

    // ═══════════════════════════════════════════════════════════════════════
    //  Release expired: capture + credit revenue buckets
    // ═══════════════════════════════════════════════════════════════════════

    function test_release_expired_captures_and_credits_revenue() public {
        uint32 start = uint32(block.timestamp + 1000);
        uint32 end = start + 1000;
        uint256 totalPrice = uint256(price) * 1000;

        vm.prank(renter);
        harness.reservationRequest(labId, start, end);

        bytes32 key = _key(start);
        vm.prank(provider);
        harness.confirmReservationRequest(key);

        // Warp past the reservation end
        vm.warp(end + 1);

        vm.prank(renter);
        harness.releaseExpiredReservations(labId, renter, 10);

        // Credits should be fully captured (no longer locked)
        assertEq(harness.getCreditLockedBalance(renter), 0);
        // Total balance reduced by totalPrice (captured)
        assertEq(harness.getServiceCreditBalance(renter), 10 ether - totalPrice);
        // Status should be _SETTLED (4)
        assertEq(harness.getReservationStatus(key), _SETTLED);
        // Revenue should be credited to provider receivable
        assertTrue(harness.getProviderReceivableAccrued(labId) > 0);
    }

    // ═══════════════════════════════════════════════════════════════════════
    //  Auto-release on new request: captures locked credits
    // ═══════════════════════════════════════════════════════════════════════

    function test_auto_release_on_new_request_captures_credits() public {
        // Fill up to near-limit with expired reservations
        uint32 start = uint32(block.timestamp + 1000);
        uint256 totalPrice = uint256(price) * 100; // each reservation: 100 * 100 = 10,000

        for (uint256 i; i < 9; ++i) {
            uint32 s = start + uint32(i * 200);
            uint32 e = s + 100;
            harness.setServiceCreditBalance(renter, 10 ether);
            vm.prank(renter);
            harness.reservationRequest(labId, s, e);
            vm.prank(provider);
            harness.confirmReservationRequest(_key(s));
        }

        // All 9 reservations have locked credits
        assertEq(harness.getCreditLockedBalance(renter), totalPrice * 9);

        // Warp past all end times
        vm.warp(block.timestamp + 1_000_000);

        // New reservation triggers auto-release
        harness.setServiceCreditBalance(renter, 10 ether);
        uint32 newStart = uint32(block.timestamp + 3600);
        vm.prank(renter);
        harness.reservationRequest(labId, newStart, newStart + 100);

        // Expired reservations should have been finalized (credits captured)
        // Locked balance should be 0 from expired + 10,000 from new pending (not yet confirmed)
        // Actually: new reservation is only PENDING, so no lock for it yet
        // All expired were captured, so locked should be 0
        assertEq(harness.getCreditLockedBalance(renter), 0);
    }

    // ═══════════════════════════════════════════════════════════════════════
    //  Multiple reservations: independent locks
    // ═══════════════════════════════════════════════════════════════════════

    function test_multiple_reservations_independent_locks() public {
        uint32 start1 = uint32(block.timestamp + 1000);
        uint32 end1 = start1 + 500;
        uint32 start2 = uint32(block.timestamp + 2000);
        uint32 end2 = start2 + 500;
        uint256 totalPrice1 = uint256(price) * 500;
        uint256 totalPrice2 = uint256(price) * 500;

        // Request + confirm two reservations
        vm.prank(renter);
        harness.reservationRequest(labId, start1, end1);
        vm.prank(provider);
        harness.confirmReservationRequest(_key(start1));

        vm.prank(renter);
        harness.reservationRequest(labId, start2, end2);
        vm.prank(provider);
        harness.confirmReservationRequest(_key(start2));

        // Both locked
        assertEq(harness.getCreditLockedBalance(renter), totalPrice1 + totalPrice2);

        // Cancel first, release remains locked for second
        vm.prank(renter);
        harness.cancelBooking(_key(start1));

        // Fee = max(3% of 50,000 = 1,500, MIN=10,000) → 10,000
        uint256 feeAmount = 10_000;
        // Only second reservation remains locked
        assertEq(harness.getCreditLockedBalance(renter), totalPrice2);
        // First reservation fee captured
        assertEq(harness.getServiceCreditBalance(renter), 10 ether - feeAmount);
    }

    // ═══════════════════════════════════════════════════════════════════════
    //  Full lifecycle: request → confirm → complete → settle
    // ═══════════════════════════════════════════════════════════════════════

    function test_full_lifecycle_request_confirm_settle() public {
        uint32 start = uint32(block.timestamp + 1000);
        uint32 end = start + 3600; // 1 hour
        uint256 totalPrice = uint256(price) * 3600;
        uint256 initialBalance = 10 ether;

        // 1. Request
        vm.prank(renter);
        harness.reservationRequest(labId, start, end);
        assertEq(harness.getReservationStatus(_key(start)), _PENDING);
        assertEq(harness.getCreditLockedBalance(renter), 0);

        // 2. Confirm (locks credits)
        vm.prank(provider);
        harness.confirmReservationRequest(_key(start));
        assertEq(harness.getReservationStatus(_key(start)), _CONFIRMED);
        assertEq(harness.getCreditLockedBalance(renter), totalPrice);

        // 3. Time passes (reservation completes)
        vm.warp(end + 1);

        // 4. Release (captures credits, credits revenue)
        vm.prank(renter);
        harness.releaseExpiredReservations(labId, renter, 10);

        assertEq(harness.getReservationStatus(_key(start)), _SETTLED);
        assertEq(harness.getCreditLockedBalance(renter), 0);
        assertEq(harness.getServiceCreditBalance(renter), initialBalance - totalPrice);

        // Revenue properly allocated (70% provider, 15% treasury, 10% subsidies, 5% governance)
        uint256 providerRevenue = harness.getProviderReceivableAccrued(labId);
        uint256 treasuryRevenue = harness.getPendingProjectTreasury();
        uint256 subsidiesRevenue = harness.getPendingSubsidies();
        uint256 governanceRevenue = harness.getPendingGovernance();
        assertEq(providerRevenue + treasuryRevenue + subsidiesRevenue + governanceRevenue, totalPrice);
    }
}
