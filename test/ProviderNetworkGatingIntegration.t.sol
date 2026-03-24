// SPDX-License-Identifier: MIT
pragma solidity ^0.8.33;

import {Test} from "forge-std/Test.sol";
import {EnumerableSet} from "@openzeppelin/contracts/utils/structs/EnumerableSet.sol";
import {WalletReservationConfirmationFacet} from
    "../contracts/facets/reservation/wallet/WalletReservationConfirmationFacet.sol";
import {AppStorage, LibAppStorage, Reservation, ProviderNetworkStatus} from "../contracts/libraries/LibAppStorage.sol";
import {LibReservationDenyReason} from "../contracts/libraries/LibReservationDenyReason.sol";

/// @title Integration tests: provider-network gating blocks confirmation for non-ACTIVE providers
contract NetworkGatingHarness is WalletReservationConfirmationFacet {
    using EnumerableSet for EnumerableSet.Bytes32Set;
    using EnumerableSet for EnumerableSet.AddressSet;

    mapping(uint256 => address) public owners;

    function setOwner(uint256 tokenId, address owner_) external {
        owners[tokenId] = owner_;
    }

    function ownerOf(uint256 tokenId) external view returns (address) {
        return owners[tokenId];
    }

    // --- Storage helpers ---

    function seedPendingReservation(
        bytes32 key,
        address renter,
        uint96 price,
        uint256 labId,
        uint32 start
    ) external {
        AppStorage storage s = LibAppStorage.diamondStorage();
        Reservation storage r = s.reservations[key];
        r.renter = renter;
        r.price = price;
        r.status = 0; // _PENDING
        r.labId = labId;
        r.start = start;
        r.end = start + 3600;
        s.reservationKeysByToken[labId].add(key);
        s.renters[renter].add(key);
    }

    function setTokenStatus(uint256 labId, bool status) external {
        AppStorage storage s = LibAppStorage.diamondStorage();
        s.tokenStatus[labId] = status;
    }

    function setProviderNetworkStatus(address provider_, ProviderNetworkStatus status) external {
        AppStorage storage s = LibAppStorage.diamondStorage();
        s.providerNetworkStatus[provider_] = status;
    }

    function setServiceCreditBalance(address account, uint256 amount) external {
        AppStorage storage s = LibAppStorage.diamondStorage();
        s.serviceCreditBalance[account] = amount;
    }

    function setCreditAvailableBalance(address account, uint256 amount) external {
        AppStorage storage s = LibAppStorage.diamondStorage();
        s.serviceCreditBalance[account] = amount;
    }

    function getReservationStatus(bytes32 key) external view returns (uint8) {
        AppStorage storage s = LibAppStorage.diamondStorage();
        return s.reservations[key].status;
    }

    // --- Stub for calculateRequiredStake (called via IReservableTokenCalcW) ---

    function calculateRequiredStake(address, uint256) external pure returns (uint256) {
        return 0; // returns 0 so stake check always passes
    }

    // --- Stub for updateLastReservation (called on successful confirm) ---

    function updateLastReservation(address) external {}
}

contract ProviderNetworkGatingIntegrationTest is Test {
    NetworkGatingHarness internal h;

    address internal constant PROVIDER = address(0xABCD);
    address internal constant USER = address(0x1234);
    uint256 internal constant LAB_ID = 42;
    uint32 internal constant START = 100_000;

    event ReservationRequestDenied(bytes32 indexed reservationKey, uint256 indexed tokenId, uint8 reason);
    event ReservationConfirmed(bytes32 indexed reservationKey, uint256 indexed tokenId);

    function setUp() public {
        h = new NetworkGatingHarness();
        h.setOwner(LAB_ID, PROVIDER);
        h.setTokenStatus(LAB_ID, true);
    }

    function _makeKey() internal pure returns (bytes32) {
        return keccak256(abi.encodePacked(LAB_ID, START));
    }

    // =====================================================================
    //  1. ACTIVE provider — confirmation succeeds
    // =====================================================================

    function test_active_provider_confirms_successfully() public {
        bytes32 key = _makeKey();
        h.setProviderNetworkStatus(PROVIDER, ProviderNetworkStatus.ACTIVE);
        h.seedPendingReservation(key, USER, 1000, LAB_ID, START);
        h.setServiceCreditBalance(USER, 10_000);

        vm.expectEmit(true, true, false, true);
        emit ReservationConfirmed(key, LAB_ID);

        vm.prank(PROVIDER);
        h.confirmReservationRequest(key);

        // status 1 = _CONFIRMED
        assertEq(h.getReservationStatus(key), 1);
    }

    // =====================================================================
    //  2. SUSPENDED provider — confirmation denied
    // =====================================================================

    function test_suspended_provider_denied() public {
        bytes32 key = _makeKey();
        h.setProviderNetworkStatus(PROVIDER, ProviderNetworkStatus.SUSPENDED);
        h.seedPendingReservation(key, USER, 1000, LAB_ID, START);
        h.setServiceCreditBalance(USER, 10_000);

        vm.expectEmit(true, true, false, true);
        emit ReservationRequestDenied(key, LAB_ID, LibReservationDenyReason.PROVIDER_NOT_ELIGIBLE);

        vm.prank(PROVIDER);
        h.confirmReservationRequest(key);

        // status 5 = _CANCELLED
        assertEq(h.getReservationStatus(key), 5);
    }

    // =====================================================================
    //  3. TERMINATED provider — confirmation denied
    // =====================================================================

    function test_terminated_provider_denied() public {
        bytes32 key = _makeKey();
        h.setProviderNetworkStatus(PROVIDER, ProviderNetworkStatus.TERMINATED);
        h.seedPendingReservation(key, USER, 1000, LAB_ID, START);
        h.setServiceCreditBalance(USER, 10_000);

        vm.expectEmit(true, true, false, true);
        emit ReservationRequestDenied(key, LAB_ID, LibReservationDenyReason.PROVIDER_NOT_ELIGIBLE);

        vm.prank(PROVIDER);
        h.confirmReservationRequest(key);

        assertEq(h.getReservationStatus(key), 5);
    }

    // =====================================================================
    //  4. NONE (unregistered) provider — confirmation denied
    // =====================================================================

    function test_none_status_provider_denied() public {
        bytes32 key = _makeKey();
        // NONE is default — don't set any network status
        h.seedPendingReservation(key, USER, 1000, LAB_ID, START);
        h.setServiceCreditBalance(USER, 10_000);

        vm.expectEmit(true, true, false, true);
        emit ReservationRequestDenied(key, LAB_ID, LibReservationDenyReason.PROVIDER_NOT_ELIGIBLE);

        vm.prank(PROVIDER);
        h.confirmReservationRequest(key);

        assertEq(h.getReservationStatus(key), 5);
    }

    // =====================================================================
    //  5. Reactivated provider can confirm after suspension
    // =====================================================================

    function test_reactivated_provider_can_confirm() public {
        bytes32 key = _makeKey();
        h.setProviderNetworkStatus(PROVIDER, ProviderNetworkStatus.SUSPENDED);
        // Reactivate
        h.setProviderNetworkStatus(PROVIDER, ProviderNetworkStatus.ACTIVE);
        h.seedPendingReservation(key, USER, 1000, LAB_ID, START);
        h.setServiceCreditBalance(USER, 10_000);

        vm.expectEmit(true, true, false, true);
        emit ReservationConfirmed(key, LAB_ID);

        vm.prank(PROVIDER);
        h.confirmReservationRequest(key);

        assertEq(h.getReservationStatus(key), 1);
    }
}
