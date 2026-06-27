// SPDX-License-Identifier: GPL-3.0-or-later
pragma solidity ^0.8.31;

import {EnumerableSet} from "@openzeppelin/contracts/utils/structs/EnumerableSet.sol";
import {LibAppStorage, AppStorage, INSTITUTION_ROLE} from "../../../libraries/LibAppStorage.sol";
import {LibInstitutionalReservation} from "../../../libraries/LibInstitutionalReservation.sol";

/// @title InstitutionalReservationCancellationFacet
/// @author Luis de la Torre Cubillo, Juan Luis Ramos Villalón
/// @notice Cancellation functions for institutional reservations

contract InstitutionalReservationCancellationFacet {
    using EnumerableSet for EnumerableSet.AddressSet;

    event ReservationRequestCanceled(bytes32 indexed reservationKey, uint256 indexed tokenId);
    event BookingCanceled(bytes32 indexed reservationKey, uint256 indexed tokenId);

    modifier onlyInstitution(
        address institution
    ) {
        _onlyInstitution(institution);
        _;
    }

    function _onlyInstitution(
        address institution
    ) internal view {
        AppStorage storage s = _s();
        if (!s.roleMembers[INSTITUTION_ROLE].contains(institution)) revert("Unknown institution");
        address backend = s.institutionalBackends[institution];
        if (!(msg.sender == institution || (backend != address(0) && msg.sender == backend))) {
            revert("Unauthorized institution");
        }
    }

    function _s() internal pure returns (AppStorage storage s) {
        return LibAppStorage.diamondStorage();
    }

    function cancelInstitutionalReservationRequest(
        address institutionalProvider,
        bytes32 pucHash,
        bytes32 _reservationKey
    ) external onlyInstitution(institutionalProvider) {
        _cancelInstitutionalReservationRequest(institutionalProvider, pucHash, _reservationKey);
    }

    function cancelInstitutionalBookingWithPucHash(
        address institutionalProvider,
        bytes32 _reservationKey,
        bytes32 pucHash
    ) external onlyInstitution(institutionalProvider) {
        _cancelInstitutionalBookingWithPucHash(institutionalProvider, _reservationKey, pucHash);
    }

    function _cancelInstitutionalReservationRequest(
        address institutionalProvider,
        bytes32 pucHash,
        bytes32 _reservationKey
    ) internal {
        uint256 labId =
            LibInstitutionalReservation.cancelReservationRequest(institutionalProvider, pucHash, _reservationKey);
        emit ReservationRequestCanceled(_reservationKey, labId);
    }

    function _cancelInstitutionalBookingWithPucHash(
        address institutionalProvider,
        bytes32 _reservationKey,
        bytes32 pucHash
    ) internal {
        uint256 labId = LibInstitutionalReservation.cancelBooking(institutionalProvider, pucHash, _reservationKey);
        emit BookingCanceled(_reservationKey, labId);
    }
}
