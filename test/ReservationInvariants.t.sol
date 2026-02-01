// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.33;

import "forge-std/Test.sol";
import {ReservationHarness, MockERC20} from "./GasReservations.t.sol";
import "../contracts/libraries/LibAppStorage.sol";
import {EnumerableSet} from "@openzeppelin/contracts/utils/structs/EnumerableSet.sol";
import "../contracts/facets/reservation/institutional/InstitutionalReservationRequestValidationFacet.sol";

// Minimal harness that exposes ownerOf so library calls succeed when executed in-contract
contract InstValidateHarnessLocal is InstitutionalReservationRequestValidationFacet {
    using EnumerableSet for EnumerableSet.Bytes32Set;
    mapping(uint256 => address) public owners;

    function setOwner(
        uint256 tokenId,
        address owner
    ) external {
        owners[tokenId] = owner;
    }

    function ownerOf(
        uint256 tokenId
    ) external view returns (address) {
        return owners[tokenId];
    }

    // Test helpers to mutate this contract's AppStorage
    function setBackend(
        address provider,
        address backend
    ) external {
        AppStorage storage s = LibAppStorage.diamondStorage();
        s.institutionalBackends[provider] = backend;
    }

    function setTokenStatus(
        uint256 tokenId,
        bool status
    ) external {
        AppStorage storage s = LibAppStorage.diamondStorage();
        s.tokenStatus[tokenId] = status;
    }

    // Simple stub to satisfy IReservableTokenCalcV calls during validation
    function calculateRequiredStake(
        address,
        uint256
    ) external pure returns (uint256) {
        return 0;
    }

    // Seed confirmed reservation directly into this contract's storage for testing
    function seedConfirmedReservation(
        address trackingKey,
        uint256 labId,
        uint32 sT,
        uint32 eT
    ) external {
        AppStorage storage s = LibAppStorage.diamondStorage();
        bytes32 k = keccak256(abi.encodePacked(labId, sT));
        Reservation storage r = s.reservations[k];
        r.renter = trackingKey;
        r.labId = labId;
        r.start = sT;
        r.end = eT;
        r.status = 1; // CONFIRMED
        s.reservationKeysByToken[labId].add(k);
        s.reservationKeysByTokenAndUser[labId][trackingKey].add(k);
        s.renters[trackingKey].add(k);
        s.activeReservationCountByTokenAndUser[labId][trackingKey]++;
        s.totalReservationsCount++;
    }

    function getActiveCountFor(
        uint256 labId,
        address trackingKey
    ) external view returns (uint256) {
        AppStorage storage s = LibAppStorage.diamondStorage();
        return s.activeReservationCountByTokenAndUser[labId][trackingKey];
    }

    function getReservationKeysLen(
        uint256 labId,
        address trackingKey
    ) external view returns (uint256) {
        AppStorage storage s = LibAppStorage.diamondStorage();
        return s.reservationKeysByTokenAndUser[labId][trackingKey].length();
    }

    function containsReservation(
        uint256 labId,
        address trackingKey,
        bytes32 key
    ) external view returns (bool) {
        AppStorage storage s = LibAppStorage.diamondStorage();
        return s.reservationKeysByTokenAndUser[labId][trackingKey].contains(key);
    }
}

