// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.33;

import "forge-std/Test.sol";
import "../contracts/libraries/LibReservationConfig.sol";

/// @notice Release-gate tests for the timing contract shared with the listeners.
///
/// These are deliberately written against the library used by the production
/// facets. They protect the closed-boundary semantics that an E2E test cannot
/// reliably reproduce without making a five-minute test wait.
contract ReleaseGateReservationWindowTest is Test {
    function test_pending_request_expires_at_exactly_five_minutes() public pure {
        uint256 requestStart = 1_000_000;
        uint256 reservationStart = requestStart + 10 minutes;
        uint256 deadline = requestStart + LibReservationConfig.PENDING_REQUEST_TTL;

        assertEq(LibReservationConfig.PENDING_REQUEST_TTL, 5 minutes);
        assertEq(LibReservationConfig.RESERVATION_CONFIRMATION_LEAD_TIME, 10 minutes);
        assertEq(
            LibReservationConfig.pendingRequestExpiry(
                requestStart,
                LibReservationConfig.PENDING_REQUEST_TTL,
                reservationStart
            ),
            deadline
        );
        assertFalse(
            LibReservationConfig.isPendingRequestExpired(
                requestStart,
                LibReservationConfig.PENDING_REQUEST_TTL,
                reservationStart,
                deadline - 1
            )
        );
        assertTrue(
            LibReservationConfig.isPendingRequestExpired(
                requestStart,
                LibReservationConfig.PENDING_REQUEST_TTL,
                reservationStart,
                deadline
            )
        );
        assertTrue(
            LibReservationConfig.isPendingRequestExpired(
                requestStart,
                LibReservationConfig.PENDING_REQUEST_TTL,
                reservationStart,
                deadline + 1
            )
        );
    }

    function test_reservation_start_is_the_effective_deadline_when_it_is_earlier() public pure {
        uint256 requestStart = 1_000_000;
        uint256 reservationStart = requestStart + 90 seconds;

        assertEq(
            LibReservationConfig.pendingRequestExpiry(requestStart, 5 minutes, reservationStart),
            reservationStart
        );
        assertFalse(
            LibReservationConfig.isPendingRequestExpired(
                requestStart,
                5 minutes,
                reservationStart,
                reservationStart - 1
            )
        );
        assertTrue(
            LibReservationConfig.isPendingRequestExpired(
                requestStart,
                5 minutes,
                reservationStart,
                reservationStart
            )
        );
    }
}
