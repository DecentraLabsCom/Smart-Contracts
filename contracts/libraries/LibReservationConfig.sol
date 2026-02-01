// SPDX-License-Identifier: GPL-3.0-or-later
pragma solidity ^0.8.31;

library LibReservationConfig {
    /// @notice Global TTL for pending reservation requests (5 minutes)
    uint256 internal constant PENDING_REQUEST_TTL = 5 minutes;
}
