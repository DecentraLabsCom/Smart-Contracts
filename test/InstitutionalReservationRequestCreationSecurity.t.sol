// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.33;

import {Test} from "forge-std/Test.sol";
import {
    InstitutionalReservationRequestCreationFacet
} from "../contracts/facets/reservation/institutional/InstitutionalReservationRequestCreationFacet.sol";
import {AppStorage, LibAppStorage} from "../contracts/libraries/LibAppStorage.sol";

contract InstitutionalReservationRequestCreationSecurityHarness is InstitutionalReservationRequestCreationFacet {
    function seedBackend(
        address institution,
        address backend
    ) external {
        LibAppStorage.diamondStorage().institutionalBackends[institution] = backend;
    }

    function createAsDiamondSelf(
        InstInput calldata input
    ) external {
        this.createInstReservation(input);
    }

    function recordAsDiamondSelf(
        uint256 labId,
        address trackingKey,
        bytes32 reservationKey,
        uint32 start
    ) external {
        this.recordRecentInstReservation(labId, trackingKey, reservationKey, start);
    }

    function reservationRenter(
        bytes32 reservationKey
    ) external view returns (address) {
        return LibAppStorage.diamondStorage().reservations[reservationKey].renter;
    }

    function recentReservationCount(
        uint256 labId
    ) external view returns (uint8) {
        AppStorage storage s = LibAppStorage.diamondStorage();
        return s.recentReservationsByToken[labId].size;
    }
}

contract InstitutionalReservationRequestCreationSecurityTest is Test {
    InstitutionalReservationRequestCreationSecurityHarness private harness;

    address private constant INSTITUTION = address(0xBEEF);
    address private constant TRACKING_KEY = address(0xCAFE);
    uint256 private constant LAB_ID = 7;

    function setUp() public {
        harness = new InstitutionalReservationRequestCreationSecurityHarness();
        harness.seedBackend(INSTITUTION, address(0x1234));
    }

    function test_createInstReservation_reverts_for_external_caller() public {
        vm.expectRevert();
        harness.createInstReservation(_input(keccak256("external-create")));
    }

    function test_recordRecentInstReservation_reverts_for_external_caller() public {
        harness.seedBackend(address(this), address(0x1234));

        vm.expectRevert();
        harness.recordRecentInstReservation(LAB_ID, TRACKING_KEY, keccak256("external-record"), _start());
    }

    function test_createInstReservation_allows_diamond_self_call() public {
        bytes32 reservationKey = keccak256("self-create");

        harness.createAsDiamondSelf(_input(reservationKey));

        assertEq(harness.reservationRenter(reservationKey), INSTITUTION);
    }

    function test_recordRecentInstReservation_allows_diamond_self_call() public {
        harness.recordAsDiamondSelf(LAB_ID, TRACKING_KEY, keccak256("self-record"), _start());

        assertEq(harness.recentReservationCount(LAB_ID), 1);
    }

    function _input(
        bytes32 reservationKey
    ) private view returns (InstitutionalReservationRequestCreationFacet.InstInput memory input) {
        input = InstitutionalReservationRequestCreationFacet.InstInput({
            p: INSTITUTION,
            o: INSTITUTION,
            l: LAB_ID,
            s: _start(),
            e: _start() + 1 hours,
            u: keccak256("puc"),
            k: reservationKey,
            t: TRACKING_KEY
        });
    }

    function _start() private view returns (uint32) {
        return uint32(block.timestamp + 1 days);
    }
}
