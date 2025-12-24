// SPDX-License-Identifier: GPL-3.0-or-later
pragma solidity ^0.8.31;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {IERC721} from "@openzeppelin/contracts/token/ERC721/IERC721.sol";
import {EnumerableSet} from "@openzeppelin/contracts/utils/structs/EnumerableSet.sol";
import {ReentrancyGuardTransient} from "@openzeppelin/contracts/utils/ReentrancyGuardTransient.sol";
import {BaseWalletReservationFacet, IInstitutionalTreasuryFacetW} from "../base/BaseWalletReservationFacet.sol";
import {AppStorage, Reservation} from "../../../libraries/LibAppStorage.sol";
import {LibReputation} from "../../../libraries/LibReputation.sol";

/// @title WalletCancellationFacet
/// @author Luis de la Torre Cubillo, Juan Luis Ramos Villalón
/// @notice Cancellation functions for wallet reservations
/// @dev Extracted from WalletReservationFacet to reduce contract size below EIP-170 limit

contract WalletCancellationFacet is BaseWalletReservationFacet, ReentrancyGuardTransient {
    using SafeERC20 for IERC20;
    using EnumerableSet for EnumerableSet.Bytes32Set;

    function cancelReservationRequest(bytes32 _reservationKey) external override {
        _cancelReservationRequest(_reservationKey);
    }

    function cancelBooking(bytes32 _reservationKey) external override nonReentrant {
        _cancelBooking(_reservationKey);
    }

    function _cancelReservationRequest(bytes32 _reservationKey) internal override {
        Reservation storage reservation = _s().reservations[_reservationKey];
        if (reservation.renter == address(0)) revert("Not found");
        if (reservation.renter != msg.sender) revert("Only the renter");
        if (reservation.status != _PENDING) revert("Not pending");
    
        _cancelReservation(_reservationKey);
        emit ReservationRequestCanceled(_reservationKey, reservation.labId);
    }

    function _cancelBooking(bytes32 _reservationKey) internal override {
        AppStorage storage s = _s();
        Reservation storage reservation = s.reservations[_reservationKey];
        
        if (reservation.renter == address(0) || 
            (reservation.status != _CONFIRMED && reservation.status != _IN_USE)) 
            revert("Invalid");
    
        address renter = reservation.renter;
        uint96 price = reservation.price;
        uint256 labId = reservation.labId;
        string memory puc = reservation.puc;
        bool isInstitutional = bytes(puc).length > 0;
        uint96 providerFee;
        uint96 treasuryFee;
        uint96 governanceFee;
        uint96 refundAmount = price;
        
        if (price > 0) {
            (providerFee, treasuryFee, governanceFee, refundAmount) = _computeCancellationFee(price);
        }
        
        address currentOwner = IERC721(address(this)).ownerOf(labId);
        bool cancelledByOwner = msg.sender == currentOwner;
        if (renter != msg.sender && !cancelledByOwner) revert("Unauthorized");
    
        _cancelReservation(_reservationKey);

        if (price > 0) {
            _applyCancellationFees(s, labId, providerFee, treasuryFee, governanceFee);
        }

        if (cancelledByOwner) {
            LibReputation.recordOwnerCancellation(labId);
        }
        
        if (isInstitutional && reservation.payerInstitution != address(0)) {
            IInstitutionalTreasuryFacetW(address(this)).refundToInstitutionalTreasury(
                reservation.payerInstitution,
                puc,
                refundAmount
            );
        } else {
            IERC20(s.labTokenAddress).safeTransfer(renter, refundAmount);
        }
        
        emit BookingCanceled(_reservationKey, labId);
    }
}
