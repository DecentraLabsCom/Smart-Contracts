// SPDX-License-Identifier: GPL-3.0-or-later
pragma solidity ^0.8.31;

import {EnumerableSet} from "@openzeppelin/contracts/utils/structs/EnumerableSet.sol";
import {BaseInstitutionalReservationFacet} from "../base/BaseInstitutionalReservationFacet.sol";
import {LibInstitutionalReservation} from "../../../libraries/LibInstitutionalReservation.sol";

/// @title InstitutionalReservationCancellationFacet
/// @author Luis de la Torre Cubillo, Juan Luis Ramos Villalón
/// @notice Cancellation functions for institutional reservations
/// @dev Extracted from InstitutionalReservationFacet to reduce contract size below EIP-170 limit

contract InstitutionalReservationCancellationFacet is BaseInstitutionalReservationFacet {
    using EnumerableSet for EnumerableSet.AddressSet;

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
        uint256 labId = LibInstitutionalReservation.cancelReservationRequest(
            institutionalProvider,
            puc,
            _reservationKey
        );
        emit ReservationRequestCanceled(_reservationKey, labId);
    }

    function _cancelInstitutionalBooking(
        address institutionalProvider,
        bytes32 _reservationKey
    ) internal override {
        uint256 labId = LibInstitutionalReservation.cancelBooking(
            institutionalProvider,
            _reservationKey
        );
        emit BookingCanceled(_reservationKey, labId);
    }
}
