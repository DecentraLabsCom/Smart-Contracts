// SPDX-License-Identifier: GPL-3.0-or-later
pragma solidity ^0.8.31;

import {ReentrancyGuardTransient} from "@openzeppelin/contracts/utils/ReentrancyGuardTransient.sol";
import {LibReservationConfirmation} from "../../libraries/LibReservationConfirmation.sol";

/// @title ReservationDenialFacet
/// @notice Denial function for reservation requests.
/// @dev Uses provider/backend authorization in LibReservationConfirmation
contract ReservationDenialFacet is ReentrancyGuardTransient {
    function denyReservationRequest(
        bytes32 _reservationKey
    ) external nonReentrant {
        LibReservationConfirmation.denyReservationRequest(_reservationKey);
    }

    /// @notice Denies a pending request while preserving the operational reason
    ///      used by automated provider processing.
    function denyReservationRequestWithReason(
        bytes32 _reservationKey,
        uint8 _reason
    ) external nonReentrant {
        LibReservationConfirmation.denyReservationRequestWithReason(_reservationKey, _reason);
    }
}
