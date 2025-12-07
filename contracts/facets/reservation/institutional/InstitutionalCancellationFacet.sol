// SPDX-License-Identifier: GPL-3.0-or-later
pragma solidity ^0.8.31;

import {EnumerableSet} from "@openzeppelin/contracts/utils/structs/EnumerableSet.sol";
import {BaseInstitutionalReservationFacet, IInstitutionalTreasuryFacetI} from "../base/BaseInstitutionalReservationFacet.sol";
import {AppStorage, Reservation} from "../../../libraries/LibAppStorage.sol";

/// @title InstitutionalCancellationFacet
/// @author Luis de la Torre Cubillo, Juan Luis Ramos Villalón
/// @notice Cancellation functions for institutional reservations
/// @dev Extracted from InstitutionalReservationFacet to reduce contract size below EIP-170 limit

contract InstitutionalCancellationFacet is BaseInstitutionalReservationFacet {
    using EnumerableSet for EnumerableSet.AddressSet;

    error BackendMissing();
    error UnauthorizedInstitution();
    error InstReservationNotFound();
    error NotRenter();
    error NotPending();
    error PucMismatch();
    error InvalidStatus();

    function cancelInstitutionalReservationRequest(
        address institutionalProvider,
        string calldata puc,
        bytes32 _reservationKey
    ) external onlyInstitution(institutionalProvider) {
        _cancelInstitutionalReservationRequest(institutionalProvider, puc, _reservationKey);
    }

    function cancelInstitutionalBooking(
        address institutionalProvider,
        bytes32 _reservationKey
    ) external onlyInstitution(institutionalProvider) {
        _cancelInstitutionalBooking(institutionalProvider, _reservationKey);
    }

    function _cancelInstitutionalReservationRequest(
        address institutionalProvider,
        string calldata puc,
        bytes32 _reservationKey
    ) internal override {
        AppStorage storage s = _s();
        if (s.institutionalBackends[institutionalProvider] == address(0)) revert BackendMissing();
        if (msg.sender != s.institutionalBackends[institutionalProvider]) revert UnauthorizedInstitution();

        Reservation storage reservation = s.reservations[_reservationKey];
        if (reservation.renter == address(0)) revert InstReservationNotFound();
        if (reservation.payerInstitution != institutionalProvider) revert NotRenter();
        if (reservation.status != _PENDING) revert NotPending();
        if (keccak256(bytes(puc)) != keccak256(bytes(reservation.puc))) revert PucMismatch();

        _cancelReservation(_reservationKey);
        emit ReservationRequestCanceled(_reservationKey, reservation.labId);
    }

    function _cancelInstitutionalBooking(
        address institutionalProvider,
        bytes32 _reservationKey
    ) internal override {
        AppStorage storage s = _s();
        if (s.institutionalBackends[institutionalProvider] == address(0)) revert BackendMissing();
        if (msg.sender != s.institutionalBackends[institutionalProvider]) revert UnauthorizedInstitution();

        Reservation storage reservation = s.reservations[_reservationKey];
        if (reservation.renter == address(0) || (reservation.status != _CONFIRMED && reservation.status != _IN_USE)) revert InvalidStatus();
        if (reservation.payerInstitution != institutionalProvider) revert NotRenter();
        uint96 price = reservation.price;
        uint96 providerFee;
        uint96 treasuryFee;
        uint96 governanceFee;
        uint96 refundAmount = price;

        if (price > 0) {
            (providerFee, treasuryFee, governanceFee, refundAmount) = _computeCancellationFee(price);
        }

        _cancelReservation(_reservationKey);

        if (price > 0) {
            _applyCancellationFees(s, reservation.labId, providerFee, treasuryFee, governanceFee);
        }

        IInstitutionalTreasuryFacetI(address(this)).refundToInstitutionalTreasury(
            reservation.payerInstitution,
            reservation.puc,
            refundAmount
        );

        emit BookingCanceled(_reservationKey, reservation.labId);
    }
}
