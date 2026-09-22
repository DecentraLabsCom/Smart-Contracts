// SPDX-License-Identifier: GPL-3.0-or-later
pragma solidity ^0.8.33;

import {AppStorage, Reservation} from "./LibAppStorage.sol";
import {LibHeap} from "./LibHeap.sol";
import {LibInstitutionalReservationSettlement} from "./LibInstitutionalReservationSettlement.sol";

/// @title LibReservationFinalization
/// @notice Bounded traversal of economically finalizable reservation candidates.
library LibReservationFinalization {
    /// @dev The attempt counter bounds work even if a stale heap entry is popped
    ///      but no longer matches the current reservation generation.
    function finalizeEligibleBatch(
        AppStorage storage s,
        uint256 labId,
        uint256 maxAttempts,
        uint256 currentTime
    ) internal returns (uint256 finalized, bool pendingGraceEncountered, bool scanLimitReached) {
        uint256 attempted;
        while (attempted < maxAttempts) {
            (bytes32 key, bool pendingGrace, bool scanLimitReachedThisScan) =
                LibHeap.popEligiblePayoutCandidate(s, labId, currentTime);
            pendingGraceEncountered = pendingGraceEncountered || pendingGrace;
            scanLimitReached = scanLimitReached || scanLimitReachedThisScan;

            // bytes32(0) is the explicit no-candidate sentinel returned by the heap.
            // slither-disable-next-line incorrect-equality
            if (key == bytes32(0)) break;

            unchecked {
                ++attempted;
            }
            Reservation storage reservation = s.reservations[key];
            if (
                LibInstitutionalReservationSettlement.finalizeProviderPayoutReservation(
                        s, key, reservation, labId, currentTime
                    )
                    || LibInstitutionalReservationSettlement.finalizeExpiredReservation(
                        s, key, reservation, labId, currentTime
                    )
            ) {
                unchecked {
                    ++finalized;
                }
            }
        }
    }
}
