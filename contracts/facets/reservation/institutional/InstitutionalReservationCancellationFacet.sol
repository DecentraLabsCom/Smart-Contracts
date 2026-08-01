// SPDX-License-Identifier: GPL-3.0-or-later
pragma solidity ^0.8.31;

import {EnumerableSet} from "@openzeppelin/contracts/utils/structs/EnumerableSet.sol";
import {ReentrancyGuardTransient} from "@openzeppelin/contracts/utils/ReentrancyGuardTransient.sol";
import {
    LibAppStorage,
    AppStorage,
    INSTITUTION_ROLE,
    CreditReservationAllocation,
    Reservation
} from "../../../libraries/LibAppStorage.sol";
import {LibInstitutionalReservation} from "../../../libraries/LibInstitutionalReservation.sol";
import {LibRevenue} from "../../../libraries/LibRevenue.sol";
import {LibReservationIdentity} from "../../../libraries/LibReservationIdentity.sol";

/// @title InstitutionalReservationCancellationFacet
/// @author Luis de la Torre Cubillo, Juan Luis Ramos Villalón
/// @notice Cancellation functions for institutional reservations

contract InstitutionalReservationCancellationFacet is ReentrancyGuardTransient {
    using EnumerableSet for EnumerableSet.AddressSet;

    uint8 internal constant CANCELLATION_POLICY_VERSION = 2;

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
    event ReservationCancellationByGeneration(
        bytes32 indexed reservationId, bytes32 indexed reservationKey, uint256 indexed tokenId, uint8 reasonCode
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

    /// @notice Returns the exact cancellation accounting that the current contract would apply.
    /// @dev This is deliberately sourced from the reservation and credit-lot ledger so the
    ///      confirmation UI cannot silently diverge from the cancellation transaction.
    function previewInstitutionalBookingCancellation(
        bytes32 reservationKey
    )
        external
        view
        returns (
            uint8 reservationStatus,
            bool cancellable,
            address refundDestination,
            uint96 price,
            uint96 totalFee,
            uint96 providerFee,
            uint96 refundAmount,
            uint32 cancellationCutoff,
            uint256 spendingPeriodStart,
            uint256 spendingPeriodEnd,
            uint48 sourceCreditExpiry,
            CreditReservationAllocation[] memory allocations,
            uint8 policyVersion
        )
    {
        AppStorage storage s = _s();
        Reservation storage reservation = s.reservations[reservationKey];
        bytes32 reservationId = LibReservationIdentity.currentReservationId(s, reservationKey);

        reservationStatus = reservation.status;
        refundDestination = reservation.payerInstitution;
        price = reservation.price;
        cancellationCutoff = reservation.start;
        policyVersion = CANCELLATION_POLICY_VERSION;
        // Cancellation eligibility is intentionally evaluated against chain time.
        // slither-disable-next-line timestamp
        cancellable = reservationStatus == 1 && block.timestamp < cancellationCutoff;

        if (reservationStatus == 1 && s.labs[reservation.labId].resourceType == 0) {
            uint96 calculatedRefund;
            (providerFee, calculatedRefund) = LibRevenue.computeCancellationFee(price);
            refundAmount = calculatedRefund;
            totalFee = price - refundAmount;
        } else if (reservationStatus == 1) {
            refundAmount = price;
        } else {
            refundAmount = 0;
        }

        uint256 periodStartPlusOne = s.institutionalReservationPeriodStartPlusOne[reservationId];
        if (periodStartPlusOne != 0) {
            spendingPeriodStart = periodStartPlusOne - 1;
            uint256 duration = s.institutionalSpendingPeriod[reservation.payerInstitution];
            if (duration == 0) duration = LibAppStorage.DEFAULT_SPENDING_PERIOD;
            spendingPeriodEnd = spendingPeriodStart + duration;
        }

        sourceCreditExpiry = s.creditReservationExpiry[reservation.payerInstitution][reservationId];
        // The preview is intentionally a bounded summary. Source-lot
        // provenance remains available through the paginated credit-ledger
        // getter, so a reservation with many allocations cannot make one
        // eth_call copy an unbounded array into memory.
        allocations = new CreditReservationAllocation[](0);
    }

    /// @notice Cancel a confirmed booking because the provider cannot honor it.
    /// @dev Refunds the full institutional price and applies the reason/notice-based
    ///      provider reputation penalty enforced by LibInstitutionalReservation.
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
        emit ReservationCancellationByGeneration(
            LibReservationIdentity.currentReservationId(_s(), reservationKey), reservationKey, labId, reasonCode
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
        emit ReservationCancellationByGeneration(
            LibReservationIdentity.currentReservationId(_s(), _reservationKey), _reservationKey, labId, 0
        );
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
        emit ReservationCancellationByGeneration(
            LibReservationIdentity.currentReservationId(_s(), _reservationKey), _reservationKey, labId, 0
        );
    }
}
