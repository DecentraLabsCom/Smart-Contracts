// SPDX-License-Identifier: GPL-3.0-or-later
pragma solidity ^0.8.31;

library LibReservationConfig {
    /// @notice Global TTL for pending reservation requests (5 minutes)
    uint256 internal constant PENDING_REQUEST_TTL = 5 minutes;

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
