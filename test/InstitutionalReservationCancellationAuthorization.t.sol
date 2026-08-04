// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.33;

import "forge-std/Test.sol";
import "../contracts/facets/reservation/institutional/InstitutionalReservationCancellationFacet.sol";
import {AppStorage, INSTITUTION_ROLE, LibAppStorage} from "../contracts/libraries/LibAppStorage.sol";
import {LibInstitutionalReservation} from "../contracts/libraries/LibInstitutionalReservation.sol";
import {UnknownInstitution} from "../contracts/libraries/LibInstitutionalOrg.sol";
import {EnumerableSet} from "@openzeppelin/contracts/utils/structs/EnumerableSet.sol";
import {InstReservationHarness} from "./Harnesses.sol";

contract InstitutionalReservationCancellationAuthorizationHarness is InstitutionalReservationCancellationFacet {
    using EnumerableSet for EnumerableSet.AddressSet;

    function setInstitution(
        address institution
    ) external {
        AppStorage storage s = LibAppStorage.diamondStorage();
        s.roleMembers[INSTITUTION_ROLE].add(institution);
    }

    function setBackend(
        address institution,
        address backend
    ) external {
        LibAppStorage.diamondStorage().institutionalBackends[institution] = backend;
    }

    function authorizeInstitutionalBackend(
        address institution
    ) external view {
        _onlyInstitutionalBackend(institution);
    }
}

contract InstitutionalReservationCancellationAuthorizationTest is Test {
    InstitutionalReservationCancellationAuthorizationHarness internal harness;
    InstReservationHarness internal routeHarness;

    address internal institution = address(0xCAFE);
    address internal backend = address(0xBEEF);

    function setUp() public {
        harness = new InstitutionalReservationCancellationAuthorizationHarness();
        routeHarness = new InstReservationHarness();
        harness.setInstitution(institution);
        harness.setBackend(institution, backend);
    }

    function test_directCancellation_rejectsInstitutionWallet() public {
        vm.prank(institution);
        vm.expectRevert(LibInstitutionalReservation.UnauthorizedInstitution.selector);
        harness.authorizeInstitutionalBackend(institution);
    }

    function test_directCancellation_rejectsMissingBackend() public {
        address institutionWithoutBackend = address(0xD00D);
        harness.setInstitution(institutionWithoutBackend);

        vm.expectRevert(LibInstitutionalReservation.BackendMissing.selector);
        harness.authorizeInstitutionalBackend(institutionWithoutBackend);
    }

    function test_directCancellation_rejectsUnknownInstitutionWithCustomError() public {
        address unknownInstitution = address(0xD00D);

        vm.expectRevert(UnknownInstitution.selector);
        harness.authorizeInstitutionalBackend(unknownInstitution);
    }

    function test_directCancellation_acceptsRegisteredBackend() public {
        vm.prank(backend);
        harness.authorizeInstitutionalBackend(institution);
    }

    function test_directCancellation_pendingRequest_remainsBackendUsable() public {
        uint256 labId = 42;
        uint32 start = uint32(block.timestamp + 1 hours);
        bytes32 reservationKey = keccak256("direct-pending-cancellation");
        bytes32 pucHash = keccak256(bytes("user@institution.example"));

        routeHarness.setInstitution(institution);
        routeHarness.setBackend(institution, backend);
        routeHarness.setReservation(
            reservationKey, address(0x1234), institution, 0, 0, labId, start, "user@institution.example"
        );

        vm.prank(backend);
        routeHarness.cancelInstitutionalReservationRequest(institution, pucHash, reservationKey);

        assertEq(routeHarness.getReservationStatus(reservationKey), 4);
    }

    function test_directCancellation_confirmedBooking_remainsBackendUsable() public {
        uint256 labId = 43;
        uint32 start = uint32(block.timestamp + 1 hours);
        bytes32 reservationKey = keccak256("direct-booking-cancellation");
        bytes32 pucHash = keccak256(bytes("booking@institution.example"));

        routeHarness.setInstitution(institution);
        routeHarness.setBackend(institution, backend);
        routeHarness.setReservation(
            reservationKey, address(0x1234), institution, 0, 1, labId, start, "booking@institution.example"
        );

        vm.prank(backend);
        routeHarness.cancelInstitutionalBookingWithPucHash(institution, reservationKey, pucHash);

        assertEq(routeHarness.getReservationStatus(reservationKey), 4);
    }
}
