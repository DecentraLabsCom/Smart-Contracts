// SPDX-License-Identifier: GPL-3.0-or-later
pragma solidity ^0.8.33;

import {IERC721} from "@openzeppelin/contracts/token/ERC721/IERC721.sol";
import {LibAppStorage, AppStorage, Reservation} from "./LibAppStorage.sol";
import {LibRevenue} from "./LibRevenue.sol";
import {LibReservationCancellation} from "./LibReservationCancellation.sol";
import {LibReputation} from "./LibReputation.sol";
import {LibCreditLedger} from "./LibCreditLedger.sol";

library LibWalletReservationCancellation {
    error ReservationNotFound();
    error OnlyRenter();
    error ReservationNotPending();
    error InvalidBooking();
    error Unauthorized();
    error UseInstitutionalCancel();

    uint8 internal constant _PENDING = 0;
    uint8 internal constant _CONFIRMED = 1;
    uint8 internal constant _IN_USE = 2;

    event ReservationRequestCanceled(bytes32 indexed reservationKey, uint256 indexed tokenId);
    event BookingCanceled(bytes32 indexed reservationKey, uint256 indexed tokenId);

    function cancelReservationRequest(
        bytes32 reservationKey
    ) external {
        AppStorage storage s = LibAppStorage.diamondStorage();
        Reservation storage reservation = s.reservations[reservationKey];
        if (reservation.renter == address(0)) revert ReservationNotFound();
        if (reservation.renter != msg.sender) revert OnlyRenter();
        if (reservation.status != _PENDING) revert ReservationNotPending();

        uint256 labId = reservation.labId;
        LibReservationCancellation.cancelReservation(reservationKey);
        emit ReservationRequestCanceled(reservationKey, labId);
    }

    function cancelBooking(
        bytes32 reservationKey
    ) external {
        AppStorage storage s = LibAppStorage.diamondStorage();
        Reservation storage reservation = s.reservations[reservationKey];

        if (reservation.renter == address(0) || (reservation.status != _CONFIRMED && reservation.status != _IN_USE)) {
            revert InvalidBooking();
        }

        // Institutional reservations must use cancelInstitutionalBookingWithPuc
        if (s.reservationPucHash[reservationKey] != bytes32(0)) {
            revert UseInstitutionalCancel();
        }

        address renter = reservation.renter;
        uint96 price = reservation.price;
        uint256 labId = reservation.labId;

        address currentOwner = IERC721(address(this)).ownerOf(labId);
        bool cancelledByOwner = msg.sender == currentOwner;
        if (renter != msg.sender && !cancelledByOwner) revert Unauthorized();

        uint96 providerFee;
        uint96 treasuryFee;
        uint96 governanceFee;
        uint96 refundAmount = price;

        if (price > 0) {
            (providerFee, treasuryFee, governanceFee, refundAmount) = LibRevenue.computeCancellationFee(price);
        }

        LibReservationCancellation.cancelReservation(reservationKey);

        if (price > 0) {
            // Capture the fee portion from locked credits (consumes lots FIFO)
            uint96 feeTotal = providerFee + treasuryFee + governanceFee;
            if (feeTotal > 0) {
                LibCreditLedger.captureLockedCredits(renter, uint256(feeTotal), reservationKey);
            }
            // Release the refund portion back to available
            if (refundAmount > 0) {
                LibCreditLedger.releaseLockedCredits(renter, uint256(refundAmount), reservationKey);
            }
            LibReservationCancellation.applyCancellationFees(labId, providerFee, treasuryFee, governanceFee, reservationKey);
        } else {
            // No price — just release any locked amount (defensive)
            // Nothing locked for zero-price reservations
        }

        if (cancelledByOwner) {
            LibReputation.recordOwnerCancellation(labId);
        }
        emit BookingCanceled(reservationKey, labId);
    }
}
