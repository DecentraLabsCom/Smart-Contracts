// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.33;

import "forge-std/Test.sol";
import "@openzeppelin/contracts/utils/structs/EnumerableSet.sol";
import "../contracts/facets/reservation/ReservationIntentFacet.sol";
import "../contracts/libraries/IntentTypes.sol";
import "../contracts/libraries/LibAppStorage.sol";
import "../contracts/libraries/LibIntent.sol";

contract ReservationIntentHarness is ReservationIntentFacet {
    using EnumerableSet for EnumerableSet.AddressSet;

    address public lastRefundInstitution;
    string public lastRefundPuc;
    uint256 public lastRefundAmount;

    function setInstitution(
        address institution
    ) external {
        AppStorage storage s = LibAppStorage.diamondStorage();
        s.roleMembers[INSTITUTION_ROLE].add(institution);
        s.institutionalBackends[institution] = institution;
    }

    function setConfirmedReservation(
        bytes32 reservationKey,
        address institution,
        uint256 labId,
        uint96 price,
        string calldata puc
    ) external {
        AppStorage storage s = LibAppStorage.diamondStorage();
        Reservation storage r = s.reservations[reservationKey];
        r.renter = institution;
        r.payerInstitution = institution;
        r.price = price;
        r.status = 1;
        r.labId = labId;
        r.start = uint32(block.timestamp + 1 days);
        r.end = uint32(block.timestamp + 1 days + 1 hours);
        s.reservationPucHash[reservationKey] = keccak256(bytes(puc));
    }

    function setPendingCancelBookingIntent(
        bytes32 requestId,
        address executor,
        ActionIntentPayload memory payload
    ) external {
        AppStorage storage s = LibAppStorage.diamondStorage();
        s.intents[requestId] = IntentMeta({
            requestId: requestId,
            signer: executor,
            executor: executor,
            action: LibIntent.ACTION_CANCEL_BOOKING,
            payloadHash: LibIntent.hashActionPayloadPublic(payload),
            nonce: 0,
            requestedAt: uint64(block.timestamp),
            expiresAt: uint64(block.timestamp + 1 hours),
            state: IntentState.Pending
        });
    }

    function intentState(
        bytes32 requestId
    ) external view returns (IntentState) {
        return LibAppStorage.diamondStorage().intents[requestId].state;
    }

    function reservationStatus(
        bytes32 reservationKey
    ) external view returns (uint8) {
        return LibAppStorage.diamondStorage().reservations[reservationKey].status;
    }

    function refundToInstitutionalTreasury(
        address institution,
        string calldata puc,
        uint256 amount
    ) external {
        lastRefundInstitution = institution;
        lastRefundPuc = puc;
        lastRefundAmount = amount;
    }
}

contract ReservationIntentFacetTest is Test {
    ReservationIntentHarness harness;
    address institution = address(0xCAFE);
    string constant PUC = "alice@institution.example";

    function setUp() public {
        harness = new ReservationIntentHarness();
        harness.setInstitution(institution);
    }

    function _cancelPayload(
        bytes32 reservationKey,
        bytes32 pucHash,
        uint96 price
    ) internal view returns (ActionIntentPayload memory) {
        return ActionIntentPayload({
            executor: institution,
            schacHomeOrganization: "institution.example",
            pucHash: pucHash,
            assertionHash: bytes32(0),
            labId: 17,
            reservationKey: reservationKey,
            uri: "",
            price: price,
            maxBatch: 0,
            accessURI: "",
            accessKey: "",
            tokenURI: "",
            resourceType: 0
        });
    }

    function test_cancelBookingWithIntent_consumesActionPayload() public {
        bytes32 reservationKey = keccak256("reservation");
        bytes32 requestId = keccak256("cancel-booking");
        uint96 price = 5000;
        ActionIntentPayload memory payload = _cancelPayload(reservationKey, keccak256(bytes(PUC)), price);

        harness.setConfirmedReservation(reservationKey, institution, payload.labId, price, PUC);
        harness.setPendingCancelBookingIntent(requestId, institution, payload);

        vm.prank(institution);
        harness.cancelInstitutionalBookingWithIntent(requestId, payload, PUC);

        assertEq(uint8(harness.intentState(requestId)), uint8(IntentState.Executed));
        assertEq(harness.reservationStatus(reservationKey), 5);
        assertEq(harness.lastRefundInstitution(), institution);
        assertEq(harness.lastRefundPuc(), PUC);
    }

    function test_cancelBookingWithIntent_revertsWhenPucHashMismatch() public {
        bytes32 reservationKey = keccak256("reservation-mismatch");
        bytes32 requestId = keccak256("cancel-booking-mismatch");
        uint96 price = 5000;
        ActionIntentPayload memory payload = _cancelPayload(reservationKey, keccak256(bytes("other")), price);

        harness.setConfirmedReservation(reservationKey, institution, payload.labId, price, PUC);
        harness.setPendingCancelBookingIntent(requestId, institution, payload);

        vm.prank(institution);
        vm.expectRevert(bytes("PAYLOAD_PUC_MISMATCH"));
        harness.cancelInstitutionalBookingWithIntent(requestId, payload, PUC);
    }
}
