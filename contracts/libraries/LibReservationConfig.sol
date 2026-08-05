// SPDX-License-Identifier: GPL-3.0-or-later
pragma solidity ^0.8.31;

library LibReservationConfig {
    /// @notice Global TTL for pending reservation requests (5 minutes)
    /// @dev Providers must observe the request at the configured confirmation
    ///      depth before writing confirmation. If finality is not reached before
    ///      this deadline, the request expires without capturing credits.
    uint256 internal constant PENDING_REQUEST_TTL = 5 minutes;

    /// @notice Minimum lead time between request creation and reservation start.
    /// @dev The ten-minute lead leaves a five-minute safety margin after the
    ///      pending decision window. Marketplace validation mirrors this value.
    uint256 internal constant RESERVATION_CONFIRMATION_LEAD_TIME = 10 minutes;

    /// @notice Returns the effective deadline for deciding a pending request.
    /// @dev A provider cannot confirm after the requested service window starts,
    ///      even when the ordinary pending-request TTL has not elapsed.
    function pendingRequestExpiry(
        uint256 requestPeriodStart,
        uint256 requestPeriodDuration,
        uint256 reservationStart
    ) internal pure returns (uint256) {
        uint256 ttlExpiry = requestPeriodStart + requestPeriodDuration;
        return ttlExpiry < reservationStart ? ttlExpiry : reservationStart;
    }

    function isPendingRequestExpired(
        uint256 requestPeriodStart,
        uint256 requestPeriodDuration,
        uint256 reservationStart,
        uint256 currentTime
    ) internal pure returns (bool) {
        return currentTime >= pendingRequestExpiry(requestPeriodStart, requestPeriodDuration, reservationStart);
    }

    /// @notice Economic grace period for provider session attestations after a reservation ends.
    /// @dev This is the single deadline used by session submission and permissionless finalization.
    uint256 internal constant SESSION_ATTESTATION_GRACE = 1 days;

    function sessionAttestationDeadline(
        uint32 reservationEnd
    ) internal pure returns (uint256) {
        return uint256(reservationEnd) + SESSION_ATTESTATION_GRACE;
    }

    function isWithinSessionAttestationGrace(
        uint32 reservationEnd,
        uint256 currentTime
    ) internal pure returns (bool) {
        return currentTime <= sessionAttestationDeadline(reservationEnd);
    }
}
