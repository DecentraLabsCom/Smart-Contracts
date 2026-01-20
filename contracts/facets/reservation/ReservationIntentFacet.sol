// SPDX-License-Identifier: GPL-3.0-or-later
pragma solidity ^0.8.31;

import {EnumerableSet} from "@openzeppelin/contracts/utils/structs/EnumerableSet.sol";
import {AppStorage, LibAppStorage, Reservation, INSTITUTION_ROLE} from "../../libraries/LibAppStorage.sol";
import {LibIntent} from "../../libraries/LibIntent.sol";
import {ReservationIntentPayload, ActionIntentPayload} from "../../libraries/IntentTypes.sol";
import {LibInstitutionalReservation} from "../../libraries/LibInstitutionalReservation.sol";

// Custom errors for gas-efficient reverts (Solidity 0.8.26+)
error IntentUnknownInstitution();
error IntentNotAuthorizedInstitution();
error IntentLabDoesNotExist();
error IntentExecutorMustBeCaller();
error IntentInstitutionMustBeCaller();
error IntentUnknownReservation();

/// @title ReservationIntentFacet
/// @author
/// - Luis de la Torre Cubillo
/// - Juan Luis Ramos Villalón
/// @notice Facet for intent-based institutional reservations. Split from InstitutionalReservationFacet to reduce contract size.
contract ReservationIntentFacet {
    using EnumerableSet for EnumerableSet.AddressSet;

    /// @notice Event of institutional intents
    event ReservationIntentProcessed(bytes32 indexed requestId, bytes32 reservationKey, string action, string puc, address institution, bool success, string reason);

    function _s() internal pure returns (AppStorage storage s) {
        s = LibAppStorage.diamondStorage();
    }

    modifier onlyInstitution(address institution) {
        _onlyInstitution(institution);
        _;
    }

    function _onlyInstitution(address institution) internal view {
        AppStorage storage s = _s();
        require(s.roleMembers[INSTITUTION_ROLE].contains(institution), IntentUnknownInstitution());
        address backend = s.institutionalBackends[institution];
        require(msg.sender == institution || (backend != address(0) && msg.sender == backend), IntentNotAuthorizedInstitution());
    }

    modifier exists(uint256 labId) {
        _exists(labId);
        _;
    }

    function _exists(uint256 labId) internal view {
        require(_s().labs[labId].price > 0, IntentLabDoesNotExist());
    }

    function _getReservationKey(uint256 labId, uint32 start) internal pure returns (bytes32) {
        // forge-lint: disable-next-line(asm-keccak256)
        return keccak256(abi.encodePacked(labId, start));
    }

    function _consumeReservationIntent(
        bytes32 requestId,
        uint8 action,
        ReservationIntentPayload memory payload
    ) internal {
        require(payload.executor == msg.sender, IntentExecutorMustBeCaller());
        bytes32 payloadHash = LibIntent.hashReservationPayload(payload);
        LibIntent.consumeIntent(requestId, action, payloadHash, msg.sender);
    }

    function _consumeActionIntent(
        bytes32 requestId,
        uint8 action,
        ActionIntentPayload memory payload
    ) internal {
        require(payload.executor == msg.sender, IntentExecutorMustBeCaller());
        bytes32 payloadHash = LibIntent.hashActionPayload(payload);
        LibIntent.consumeIntent(requestId, action, payloadHash, msg.sender);
    }

    function _pucMatches(
        AppStorage storage s,
        Reservation storage,
        bytes32 reservationKey,
        string calldata puc
    ) internal view returns (bool) {
        bytes32 storedHash = s.reservationPucHash[reservationKey];
        return storedHash != bytes32(0) && storedHash == keccak256(bytes(puc));
    }

    /// @notice Institutional reservation request via intent
    function institutionalReservationRequestWithIntent(
        bytes32 requestId,
        ReservationIntentPayload calldata payload
    ) external exists(payload.labId) onlyInstitution(msg.sender) {
        AppStorage storage s = _s();
        bytes32 expectedKey = _getReservationKey(payload.labId, payload.start);
        require(payload.reservationKey == expectedKey, "RESERVATION_KEY_MISMATCH");
        require(payload.price == s.labs[payload.labId].price, "LAB_PRICE_MISMATCH");
        _consumeReservationIntent(requestId, LibIntent.ACTION_REQUEST_BOOKING, payload);

        LibInstitutionalReservation.requestReservation(
            msg.sender,
            payload.puc,
            payload.labId,
            payload.start,
            payload.end
        );
        emit ReservationIntentProcessed(requestId, payload.reservationKey, "RESERVATION_REQUEST", payload.puc, msg.sender, true, "");
    }

    /// @notice Institutional cancellation of reservation request via intent
    function cancelInstitutionalReservationRequestWithIntent(
        bytes32 requestId,
        ReservationIntentPayload calldata payload
    ) external onlyInstitution(msg.sender) {
        AppStorage storage s = _s();
        Reservation storage reservation = s.reservations[payload.reservationKey];
        require(reservation.labId != 0, IntentUnknownReservation());
        require(payload.labId == reservation.labId, "LAB_ID_MISMATCH");
        require(payload.start == reservation.start, "RESERVATION_START_MISMATCH");
        require(payload.end == reservation.end, "RESERVATION_END_MISMATCH");
        require(payload.price == reservation.price, "RESERVATION_PRICE_MISMATCH");
        require(
            _pucMatches(s, reservation, payload.reservationKey, payload.puc),
            "RESERVATION_PUC_MISMATCH"
        );

        _consumeReservationIntent(requestId, LibIntent.ACTION_CANCEL_REQUEST_BOOKING, payload);

        LibInstitutionalReservation.cancelReservationRequest(
            msg.sender,
            payload.puc,
            payload.reservationKey
        );
        emit ReservationIntentProcessed(
            requestId,
            payload.reservationKey,
            "CANCEL_RESERVATION_REQUEST",
            payload.puc,
            msg.sender,
            true,
            ""
        );
    }

    /// @notice Cancels a confirmed booking via intent
    function cancelInstitutionalBookingWithIntent(
        bytes32 requestId,
        ActionIntentPayload calldata payload
    ) external onlyInstitution(msg.sender) {
        AppStorage storage s = _s();
        Reservation storage reservation = s.reservations[payload.reservationKey];
        require(reservation.labId != 0, IntentUnknownReservation());
        require(payload.labId == reservation.labId, "LAB_ID_MISMATCH");
        require(payload.price == reservation.price, "RESERVATION_PRICE_MISMATCH");
        require(
            _pucMatches(s, reservation, payload.reservationKey, payload.puc),
            "RESERVATION_PUC_MISMATCH"
        );

        _consumeActionIntent(requestId, LibIntent.ACTION_CANCEL_BOOKING, payload);

        LibInstitutionalReservation.cancelBooking(msg.sender, payload.puc, payload.reservationKey);
        emit ReservationIntentProcessed(
            requestId,
            payload.reservationKey,
            "CANCEL_BOOKING",
            payload.puc,
            msg.sender,
            true,
            ""
        );
    }
}
