// SPDX-License-Identifier: GPL-3.0-or-later
pragma solidity ^0.8.31;

import {EnumerableSet} from "@openzeppelin/contracts/utils/structs/EnumerableSet.sol";
import {AppStorage, LibAppStorage, Reservation, INSTITUTION_ROLE} from "../../../libraries/LibAppStorage.sol";
import {LibIntent} from "../../../libraries/LibIntent.sol";
import {ReservationIntentPayload, ActionIntentPayload} from "../../../libraries/IntentTypes.sol";

// Custom errors for gas-efficient reverts (Solidity 0.8.26+)
error IntentUnknownInstitution();
error IntentNotAuthorizedInstitution();
error IntentLabDoesNotExist();
error IntentExecutorMustBeCaller();
error IntentInstitutionMustBeCaller();
error IntentUnknownReservation();

/// @dev Interface for calling InstitutionalReservationFacet
interface IInstitutionalReservationFacet {
    function institutionalReservationRequest(
        address institutionalProvider,
        string calldata puc,
        uint256 _labId,
        uint32 _start,
        uint32 _end
    ) external;
    function cancelInstitutionalReservationRequest(
        address institutionalProvider,
        string calldata puc,
        bytes32 _reservationKey
    ) external;
    function cancelInstitutionalBooking(
        address institutionalProvider,
        bytes32 _reservationKey
    ) external;
}

/// @title InstitutionalIntentFacet
/// @author
/// - Luis de la Torre Cubillo
/// - Juan Luis Ramos Villalón
/// @notice Facet for intent-based institutional reservations. Split from InstitutionalReservationFacet to reduce contract size.
contract InstitutionalIntentFacet {
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

    /// @notice Institutional reservation request via intent
    function institutionalReservationRequestWithIntent(
        bytes32 requestId,
        address institutionalProvider,
        string calldata puc,
        uint256 _labId,
        uint32 _start,
        uint32 _end
    ) external exists(_labId) onlyInstitution(institutionalProvider) {
        require(institutionalProvider == msg.sender, IntentInstitutionMustBeCaller());
        AppStorage storage s = _s();
        
        bytes32 reservationKey = _getReservationKey(_labId, _start);
        uint96 price = s.labs[_labId].price;

        ReservationIntentPayload memory payload = ReservationIntentPayload({
            executor: msg.sender,
            schacHomeOrganization: "",
            puc: puc,
            assertionHash: bytes32(0),
            labId: _labId,
            start: _start,
            end: _end,
            price: price,
            reservationKey: reservationKey
        });
        _consumeReservationIntent(requestId, LibIntent.ACTION_REQUEST_BOOKING, payload);

        IInstitutionalReservationFacet(address(this)).institutionalReservationRequest(institutionalProvider, puc, _labId, _start, _end);
        emit ReservationIntentProcessed(requestId, reservationKey, "RESERVATION_REQUEST", puc, institutionalProvider, true, "");
    }

    /// @notice Institutional cancellation of reservation request via intent
    function cancelInstitutionalReservationRequestWithIntent(
        bytes32 requestId,
        address institutionalProvider,
        string calldata puc,
        bytes32 _reservationKey
    ) external onlyInstitution(institutionalProvider) {
        require(institutionalProvider == msg.sender, IntentInstitutionMustBeCaller());
        AppStorage storage s = _s();
        Reservation storage reservation = s.reservations[_reservationKey];
        require(reservation.labId != 0, IntentUnknownReservation());

        ReservationIntentPayload memory payload = ReservationIntentPayload({
            executor: msg.sender,
            schacHomeOrganization: "",
            puc: puc,
            assertionHash: bytes32(0),
            labId: reservation.labId,
            start: reservation.start,
            end: reservation.end,
            price: reservation.price,
            reservationKey: _reservationKey
        });
        _consumeReservationIntent(requestId, LibIntent.ACTION_CANCEL_REQUEST_BOOKING, payload);

        IInstitutionalReservationFacet(address(this)).cancelInstitutionalReservationRequest(institutionalProvider, puc, _reservationKey);
        emit ReservationIntentProcessed(requestId, _reservationKey, "CANCEL_RESERVATION_REQUEST", puc, institutionalProvider, true, "");
    }

    /// @notice Cancels a confirmed booking via intent
    function cancelInstitutionalBookingWithIntent(
        bytes32 requestId,
        address institutionalProvider,
        bytes32 _reservationKey
    ) external onlyInstitution(institutionalProvider) {
        require(institutionalProvider == msg.sender, IntentInstitutionMustBeCaller());
        AppStorage storage s = _s();
        Reservation storage reservation = s.reservations[_reservationKey];
        require(reservation.labId != 0, IntentUnknownReservation());

        ActionIntentPayload memory payload = ActionIntentPayload({
            executor: msg.sender,
            schacHomeOrganization: "",
            puc: reservation.puc,
            assertionHash: bytes32(0),
            labId: reservation.labId,
            reservationKey: _reservationKey,
            uri: "",
            price: reservation.price,
            maxBatch: 0,
            auth: "",
            accessURI: "",
            accessKey: "",
            tokenURI: ""
        });
        _consumeActionIntent(requestId, LibIntent.ACTION_CANCEL_BOOKING, payload);

        IInstitutionalReservationFacet(address(this)).cancelInstitutionalBooking(institutionalProvider, _reservationKey);
        emit ReservationIntentProcessed(requestId, _reservationKey, "CANCEL_BOOKING", reservation.puc, institutionalProvider, true, "");
    }
}
