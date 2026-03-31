// SPDX-License-Identifier: GPL-3.0-or-later
pragma solidity ^0.8.31;

import {ReentrancyGuardTransient} from "@openzeppelin/contracts/utils/ReentrancyGuardTransient.sol";
import {LibReservationConfirmation} from "../../libraries/LibReservationConfirmation.sol";

/// @title ReservationDenialFacet
/// @notice Denial function for reservation requests (wallet + institutional)
/// @dev Uses provider/backend authorization in LibReservationConfirmation
contract ReservationDenialFacet is ReentrancyGuardTransient {
    function denyReservationRequest(
        bytes32 _reservationKey
    ) external nonReentrant {
        LibReservationConfirmation.denyReservationRequest(_reservationKey);
    }
}
