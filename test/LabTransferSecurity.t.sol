// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.33;

import "forge-std/Test.sol";
import {EnumerableSet} from "@openzeppelin/contracts/utils/structs/EnumerableSet.sol";
import {AppStorage, LibAppStorage} from "../contracts/libraries/LibAppStorage.sol";
import {LibLabTransfer} from "../contracts/libraries/LibLabTransfer.sol";

contract LabTransferGuardHarness {
    using EnumerableSet for EnumerableSet.Bytes32Set;

    function setReservationStatus(
        uint256 labId,
        bytes32 reservationKey,
        uint8 status
    ) external {
        AppStorage storage s = LibAppStorage.diamondStorage();
        s.reservations[reservationKey].status = status;
        s.reservationKeysByToken[labId].add(reservationKey);
    }

    function validateTransfer(
        uint256 labId,
        uint256 maxCleanup
    ) external {
        LibLabTransfer.validateNoActiveReservationsOnTransfer(labId, maxCleanup);
    }
}

contract LabTransferSecurityTest is Test {
    uint256 private constant LAB_ID = 7;
    uint256 private constant MAX_CLEANUP = 100;

    LabTransferGuardHarness private harness;

    function setUp() public {
        harness = new LabTransferGuardHarness();
    }

    function test_transferRejectsPendingConfirmedAndAccessAuthorizedReservations() public {
        uint8[3] memory activeStatuses = [uint8(0), uint8(1), uint8(2)];

        for (uint256 i; i < activeStatuses.length; i++) {
            bytes32 reservationKey = keccak256(abi.encode("active", activeStatuses[i]));
            harness.setReservationStatus(LAB_ID, reservationKey, activeStatuses[i]);

            vm.expectRevert("Non-terminal reservations block transfer");
            harness.validateTransfer(LAB_ID, MAX_CLEANUP);
        }
    }

    function test_transferAllowsOnlyTerminalReservations() public {
        harness.setReservationStatus(LAB_ID, keccak256("settled"), 3);
        harness.setReservationStatus(LAB_ID, keccak256("cancelled"), 4);

        harness.validateTransfer(LAB_ID, MAX_CLEANUP);
    }

    function test_transferRejectsUnknownReservationStatuses() public {
        harness.setReservationStatus(LAB_ID, keccak256("unknown"), 5);

        vm.expectRevert("Non-terminal reservations block transfer");
        harness.validateTransfer(LAB_ID, MAX_CLEANUP);
    }
}
