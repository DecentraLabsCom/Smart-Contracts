// SPDX-License-Identifier: GPL-3.0-or-later
pragma solidity ^0.8.31;

import {ReentrancyGuardTransient} from "@openzeppelin/contracts/utils/ReentrancyGuardTransient.sol";
import {LibWalletReservationCancellation} from "../../../libraries/LibWalletReservationCancellation.sol";

/// @title WalletReservationCancellationFacet
/// @author Luis de la Torre Cubillo, Juan Luis Ramos Villalón
/// @notice Cancellation functions for wallet reservations
/// @dev Extracted from WalletReservationFacet to reduce contract size below EIP-170 limit

contract WalletReservationCancellationFacet is ReentrancyGuardTransient {
    function cancelReservationRequest(
        bytes32 _reservationKey
    ) external {
        LibWalletReservationCancellation.cancelReservationRequest(_reservationKey);
    }

    function cancelBooking(
        bytes32 _reservationKey
    ) external nonReentrant {
        LibWalletReservationCancellation.cancelBooking(_reservationKey);
    }
}
