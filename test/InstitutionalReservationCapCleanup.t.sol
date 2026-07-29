// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.33;

import {Test} from "forge-std/Test.sol";
import {EnumerableSet} from "@openzeppelin/contracts/utils/structs/EnumerableSet.sol";
import {
    InstitutionalReservationRequestValidationFacet
} from "../contracts/facets/reservation/institutional/InstitutionalReservationRequestValidationFacet.sol";
import {
    AppStorage,
    LibAppStorage,
    ProviderNetworkStatus,
    Reservation,
    INSTITUTION_ROLE
} from "../contracts/libraries/LibAppStorage.sol";
import {LibERC721StorageTestHelper} from "./LibERC721StorageTestHelper.sol";
import {LibTracking} from "../contracts/libraries/LibTracking.sol";

contract InstitutionalReservationCapHarness is InstitutionalReservationRequestValidationFacet {
    using EnumerableSet for EnumerableSet.Bytes32Set;
    using EnumerableSet for EnumerableSet.AddressSet;

    uint8 internal constant ACCESS_AUTHORIZED = 2;
    uint8 internal constant SETTLED = 3;

    uint256 public lastRefundAmount;

    function configureLab(
        uint256 labId,
        address owner,
        address institution,
        address backend
    ) external {
        AppStorage storage s = LibAppStorage.diamondStorage();
        s.institutionalBackends[institution] = backend;
        s.roleMembers[INSTITUTION_ROLE].add(institution);
        s.tokenStatus[labId] = true;
        s.providerNetworkStatus[owner] = ProviderNetworkStatus.ACTIVE;
        LibERC721StorageTestHelper.setOwnerForTest(labId, owner);
    }

    function seedReservation(
        bytes32 key,
        uint256 labId,
        address owner,
        address institution,
        address renter,
        bytes32 pucHash,
        uint32 start,
        uint32 end,
        uint8 status
    ) external {
        AppStorage storage s = LibAppStorage.diamondStorage();
        Reservation storage reservation = s.reservations[key];
        reservation.labId = labId;
        reservation.renter = renter;
        reservation.payerInstitution = institution;
        reservation.labProvider = owner;
        reservation.price = 1_000_000;
        reservation.providerShare = 1_000_000;
        reservation.start = start;
        reservation.end = end;
        reservation.status = status;

        s.reservationPucHash[key] = pucHash;
        s.reservationKeysByToken[labId].add(key);
        s.reservationKeysByTokenAndUser[labId][LibTracking.trackingKeyFromInstitutionHash(
                institution, pucHash
            )].add(key);
        s.renters[renter].add(key);
        s.totalReservationsCount++;
        s.labActiveReservationCount[labId]++;
        s.providerActiveReservationCount[owner]++;
        s.activeReservationCountByTokenAndUser[
            labId
        ][LibTracking.trackingKeyFromInstitutionHash(institution, pucHash)]++;
    }

    function markSessionStarted(
        bytes32 key
    ) external {
        LibAppStorage.diamondStorage().reservationSessionStartedRecorded[key] = true;
    }

    function refundToInstitutionalTreasuryForReservation(
        address,
        bytes32,
        bytes32,
        uint256 amount
    ) external {
        lastRefundAmount = amount;
    }

    function reservationStatus(
        bytes32 key
    ) external view returns (uint8) {
        return LibAppStorage.diamondStorage().reservations[key].status;
    }

    function activeReservationCount(
        uint256 labId,
        address trackingKey
    ) external view returns (uint256) {
        return LibAppStorage.diamondStorage().activeReservationCountByTokenAndUser[labId][trackingKey];
    }
}

contract InstitutionalReservationCapCleanupTest is Test {
    uint8 internal constant ACCESS_AUTHORIZED = 2;
    uint8 internal constant SETTLED = 3;

    address internal constant INSTITUTION = address(0xCAFE);
    address internal constant BACKEND = address(0xBEEF);
    address internal constant OWNER = address(0xD00D);
    address internal constant RENTER = address(0xABCD);
    uint256 internal constant LAB_ID = 77;

    InstitutionalReservationCapHarness internal harness;
    bytes32 internal pucHash;
    address internal trackingKey;
    uint32 internal expiredEnd;
    bytes32 internal expiredKey;

    function setUp() public {
        harness = new InstitutionalReservationCapHarness();
        harness.configureLab(LAB_ID, OWNER, INSTITUTION, BACKEND);

        vm.warp(10_000);
        pucHash = keccak256("cap-user");
        trackingKey = LibTracking.trackingKeyFromInstitutionHash(INSTITUTION, pucHash);
        expiredEnd = uint32(block.timestamp - 1 hours);
        expiredKey = keccak256("expired-within-attestation-grace");

        harness.seedReservation(
            expiredKey,
            LAB_ID,
            OWNER,
            INSTITUTION,
            RENTER,
            pucHash,
            uint32(block.timestamp - 2 hours),
            expiredEnd,
            ACCESS_AUTHORIZED
        );

        for (uint256 i; i < 7; i++) {
            // forge-lint: disable-next-line(unsafe-typecast)
            uint32 start = uint32(block.timestamp + 1 days + i * 2 hours);
            harness.seedReservation(
                keccak256(abi.encodePacked("future-cap-reservation", i)),
                LAB_ID,
                OWNER,
                INSTITUTION,
                RENTER,
                pucHash,
                start,
                start + 1 hours,
                ACCESS_AUTHORIZED
            );
        }
    }

    function test_capCleanup_respectsSessionAttestationGrace() public {
        vm.prank(BACKEND);
        harness.validateInstRequest(
            INSTITUTION, pucHash, LAB_ID, uint32(block.timestamp + 10 days), uint32(block.timestamp + 10 days + 1 hours)
        );

        assertEq(harness.reservationStatus(expiredKey), ACCESS_AUTHORIZED);
        assertEq(harness.activeReservationCount(LAB_ID, trackingKey), 8);
        assertEq(harness.lastRefundAmount(), 0);

        vm.warp(uint256(expiredEnd) + 1 days + 1);
        vm.prank(BACKEND);
        harness.validateInstRequest(
            INSTITUTION, pucHash, LAB_ID, uint32(block.timestamp + 10 days), uint32(block.timestamp + 10 days + 1 hours)
        );

        assertEq(harness.reservationStatus(expiredKey), SETTLED);
        assertEq(harness.activeReservationCount(LAB_ID, trackingKey), 7);
        assertEq(harness.lastRefundAmount(), 750_000);
    }
}
