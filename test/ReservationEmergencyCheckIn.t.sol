// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.33;

import "forge-std/Test.sol";
import {ReservationCheckInFacet} from "../contracts/facets/reservation/ReservationCheckInFacet.sol";
import {AppStorage, LibAppStorage, Reservation} from "../contracts/libraries/LibAppStorage.sol";
import {LibDiamond} from "../contracts/libraries/LibDiamond.sol";
import {LibInstitutionalReservationSettlement} from "../contracts/libraries/LibInstitutionalReservationSettlement.sol";
import {LibReservationIdentity} from "../contracts/libraries/LibReservationIdentity.sol";
import {EnumerableSet} from "@openzeppelin/contracts/utils/structs/EnumerableSet.sol";

contract EmergencyAuthority {
    function execute(
        address target,
        bytes calldata data
    ) external returns (bytes memory result) {
        (bool success, bytes memory returnData) = target.call(data);
        if (!success) assembly { revert(add(returnData, 32), mload(returnData)) }
        return returnData;
    }
}

contract ReservationEmergencyCheckInHarness is ReservationCheckInFacet {
    using EnumerableSet for EnumerableSet.AddressSet;

    function setOwner(
        address owner
    ) external {
        LibDiamond.setContractOwner(owner);
    }

    function setAdmin(
        address admin
    ) external {
        AppStorage storage s = LibAppStorage.diamondStorage();
        s.DEFAULT_ADMIN_ROLE = bytes32(0);
        s.roleMembers[s.DEFAULT_ADMIN_ROLE].add(admin);
    }

    function setConfirmedReservation(
        bytes32 reservationKey,
        uint256 labId,
        uint32 start,
        uint32 end
    ) external returns (bytes32 reservationId) {
        AppStorage storage s = LibAppStorage.diamondStorage();
        reservationId = LibReservationIdentity.createReservationId(s, reservationKey);
        s.reservations[reservationKey] = Reservation({
            labId: labId,
            renter: address(0xBEEF),
            price: 1000,
            labProvider: address(0xCAFE),
            status: 1,
            start: start,
            end: end,
            requestPeriodStart: 0,
            requestPeriodDuration: 0,
            payerInstitution: address(0xD00D),
            collectorInstitution: address(0xD00D),
            providerShare: 500
        });
    }

    function getReservationStatus(
        bytes32 reservationKey
    ) external view returns (uint8) {
        return LibAppStorage.diamondStorage().reservations[reservationKey].status;
    }

    function isSettlementExcluded(
        bytes32 reservationKey
    ) external view returns (bool) {
        return emergencyCheckInSettlementExcluded(reservationKey);
    }

    function emergencyCheckInSettlementExcluded(
        bytes32 reservationKey
    ) public view returns (bool) {
        AppStorage storage s = LibAppStorage.diamondStorage();
        return
            s.emergencyCheckInReviews[LibReservationIdentity.currentReservationId(s, reservationKey)].settlementExcluded;
    }

    function canFinalize(
        bytes32 reservationKey,
        uint256 currentTime
    ) external view returns (bool) {
        AppStorage storage s = LibAppStorage.diamondStorage();
        return LibInstitutionalReservationSettlement.isEconomicallyExpired(
            s, s.reservations[reservationKey], reservationKey, currentTime
        );
    }
}

contract ReservationEmergencyCheckInTest is Test {
    using EnumerableSet for EnumerableSet.AddressSet;

    ReservationEmergencyCheckInHarness internal harness;
    EmergencyAuthority internal authority;
    address internal admin = address(0xA11CE);
    bytes32 internal constant RESERVATION_KEY = keccak256("emergency-check-in");
    uint256 internal constant LAB_ID = 7;

    function setUp() public {
        harness = new ReservationEmergencyCheckInHarness();
        authority = new EmergencyAuthority();
        harness.setOwner(address(authority));
        harness.setAdmin(admin);
        harness.setConfirmedReservation(
            RESERVATION_KEY, LAB_ID, uint32(block.timestamp - 1), uint32(block.timestamp + 1000)
        );
    }

    function test_emergencyCheckIn_requiresGovernanceContract() public {
        vm.prank(admin);
        vm.expectRevert("Emergency authority required");
        harness.emergencyCheckIn(RESERVATION_KEY, 1);
    }

    function test_emergencyCheckIn_rejectsAnEoaDiamondOwner() public {
        address eoaOwner = address(0xE0A);
        harness.setOwner(eoaOwner);

        vm.prank(eoaOwner);
        vm.expectRevert("Emergency authority must be multisig or timelock");
        harness.emergencyCheckIn(RESERVATION_KEY, 1);
    }

    function test_emergencyCheckIn_requiresReasonCode() public {
        vm.expectRevert("Emergency reason required");
        authority.execute(address(harness), abi.encodeCall(harness.emergencyCheckIn, (RESERVATION_KEY, 0)));
    }

    function test_emergencyCheckIn_isAuditedAndExcludedFromSettlement() public {
        vm.expectEmit(false, true, true, true, address(harness));
        emit ReservationCheckInFacet.EmergencyCheckIn(
            bytes32(0), RESERVATION_KEY, LAB_ID, 9, address(authority), uint64(block.timestamp)
        );
        vm.expectEmit(false, true, true, true, address(harness));
        emit ReservationCheckInFacet.EmergencyCheckInSettlementReviewRequired(
            bytes32(0), RESERVATION_KEY, LAB_ID, 9, address(authority), uint64(block.timestamp)
        );

        authority.execute(address(harness), abi.encodeCall(harness.emergencyCheckIn, (RESERVATION_KEY, 9)));

        assertEq(harness.getReservationStatus(RESERVATION_KEY), 2);
        assertTrue(harness.isSettlementExcluded(RESERVATION_KEY));
        assertFalse(harness.canFinalize(RESERVATION_KEY, block.timestamp + 2000));
    }

    function test_review_releasesReservationForSettlement() public {
        authority.execute(address(harness), abi.encodeCall(harness.emergencyCheckIn, (RESERVATION_KEY, 1)));

        authority.execute(address(harness), abi.encodeCall(harness.reviewEmergencyCheckIn, (RESERVATION_KEY)));

        assertFalse(harness.isSettlementExcluded(RESERVATION_KEY));
        assertTrue(harness.canFinalize(RESERVATION_KEY, block.timestamp + 2 days));
    }
}
