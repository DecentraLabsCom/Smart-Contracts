// SPDX-License-Identifier: GPL-3.0-or-later
pragma solidity ^0.8.31;

import {EnumerableSet} from "@openzeppelin/contracts/utils/structs/EnumerableSet.sol";
import {AppStorage, LibAppStorage, Reservation, INSTITUTION_ROLE} from "../../libraries/LibAppStorage.sol";
import {LibIntent} from "../../libraries/LibIntent.sol";
import {ReservationIntentPayload, ActionIntentPayload} from "../../libraries/IntentTypes.sol";
import {LibInstitutionalReservation} from "../../libraries/LibInstitutionalReservation.sol";
import {LibReservationIdentity} from "../../libraries/LibReservationIdentity.sol";

error IntentCancellationUnknownInstitution();
error IntentCancellationNotAuthorizedInstitution();
error IntentCancellationInstitutionBackendRequired();
error IntentCancellationUnknownReservation();
error IntentCancellationExecutorMustBeCaller();

/// @notice Intent-based cancellation routes kept separate so each facet remains
/// below the EIP-170 runtime bytecode limit.
contract ReservationIntentCancellationFacet {
    using EnumerableSet for EnumerableSet.AddressSet;

    event ReservationIntentProcessed(
        bytes32 indexed requestId,
        bytes32 reservationKey,
        string action,
        bytes32 pucHash,
        address institution,
        bool success,
        string reason
    );
    event ReservationIntentGenerationProcessed(
        bytes32 indexed requestId, bytes32 indexed reservationId, bytes32 indexed reservationKey
    );

    function _s() internal pure returns (AppStorage storage s) {
        s = LibAppStorage.diamondStorage();
    }

    function _onlyInstitutionalBackend(
        address institution
    ) internal view {
        AppStorage storage s = _s();
        require(s.roleMembers[INSTITUTION_ROLE].contains(institution), IntentCancellationUnknownInstitution());
        address backend = s.institutionalBackends[institution];
        require(backend != address(0), IntentCancellationInstitutionBackendRequired());
        require(msg.sender == backend, IntentCancellationNotAuthorizedInstitution());
    }

    function _consumeReservationIntent(
        bytes32 requestId,
        uint8 action,
        ReservationIntentPayload memory payload
    ) internal {
        require(payload.executor == msg.sender, IntentCancellationExecutorMustBeCaller());
        bytes32 payloadHash = LibIntent.hashReservationPayload(payload);
        LibIntent.consumeIntent(requestId, action, payloadHash, msg.sender);
    }

    function _consumeActionIntent(
        bytes32 requestId,
        uint8 action,
        ActionIntentPayload memory payload
    ) internal {
        require(payload.executor == msg.sender, IntentCancellationExecutorMustBeCaller());
        bytes32 payloadHash = LibIntent.hashActionPayload(payload);
        LibIntent.consumeIntent(requestId, action, payloadHash, msg.sender);
    }

    function _pucHashMatches(
        AppStorage storage s,
        bytes32 reservationKey,
        bytes32 pucHash
    ) internal view returns (bool) {
        bytes32 storedHash = s.reservationPucHash[LibReservationIdentity.currentReservationId(s, reservationKey)];
        return storedHash != bytes32(0) && storedHash == pucHash;
    }

    /// @notice Institutional cancellation of a pending reservation request via intent.
    function cancelInstitutionalReservationRequestWithIntent(
        bytes32 requestId,
        ReservationIntentPayload calldata payload
    ) external {
        AppStorage storage s = _s();
        Reservation storage reservation = s.reservations[payload.reservationKey];
        require(reservation.labId != 0, IntentCancellationUnknownReservation());
        _onlyInstitutionalBackend(reservation.payerInstitution);
        require(payload.labId == reservation.labId, "LAB_ID_MISMATCH");
        require(payload.start == reservation.start, "RESERVATION_START_MISMATCH");
        require(payload.end == reservation.end, "RESERVATION_END_MISMATCH");
        require(payload.price == reservation.price, "RESERVATION_PRICE_MISMATCH");
        require(_pucHashMatches(s, payload.reservationKey, payload.pucHash), "RESERVATION_PUC_MISMATCH");

        _consumeReservationIntent(requestId, LibIntent.ACTION_CANCEL_REQUEST_BOOKING, payload);

        uint256 cancelledLabId = LibInstitutionalReservation.cancelReservationRequest(
            reservation.payerInstitution, payload.pucHash, payload.reservationKey
        );
        require(cancelledLabId == reservation.labId, "RESERVATION_LAB_ID_MISMATCH");
        emit ReservationIntentProcessed(
            requestId,
            payload.reservationKey,
            "CANCEL_RESERVATION_REQUEST",
            payload.pucHash,
            reservation.payerInstitution,
            true,
            ""
        );
        emit ReservationIntentGenerationProcessed(
            requestId, LibReservationIdentity.currentReservationId(s, payload.reservationKey), payload.reservationKey
        );
    }

    /// @notice Cancels a confirmed booking via intent.
    // State is committed before the final audit event; the library call stays within the Diamond.
    // slither-disable-next-line reentrancy-events
    function cancelInstitutionalBookingWithIntent(
        bytes32 requestId,
        ActionIntentPayload calldata payload
    ) external {
        AppStorage storage s = _s();
        Reservation storage reservation = s.reservations[payload.reservationKey];
        require(reservation.labId != 0, IntentCancellationUnknownReservation());
        _onlyInstitutionalBackend(reservation.payerInstitution);
        require(payload.labId == reservation.labId, "LAB_ID_MISMATCH");
        require(payload.price == reservation.price, "RESERVATION_PRICE_MISMATCH");
        require(_pucHashMatches(s, payload.reservationKey, payload.pucHash), "RESERVATION_PUC_MISMATCH");

        _consumeActionIntent(requestId, LibIntent.ACTION_CANCEL_BOOKING, payload);

        uint256 cancelledLabId = LibInstitutionalReservation.cancelBooking(
            reservation.payerInstitution, payload.pucHash, payload.reservationKey
        );
        require(cancelledLabId == reservation.labId, "RESERVATION_LAB_ID_MISMATCH");
        emit ReservationIntentProcessed(
            requestId, payload.reservationKey, "CANCEL_BOOKING", payload.pucHash, reservation.payerInstitution, true, ""
        );
        emit ReservationIntentGenerationProcessed(
            requestId, LibReservationIdentity.currentReservationId(s, payload.reservationKey), payload.reservationKey
        );
    }
}
