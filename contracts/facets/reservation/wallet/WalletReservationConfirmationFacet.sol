// SPDX-License-Identifier: GPL-3.0-or-later
pragma solidity ^0.8.31;

import {ReentrancyGuardTransient} from "@openzeppelin/contracts/utils/ReentrancyGuardTransient.sol";
import {LibWalletReservationConfirmation} from "../../../libraries/LibWalletReservationConfirmation.sol";

/// @title WalletReservationConfirmationFacet
/// @author Luis de la Torre Cubillo, Juan Luis Ramos Villalón
/// @notice Confirmation and denial functions for wallet reservations
/// @dev Extracted from WalletReservationCoreFacet to reduce contract size below EIP-170 limit

contract WalletReservationConfirmationFacet is ReentrancyGuardTransient {
    function confirmReservationRequest(
        bytes32 _reservationKey
    ) external nonReentrant {
        LibWalletReservationConfirmation.confirmReservationRequest(_reservationKey);
    }
}
