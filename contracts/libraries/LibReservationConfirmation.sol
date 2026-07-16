// SPDX-License-Identifier: GPL-3.0-or-later
pragma solidity ^0.8.33;

import {LibAppStorage, AppStorage, Reservation} from "./LibAppStorage.sol";
import {LibERC721Storage} from "./LibERC721Storage.sol";
import {LibReservationCancellation} from "./LibReservationCancellation.sol";
import {LibReservationDenyReason} from "./LibReservationDenyReason.sol";
import {LibReputation} from "./LibReputation.sol";

library LibReservationConfirmation {
    error ReservationNotFound();
    error ReservationNotPending();
    error Unauthorized();

    event ReservationRequestDenied(bytes32 indexed reservationKey, uint256 indexed tokenId, uint8 reason);

    uint8 private constant _PENDING = 0;

    function denyReservationRequest(
        bytes32 reservationKey
    ) external {
        AppStorage storage s = LibAppStorage.diamondStorage();
        Reservation storage reservation = s.reservations[reservationKey];
        _requirePending(reservation);
        _requireLabProviderOrBackend(s, reservation);
        LibReputation.recordOwnerCancellation(reservation.labId);
        LibReservationCancellation.cancelReservation(reservationKey);
        emit ReservationRequestDenied(reservationKey, reservation.labId, LibReservationDenyReason.PROVIDER_MANUAL);
    }

    function _requirePending(
        Reservation storage reservation
    ) private view {
        if (reservation.renter == address(0)) revert ReservationNotFound();
        if (reservation.status != _PENDING) revert ReservationNotPending();
    }

    function _requireLabProviderOrBackend(
        AppStorage storage s,
        Reservation storage reservation
    ) private view {
        address labOwner = LibERC721Storage.ownerOf(reservation.labId);
        address authorizedBackend = s.institutionalBackends[labOwner];
        if (msg.sender != labOwner && (authorizedBackend == address(0) || msg.sender != authorizedBackend)) {
            revert Unauthorized();
        }
    }
}
