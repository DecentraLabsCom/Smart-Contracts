// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.33;

import "forge-std/Test.sol";
import "@openzeppelin/contracts/utils/structs/EnumerableSet.sol";
import "../contracts/facets/reservation/ReservationIntentFacet.sol";
import "../contracts/libraries/IntentTypes.sol";
import "../contracts/libraries/LibAppStorage.sol";
import "../contracts/libraries/LibIntent.sol";
import "../contracts/libraries/LibRevenue.sol";
import "../contracts/libraries/LibERC721Storage.sol";
import "../contracts/libraries/LibInstitutionalReservation.sol";
import "../contracts/libraries/LibTracking.sol";

contract ReservationIntentHarness is ReservationIntentFacet {
    using EnumerableSet for EnumerableSet.AddressSet;

    address public lastRefundInstitution;
    bytes32 public lastRefundPucHash;
    bytes32 public lastRefundReservationKey;
    uint256 public lastRefundAmount;

    function setInstitution(
        address institution
    ) external {
        setInstitutionWithBackend(institution, institution);
    }

    function setInstitutionWithBackend(
        address institution,
        address backend
    ) public {
        AppStorage storage s = LibAppStorage.diamondStorage();
        s.roleMembers[INSTITUTION_ROLE].add(institution);
        s.institutionalBackends[institution] = backend;
        s.organizationInstitutionWallet[keccak256(bytes("institution.example"))] = institution;
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

    function setPendingReservation(
        bytes32 reservationKey,
        address institution,
        uint256 labId,
        uint32 start,
        uint32 end,
        uint96 price,
        string calldata puc
    ) external {
        AppStorage storage s = LibAppStorage.diamondStorage();
        Reservation storage r = s.reservations[reservationKey];
        r.renter = institution;
        r.payerInstitution = institution;
        r.price = price;
        r.status = 0;
        r.labId = labId;
        r.start = start;
        r.end = end;
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

    function setPendingCancelRequestIntent(
        bytes32 requestId,
        address executor,
        ReservationIntentPayload memory payload
    ) external {
        AppStorage storage s = LibAppStorage.diamondStorage();
        s.intents[requestId] = IntentMeta({
            requestId: requestId,
            signer: executor,
            executor: executor,
            action: LibIntent.ACTION_CANCEL_REQUEST_BOOKING,
            payloadHash: LibIntent.hashReservationPayload(payload),
            nonce: 0,
            requestedAt: uint64(block.timestamp),
            expiresAt: uint64(block.timestamp + 1 hours),
            state: IntentState.Pending
        });
    }

    function setPendingDirectBookingIntent(
        bytes32 requestId,
        ReservationIntentPayload memory payload
    ) external {
        AppStorage storage s = LibAppStorage.diamondStorage();
        s.intents[requestId] = IntentMeta({
            requestId: requestId,
            signer: payload.executor,
            executor: payload.executor,
            action: LibIntent.ACTION_DIRECT_BOOKING,
            payloadHash: LibIntent.hashReservationPayload(payload),
            nonce: 0,
            requestedAt: uint64(block.timestamp),
            expiresAt: uint64(block.timestamp + 1 hours),
            state: IntentState.Pending
        });
    }

    function setPendingReservationRequestIntent(
        bytes32 requestId,
        ReservationIntentPayload memory payload
    ) external {
        AppStorage storage s = LibAppStorage.diamondStorage();
        s.intents[requestId] = IntentMeta({
            requestId: requestId,
            signer: payload.executor,
            executor: payload.executor,
            action: LibIntent.ACTION_REQUEST_BOOKING,
            payloadHash: LibIntent.hashReservationPayload(payload),
            nonce: 0,
            requestedAt: uint64(block.timestamp),
            expiresAt: uint64(block.timestamp + 1 hours),
            state: IntentState.Pending
        });
    }

    function setLabOwnerAndPrice(
        uint256 labId,
        address owner,
        uint96 price
    ) external {
        AppStorage storage s = LibAppStorage.diamondStorage();
        s.labs[labId].price = price;
        s.activeLabIndexPlusOne[labId] = 1;
        s.tokenStatus[labId] = true;
        s.providerNetworkStatus[owner] = ProviderNetworkStatus.ACTIVE;
        LibERC721Storage.layout()._owners[labId] = owner;
    }

    function validateInstRequest(
        address institution,
        bytes32 pucHash,
        uint256 labId,
        uint32 start,
        uint32
    ) external view returns (address owner, bytes32 key, address trackingKey) {
        owner = LibERC721Storage.ownerOf(labId);
        key = keccak256(abi.encodePacked(labId, start));
        trackingKey = LibTracking.trackingKeyFromInstitutionHash(institution, pucHash);
    }

    function createInstReservation(
        InstInput calldata input
    ) external {
        AppStorage storage s = LibAppStorage.diamondStorage();
        Reservation storage reservation = s.reservations[input.k];
        reservation.labId = input.l;
        reservation.renter = input.p;
        reservation.payerInstitution = input.p;
        reservation.labProvider = input.o;
        reservation.price = 0;
        reservation.status = 0;
        reservation.start = input.s;
        reservation.end = input.e;
        reservation.requestPeriodStart = uint64(block.timestamp);
        reservation.requestPeriodDuration = uint64(1 days);
        s.reservationPucHash[input.k] = input.u;
    }

    function recordRecentInstReservation(
        uint256,
        address,
        bytes32,
        uint32
    ) external {}

    function reservationPrice(
        address institution,
        uint256 labId,
        uint32 start,
        uint32 end
    ) external view returns (uint96) {
        return _reservationPrice(LibAppStorage.diamondStorage(), institution, labId, start, end);
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

    function reservationPayer(
        bytes32 reservationKey
    ) external view returns (address) {
        return LibAppStorage.diamondStorage().reservations[reservationKey].payerInstitution;
    }

    function refundToInstitutionalTreasuryForReservation(
        address institution,
        bytes32 pucHash,
        bytes32 reservationKey,
        uint256 amount
    ) external {
        lastRefundInstitution = institution;
        lastRefundPucHash = pucHash;
        lastRefundReservationKey = reservationKey;
        lastRefundAmount = amount;
    }
}

contract ReservationIntentFacetTest is Test {
    ReservationIntentHarness harness;
    address institution = address(0xCAFE);
    address institutionBackend = address(0xBEEF);
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
        harness.cancelInstitutionalBookingWithIntent(requestId, payload);

        assertEq(uint8(harness.intentState(requestId)), uint8(IntentState.Executed));
        assertEq(harness.reservationStatus(reservationKey), 4);
        assertEq(harness.lastRefundInstitution(), institution);
        assertEq(harness.lastRefundPucHash(), keccak256(bytes(PUC)));
    }

    function test_cancelBookingWithIntent_allows_separate_institution_backend() public {
        bytes32 reservationKey = keccak256("cancel-booking-separate-backend");
        bytes32 requestId = keccak256("cancel-booking-separate-backend-intent");
        uint96 price = 5000;
        ActionIntentPayload memory payload = _cancelPayload(reservationKey, keccak256(bytes(PUC)), price);
        payload.executor = institutionBackend;

        harness.setInstitutionWithBackend(institution, institutionBackend);
        harness.setConfirmedReservation(reservationKey, institution, payload.labId, price, PUC);
        harness.setPendingCancelBookingIntent(requestId, institutionBackend, payload);

        vm.prank(institutionBackend);
        harness.cancelInstitutionalBookingWithIntent(requestId, payload);

        assertEq(uint8(harness.intentState(requestId)), uint8(IntentState.Executed));
        assertEq(harness.reservationStatus(reservationKey), 4);
        assertEq(harness.lastRefundInstitution(), institution);
        (, uint96 expectedRefund) = LibRevenue.computeCancellationFee(price);
        assertEq(harness.lastRefundAmount(), expectedRefund);
    }

    function test_cancelReservationRequestWithIntent_allows_separate_institution_backend() public {
        bytes32 reservationKey = keccak256("cancel-request-separate-backend");
        bytes32 requestId = keccak256("cancel-request-separate-backend-intent");
        bytes32 pucHash = keccak256(bytes(PUC));
        ReservationIntentPayload memory payload = ReservationIntentPayload({
            executor: institutionBackend,
            schacHomeOrganization: "institution.example",
            pucHash: pucHash,
            assertionHash: bytes32(0),
            labId: 17,
            start: uint32(block.timestamp + 1 days),
            end: uint32(block.timestamp + 1 days + 1 hours),
            price: 5000,
            reservationKey: reservationKey
        });

        harness.setInstitutionWithBackend(institution, institutionBackend);
        harness.setPendingReservation(
            reservationKey, institution, payload.labId, payload.start, payload.end, payload.price, PUC
        );
        harness.setPendingCancelRequestIntent(requestId, institutionBackend, payload);

        vm.prank(institutionBackend);
        harness.cancelInstitutionalReservationRequestWithIntent(requestId, payload);

        assertEq(uint8(harness.intentState(requestId)), uint8(IntentState.Executed));
        assertEq(harness.reservationStatus(reservationKey), 4);
    }

    function test_cancelBookingWithIntent_revertsWhenPucHashMismatch() public {
        bytes32 reservationKey = keccak256("reservation-mismatch");
        bytes32 requestId = keccak256("cancel-booking-mismatch");
        uint96 price = 5000;
        ActionIntentPayload memory payload = _cancelPayload(reservationKey, keccak256(bytes("other")), price);

        harness.setConfirmedReservation(reservationKey, institution, payload.labId, price, PUC);
        harness.setPendingCancelBookingIntent(requestId, institution, payload);

        vm.prank(institution);
        vm.expectRevert(bytes("RESERVATION_PUC_MISMATCH"));
        harness.cancelInstitutionalBookingWithIntent(requestId, payload);
    }

    function test_reservationPrice_isZeroForOwnInstitutionLab() public {
        uint256 labId = 42;
        uint32 start = uint32(block.timestamp + 1 hours);
        harness.setLabOwnerAndPrice(labId, institution, 23);

        assertEq(harness.reservationPrice(institution, labId, start, start + 1800), 0);
    }

    function test_reservationPrice_usesRawPriceForExternalInstitutionLab() public {
        uint256 labId = 43;
        uint32 start = uint32(block.timestamp + 1 hours);
        harness.setLabOwnerAndPrice(labId, address(0xD00D), 23);

        assertEq(harness.reservationPrice(institution, labId, start, start + 1800), 23 * 1800);
    }

    function test_directBookingWithIntent_confirmsOwnLabAtomically() public {
        uint256 labId = 44;
        uint32 start = uint32(block.timestamp + 1 hours);
        uint32 end = start + 1800;
        bytes32 reservationKey = keccak256(abi.encodePacked(labId, start));
        bytes32 requestId = keccak256("direct-booking-own-lab");
        ReservationIntentPayload memory payload = ReservationIntentPayload({
            executor: institution,
            schacHomeOrganization: "institution.example",
            pucHash: keccak256(bytes(PUC)),
            assertionHash: bytes32(0),
            labId: labId,
            start: start,
            end: end,
            price: 0,
            reservationKey: reservationKey
        });

        harness.setLabOwnerAndPrice(labId, institution, 23);
        harness.setPendingDirectBookingIntent(requestId, payload);

        vm.prank(institution);
        harness.institutionalDirectBookingWithIntent(requestId, payload);

        assertEq(uint8(harness.intentState(requestId)), uint8(IntentState.Executed));
        assertEq(harness.reservationStatus(reservationKey), 1);
    }

    function test_directBookingWithIntent_allowsOwnerBackendAndKeepsOwnerAsPayer() public {
        uint256 labId = 45;
        uint32 start = uint32(block.timestamp + 1 hours);
        uint32 end = start + 1800;
        bytes32 reservationKey = keccak256(abi.encodePacked(labId, start));
        bytes32 requestId = keccak256("direct-booking-owner-backend");
        ReservationIntentPayload memory payload = ReservationIntentPayload({
            executor: institutionBackend,
            schacHomeOrganization: "institution.example",
            pucHash: keccak256(bytes(PUC)),
            assertionHash: bytes32(0),
            labId: labId,
            start: start,
            end: end,
            price: 0,
            reservationKey: reservationKey
        });

        harness.setInstitutionWithBackend(institution, institutionBackend);
        harness.setLabOwnerAndPrice(labId, institution, 23);
        harness.setPendingDirectBookingIntent(requestId, payload);

        vm.prank(institutionBackend);
        harness.institutionalDirectBookingWithIntent(requestId, payload);

        assertEq(uint8(harness.intentState(requestId)), uint8(IntentState.Executed));
        assertEq(harness.reservationStatus(reservationKey), 1);
        assertEq(harness.reservationPayer(reservationKey), institution);
    }

    function test_directBookingWithIntent_rejectsUnrelatedExecutor() public {
        uint256 labId = 47;
        uint32 start = uint32(block.timestamp + 1 hours);
        bytes32 reservationKey = keccak256(abi.encodePacked(labId, start));
        bytes32 requestId = keccak256("direct-booking-unrelated-executor");
        address unrelatedExecutor = address(0xD00D);
        ReservationIntentPayload memory payload = ReservationIntentPayload({
            executor: unrelatedExecutor,
            schacHomeOrganization: "institution.example",
            pucHash: keccak256(bytes(PUC)),
            assertionHash: bytes32(0),
            labId: labId,
            start: start,
            end: start + 1800,
            price: 0,
            reservationKey: reservationKey
        });

        harness.setLabOwnerAndPrice(labId, institution, 23);
        harness.setPendingDirectBookingIntent(requestId, payload);

        vm.prank(unrelatedExecutor);
        vm.expectRevert(IntentNotAuthorizedInstitution.selector);
        harness.institutionalDirectBookingWithIntent(requestId, payload);
    }

    function test_reservationRequestWithIntent_allowsInstitutionBackendAndKeepsInstitutionAsPayer() public {
        uint256 labId = 46;
        uint32 start = uint32(block.timestamp + 1 hours);
        uint32 end = start + 1800;
        bytes32 reservationKey = keccak256(abi.encodePacked(labId, start));
        bytes32 requestId = keccak256("reservation-request-institution-backend");
        ReservationIntentPayload memory payload = ReservationIntentPayload({
            executor: institutionBackend,
            schacHomeOrganization: "institution.example",
            pucHash: keccak256(bytes(PUC)),
            assertionHash: bytes32(0),
            labId: labId,
            start: start,
            end: end,
            price: 23 * 1800,
            reservationKey: reservationKey
        });

        harness.setInstitutionWithBackend(institution, institutionBackend);
        harness.setLabOwnerAndPrice(labId, address(0xD00D), 23);
        harness.setPendingReservationRequestIntent(requestId, payload);

        vm.prank(institutionBackend);
        harness.institutionalReservationRequestWithIntent(requestId, payload);

        assertEq(uint8(harness.intentState(requestId)), uint8(IntentState.Executed));
        assertEq(harness.reservationStatus(reservationKey), 0);
        assertEq(harness.reservationPayer(reservationKey), institution);
    }
}
