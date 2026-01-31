// SPDX-License-Identifier: GPL-3.0-or-later
pragma solidity ^0.8.33;

/// @title LibReservationDenyReason
/// @notice Reason codes for ReservationRequestDenied events (uint8).
/// @dev Mapping:
///  1 = PROVIDER_MANUAL (provider/backend/manual denial)
///  2 = PROVIDER_NOT_ELIGIBLE (provider cannot fulfill: unlisted/insufficient stake)
///  3 = PAYMENT_FAILED (wallet transferFrom failed)
///  4 = REQUEST_EXPIRED (institutional request period expired)
///  5 = TREASURY_SPEND_FAILED (institutional treasury spend failed)
///  255 = UNKNOWN (fallback)
library LibReservationDenyReason {
    uint8 internal constant PROVIDER_MANUAL = 1;
    uint8 internal constant PROVIDER_NOT_ELIGIBLE = 2;
    uint8 internal constant PAYMENT_FAILED = 3;
    uint8 internal constant REQUEST_EXPIRED = 4;
    uint8 internal constant TREASURY_SPEND_FAILED = 5;
    uint8 internal constant UNKNOWN = 255;
}