contract ReservationInvariantsTest is Test {
    using EnumerableSet for EnumerableSet.Bytes32Set;

    ReservationHarness harness;
    MockERC20 token;
    address renter = address(0xBEEF);
    uint256 labId;

    function setUp() public {
        token = new MockERC20();
        harness = new ReservationHarness();
        harness.initializeHarness(address(token));
        labId = harness.mintAndList(1e6);

        // prepare funds
        token.mint(renter, 10 ether);
        vm.prank(renter);
        token.approve(address(harness), type(uint256).max);
    }

    function _key(
        uint32 start
    ) internal view returns (bytes32) {
        return keccak256(abi.encodePacked(labId, start));
    }

    function test_confirm_increments_counts_and_keys() public {
        uint32 start = uint32(block.timestamp + 1000);
        uint32 end = start + 500;

        vm.prank(renter);
        harness.reservationRequest(labId, start, end);

        bytes32 key = _key(start);

        // confirm
        vm.prank(address(this));
        harness.confirmReservationRequest(key);

        assertEq(harness.getActiveCount(labId, renter), 1);
        assertEq(harness.getReservationKeysByTokenAndUserLength(labId, renter), 1);
        assertEq(harness.getReservationKeysByTokenLength(labId), 1);
    }

    function test_cancel_decrements_counts_and_removes_key() public {
        uint32 start = uint32(block.timestamp + 2000);
        uint32 end = start + 500;

        vm.prank(renter);
        harness.reservationRequest(labId, start, end);
        bytes32 key = _key(start);

        vm.prank(address(this));
        harness.confirmReservationRequest(key);

        // renter cancels booking
        vm.prank(renter);
        harness.cancelBooking(key);

        assertEq(harness.getActiveCount(labId, renter), 0);
        assertEq(harness.getReservationKeysByTokenAndUserLength(labId, renter), 0);
    }

    function test_double_confirm_reverts() public {
        uint32 start = uint32(block.timestamp + 3000);
        uint32 end = start + 500;

        vm.prank(renter);
        harness.reservationRequest(labId, start, end);
        bytes32 key = _key(start);

        vm.prank(address(this));
        harness.confirmReservationRequest(key);

        vm.expectRevert();
        vm.prank(address(this));
        harness.confirmReservationRequest(key);
    }

    function test_activeReservation_by_token_and_user_updates_to_earliest() public {
        uint32 sEarly = uint32(block.timestamp + 5000);
        uint32 eEarly = sEarly + 100;
        uint32 sLate = uint32(block.timestamp + 7000);
        uint32 eLate = sLate + 100;

        // create late and early
        vm.prank(renter);
        harness.reservationRequest(labId, sLate, eLate);
        bytes32 kLate = _key(sLate);

        vm.prank(renter);
        harness.reservationRequest(labId, sEarly, eEarly);
        bytes32 kEarly = _key(sEarly);

        // confirm late first
        vm.prank(address(this));
        harness.confirmReservationRequest(kLate);
        bytes32 active1 = harness.getActiveReservationKey(labId, renter);
        assertEq(active1, kLate);

        // confirm early; active should switch to early
        vm.prank(address(this));
        harness.confirmReservationRequest(kEarly);
        bytes32 active2 = harness.getActiveReservationKey(labId, renter);
        assertEq(active2, kEarly);
    }

    function test_confirm_reverts_when_active_count_is_huge(
        uint8 big
    ) public {
        vm.assume(big > 200); // bias toward a value that would overflow on increment, if allowed
        // set extreme active count directly in harness storage
        vm.prank(address(this));
        harness.setActiveCount(labId, renter, big);

        // reservation request itself should be blocked when active count is already huge
        vm.prank(renter);
        uint32 start = uint32(block.timestamp + 9000);
        uint32 end = start + 100;
        vm.expectRevert();
        harness.reservationRequest(labId, start, end);
    }

    function test_deny_does_not_increment_counts_or_keys() public {
        uint32 start = uint32(block.timestamp + 11_000);
        uint32 end = start + 100;

        vm.prank(renter);
        harness.reservationRequest(labId, start, end);
        bytes32 key = _key(start);

        // provider denies
        vm.prank(address(this));
        harness.denyReservationRequest(key);

        assertEq(harness.getActiveCount(labId, renter), 0);
        assertEq(harness.getReservationKeysByTokenAndUserLength(labId, renter), 0);
    }

    function test_auto_release_removes_expired_keys_and_decrements() public {
        // create a mix of expired and non-expired reservations to trigger the auto-release path
        uint8 expiredCount = 3;
        uint8 nonExpiredCount = 7; // total 10 -> will trigger release logic in request

        uint32 startBase = uint32(block.timestamp + 1000);
        bytes32 firstExpiredKey;
        bytes32 remainingKey;

        for (uint256 i = 0; i < expiredCount; ++i) {
            uint32 sT = startBase + uint32(i * 1000);
            uint32 eT = sT + 10; // very short; will expire after warp
            vm.prank(renter);
            harness.reservationRequest(labId, sT, eT);
            bytes32 k = _key(sT);
            vm.prank(address(this));
            harness.confirmReservationRequest(k);
            if (i == 0) firstExpiredKey = k;
        }

        // create non-expired far-future reservations
        for (uint256 i = 0; i < nonExpiredCount; ++i) {
            uint32 sT = startBase + uint32(100_000 + i * 1000);
            uint32 eT = sT + 1000;
            vm.prank(renter);
            harness.reservationRequest(labId, sT, eT);
            bytes32 k = _key(sT);
            vm.prank(address(this));
            harness.confirmReservationRequest(k);
            if (i == 0) remainingKey = k;
        }

        // Sanity: we have total 10 active entries
        assertEq(harness.getActiveCount(labId, renter), 10);
        assertEq(harness.getReservationKeysByTokenAndUserLength(labId, renter), 10);

        // warp past expired windows
        vm.warp(block.timestamp + 20_000);

        // a new request should trigger auto-release and succeed
        vm.prank(renter);
        token.mint(renter, 1 ether);
        vm.prank(renter);
        token.approve(address(harness), type(uint256).max);

        uint32 newStart = uint32(block.timestamp + 3600);
        vm.prank(renter);
        harness.reservationRequest(labId, newStart, newStart + 100);

        // After auto-release, active count and per-user set length must have decreased
        assertTrue(harness.getActiveCount(labId, renter) < 10);
        assertTrue(harness.getReservationKeysByTokenAndUserLength(labId, renter) < 10);

        // The expired key must no longer be present, the remaining non-expired key must still exist
        assertFalse(harness.reservationKeyExists(labId, renter, firstExpiredKey));
        assertTrue(harness.reservationKeyExists(labId, renter, remainingKey));
    }

    function test_institutional_auto_release_removes_expired_keys_and_decrements() public {
        // setup
        address provider = address(0xCAFE);
        string memory userId = "inst-user-1";
        InstValidateHarnessLocal inst = new InstValidateHarnessLocal();
        inst.setOwner(labId, address(this));

        // set token status and backend in the inst contract's storage
        inst.setTokenStatus(labId, true);
        inst.setBackend(provider, address(this));

        // compute tracking key (same as LibTracking)
        bytes32 pucHash = keccak256(bytes(userId));
        address trackingKey = address(uint160(uint256(keccak256(abi.encodePacked(provider, pucHash)))));

        // create expired and non-expired confirmed reservations under trackingKey via inst
        uint8 expiredCount = 3;
        uint8 nonExpiredCount = 7; // total 10
        uint32 startBase = uint32(block.timestamp + 1000);
        bytes32 firstExpiredKey;
        bytes32 remainingKey;

        for (uint256 i = 0; i < expiredCount; ++i) {
            uint32 sT = startBase + uint32(i * 1000);
            uint32 eT = sT + 10;
            bytes32 k = keccak256(abi.encodePacked(labId, sT));
            inst.seedConfirmedReservation(trackingKey, labId, sT, eT);
            if (i == 0) firstExpiredKey = k;
        }

        for (uint256 i = 0; i < nonExpiredCount; ++i) {
            uint32 sT = startBase + uint32(100_000 + i * 1000);
            uint32 eT = sT + 1000;
            bytes32 k = keccak256(abi.encodePacked(labId, sT));
            inst.seedConfirmedReservation(trackingKey, labId, sT, eT);
            if (i == 0) remainingKey = k;
        }

        // Sanity
        assertEq(inst.getActiveCountFor(labId, trackingKey), 10);
        assertEq(inst.getReservationKeysLen(labId, trackingKey), 10);

        // warp past expired
        vm.warp(block.timestamp + 20_000);

        // call validateInstRequest (msg.sender == this is authorized because we set in institutionalBackends)
        uint32 newStart = uint32(block.timestamp + 3600);
        (address owner, bytes32 key, address tk) =
            inst.validateInstRequest(provider, userId, labId, newStart, newStart + 100);

        // After auto-release, active count and per-user set length must have decreased
        assertTrue(inst.getActiveCountFor(labId, trackingKey) < 10);
        assertTrue(inst.getReservationKeysLen(labId, trackingKey) < 10);

        // Expired key must have been removed, non-expired should remain
        assertFalse(inst.containsReservation(labId, trackingKey, firstExpiredKey));
        assertTrue(inst.containsReservation(labId, trackingKey, remainingKey));
    }
}
