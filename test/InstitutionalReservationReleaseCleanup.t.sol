// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.33;

import "forge-std/Test.sol";
import {EnumerableSet} from "@openzeppelin/contracts/utils/structs/EnumerableSet.sol";
import {AppStorage, LibAppStorage, Reservation, INSTITUTION_ROLE} from "../contracts/libraries/LibAppStorage.sol";
import {LibInstitutionalReservationRelease} from "../contracts/libraries/LibInstitutionalReservationRelease.sol";
import {LibTracking} from "../contracts/libraries/LibTracking.sol";
import {RivalIntervalTreeLibrary, Tree} from "../contracts/libraries/RivalIntervalTreeLibrary.sol";

contract InstitutionalReservationReleaseCleanupHarness {
    using EnumerableSet for EnumerableSet.AddressSet;
    using EnumerableSet for EnumerableSet.Bytes32Set;
    using RivalIntervalTreeLibrary for Tree;

    uint8 internal constant CONFIRMED = 1;

    function seedExpiredReservation(
        bytes32 key,
        address institution,
        address renter,
        uint256 labId,
        uint32 start,
        uint32 end,
        bytes32 pucHash
    ) external {
        AppStorage storage s = LibAppStorage.diamondStorage();
        s.roleMembers[INSTITUTION_ROLE].add(institution);

        Reservation storage reservation = s.reservations[key];
        reservation.renter = renter;
        reservation.payerInstitution = institution;
        reservation.labProvider = institution;
        reservation.labId = labId;
        reservation.start = start;
        reservation.end = end;
        reservation.status = CONFIRMED;
        reservation.price = 100;
        reservation.providerShare = 100;
        s.reservationPucHash[key] = pucHash;

        address trackingIndex = LibTracking.trackingKeyFromInstitutionHash(institution, pucHash);
        s.reservationKeysByToken[labId].add(key);
        s.reservationKeysByTokenAndUser[labId][trackingIndex].add(key);
        s.activeReservationByTokenAndUser[labId][trackingIndex] = key;
        s.activeReservationCountByTokenAndUser[labId][trackingIndex] = 1;
        s.renters[renter].add(key);
        s.renters[trackingIndex].add(key);
        s.calendars[labId].insert(start, end);
        s.labActiveReservationCount[labId] = 1;
        s.providerActiveReservationCount[institution] = 1;
        s.totalReservationsCount = 1;
    }

    function release(
        address institution,
        bytes32 pucHash,
        uint256 labId
    ) external returns (uint256) {
        return
            LibInstitutionalReservationRelease.releaseInstitutionalExpiredReservations(institution, pucHash, labId, 1);
    }

    function refundToInstitutionalTreasuryForReservation(
        address,
        bytes32,
        bytes32,
        uint256
    ) external {}

    function reservationStatus(
        bytes32 key
    ) external view returns (uint8) {
        return LibAppStorage.diamondStorage().reservations[key].status;
    }

    function trackingKey(
        address institution,
        bytes32 pucHash
    ) external pure returns (address) {
        return LibTracking.trackingKeyFromInstitutionHash(institution, pucHash);
    }

    function hasGlobalReservation(
        uint256 labId,
        bytes32 key
    ) external view returns (bool) {
        return LibAppStorage.diamondStorage().reservationKeysByToken[labId].contains(key);
    }

    function hasUserReservation(
        address user,
        bytes32 key
    ) external view returns (bool) {
        return LibAppStorage.diamondStorage().renters[user].contains(key);
    }

    function hasInstitutionalReservation(
        uint256 labId,
        address user,
        bytes32 key
    ) external view returns (bool) {
        return LibAppStorage.diamondStorage().reservationKeysByTokenAndUser[labId][user].contains(key);
    }

    function hasCalendarSlot(
        uint256 labId,
        uint32 start
    ) external view returns (bool) {
        AppStorage storage s = LibAppStorage.diamondStorage();
        return s.calendars[labId].root != 0 && s.calendars[labId].exists(start);
    }
}

contract InstitutionalReservationReleaseCleanupTest is Test {
    uint8 internal constant CONFIRMED = 1;
    uint8 internal constant SETTLED = 3;
    InstitutionalReservationReleaseCleanupHarness internal harness;

    function setUp() public {
        harness = new InstitutionalReservationReleaseCleanupHarness();
    }

    function test_release_cleans_calendar_and_all_user_indexes() public {
        address institution = address(0xCAFE);
        address renter = institution;
        uint256 labId = 42;
        uint32 start = 1000;
        uint32 end = 2000;
        bytes32 pucHash = keccak256("cleanup-user");
        bytes32 key = keccak256("cleanup-reservation");

        harness.seedExpiredReservation(key, institution, renter, labId, start, end, pucHash);
        address trackingIndex = harness.trackingKey(institution, pucHash);

        vm.warp(end + 1);
        assertEq(harness.release(institution, pucHash, labId), 1);

        assertEq(harness.reservationStatus(key), SETTLED);
        assertFalse(harness.hasCalendarSlot(labId, start));
        assertFalse(harness.hasGlobalReservation(labId, key));
        assertFalse(harness.hasUserReservation(renter, key));
        assertFalse(harness.hasUserReservation(trackingIndex, key));
        assertFalse(harness.hasInstitutionalReservation(labId, trackingIndex, key));
    }

    function test_release_does_not_clean_when_reservation_not_expired() public {
        address institution = address(0xCAFE);
        address renter = institution;
        uint256 labId = 42;
        uint32 start = 1000;
        uint32 end = 2000;
        bytes32 pucHash = keccak256("cleanup-user");
        bytes32 key = keccak256("cleanup-reservation-not-expired");

        harness.seedExpiredReservation(key, institution, renter, labId, start, end, pucHash);
        address trackingIndex = harness.trackingKey(institution, pucHash);

        vm.warp(end);
        assertEq(harness.release(institution, pucHash, labId), 0);

        assertEq(harness.reservationStatus(key), CONFIRMED);
        assertTrue(harness.hasCalendarSlot(labId, start));
        assertTrue(harness.hasGlobalReservation(labId, key));
        assertTrue(harness.hasUserReservation(renter, key));
        assertTrue(harness.hasUserReservation(trackingIndex, key));
        assertTrue(harness.hasInstitutionalReservation(labId, trackingIndex, key));
    }
}
