// SPDX-License-Identifier: GPL-3.0-or-later
pragma solidity ^0.8.31;

import {EnumerableSet} from "@openzeppelin/contracts/utils/structs/EnumerableSet.sol";
import {ReentrancyGuardTransient} from "@openzeppelin/contracts/utils/ReentrancyGuardTransient.sol";
import {LibAppStorage, AppStorage, INSTITUTION_ROLE} from "../../../libraries/LibAppStorage.sol";
import {LibInstitutionalReservation} from "../../../libraries/LibInstitutionalReservation.sol";

/// @title InstitutionalReservationCancellationFacet
/// @author Luis de la Torre Cubillo, Juan Luis Ramos Villalón
/// @notice Cancellation functions for institutional reservations

contract InstitutionalReservationCancellationFacet is ReentrancyGuardTransient {
    using EnumerableSet for EnumerableSet.AddressSet;

    event ReservationRequestCanceled(bytes32 indexed reservationKey, uint256 indexed tokenId);
    event BookingCanceled(bytes32 indexed reservationKey, uint256 indexed tokenId);
    event BookingCanceledByProvider(
        bytes32 indexed reservationKey,
        uint256 indexed tokenId,
        address indexed payerInstitution,
        address provider,
        bytes32 pucHash,
        uint96 refundAmount,
        uint8 reasonCode
    );

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

    /// @notice Cancel a confirmed booking because the provider cannot honor it.
    /// @dev Refunds the full institutional price and applies a minimal reputation penalty.
    function cancelConfirmedBookingByProvider(
        bytes32 reservationKey,
        uint8 reasonCode
    )
        external
        nonReentrant
        returns (uint256 labId, address payerInstitution, address provider, bytes32 pucHash, uint96 refundAmount)
    {
        (labId, payerInstitution, provider, pucHash, refundAmount) =
            LibInstitutionalReservation.cancelConfirmedBookingByProvider(reservationKey, reasonCode);
        emit BookingCanceledByProvider(
            reservationKey, labId, payerInstitution, provider, pucHash, refundAmount, reasonCode
        );
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

    // The reservation library completes the Diamond state transition before this audit event.
    // slither-disable-next-line reentrancy-events
    function _cancelInstitutionalBookingWithPucHash(
        address institutionalProvider,
        bytes32 _reservationKey,
        bytes32 pucHash
    ) internal {
        uint256 labId = LibInstitutionalReservation.cancelBooking(institutionalProvider, pucHash, _reservationKey);
        emit BookingCanceled(_reservationKey, labId);
    }
}
