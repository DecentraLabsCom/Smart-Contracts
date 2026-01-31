// SPDX-License-Identifier: GPL-3.0-or-later
pragma solidity ^0.8.31;

import {ReentrancyGuardTransient} from "@openzeppelin/contracts/utils/ReentrancyGuardTransient.sol";
import {LibWalletReservationConfirmation} from "../../libraries/LibWalletReservationConfirmation.sol";

/// @title ReservationDenialFacet
/// @notice Denial function for reservation requests (wallet + institutional)
/// @dev Uses provider/backend authorization in LibWalletReservationConfirmation
contract ReservationDenialFacet is ReentrancyGuardTransient {
    function denyReservationRequest(
        bytes32 _reservationKey
    ) external nonReentrant {
        LibWalletReservationConfirmation.denyReservationRequest(_reservationKey);
    }
}
