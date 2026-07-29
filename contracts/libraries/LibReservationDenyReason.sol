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
///  6 = PROVIDER_TECHNICAL_FAILURE (automatic processing failed technically)
///  7 = PROVIDER_UNAVAILABLE (metadata/configuration or provider availability)
///  8 = PROVIDER_SERVICE_FAILURE (the provider explicitly reports that the
///      confirmed service was not delivered; applies a -3 reputation penalty)
///  9+ = provider cancellation reason codes (the provider supplies a non-zero
///      code so the cancellation remains classifiable without changing the ABI)
///  255 = UNKNOWN (fallback)
library LibReservationDenyReason {
    uint8 internal constant PROVIDER_MANUAL = 1;
    uint8 internal constant PROVIDER_NOT_ELIGIBLE = 2;
    uint8 internal constant PAYMENT_FAILED = 3;
    uint8 internal constant REQUEST_EXPIRED = 4;
    uint8 internal constant TREASURY_SPEND_FAILED = 5;
    uint8 internal constant PROVIDER_TECHNICAL_FAILURE = 6;
    uint8 internal constant PROVIDER_UNAVAILABLE = 7;
    uint8 internal constant PROVIDER_SERVICE_FAILURE = 8;
    uint8 internal constant UNKNOWN = 255;
}
