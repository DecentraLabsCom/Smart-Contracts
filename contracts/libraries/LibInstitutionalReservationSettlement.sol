// SPDX-License-Identifier: GPL-3.0-or-later
pragma solidity ^0.8.33;

import {EnumerableSet} from "@openzeppelin/contracts/utils/structs/EnumerableSet.sol";
import {AppStorage, Reservation} from "./LibAppStorage.sol";
import {LibHeap} from "./LibHeap.sol";
import {LibProviderReceivable} from "./LibProviderReceivable.sol";
import {LibReputation} from "./LibReputation.sol";
import {LibRevenue} from "./LibRevenue.sol";
import {LibReservationConfig} from "./LibReservationConfig.sol";
import {LibReservationIndexCleanup} from "./LibReservationIndexCleanup.sol";
import {LibReservationIdentity} from "./LibReservationIdentity.sol";
import {LibCreditLedger} from "./LibCreditLedger.sol";

interface IInstitutionalTreasuryFacetSettlement {
    function refundToInstitutionalTreasuryForReservation(
        address provider,
        bytes32 pucHash,
        bytes32 reservationKey,
        uint256 amount
    ) external;
}

/// @title LibInstitutionalReservationSettlement
/// @notice Single economic finalization path for institutional reservations.
/// @dev Every route must check eligibility through this library and then use the
///      same finalizer so deadline, refund/receivable, reputation, counters,
///      heap and index transitions cannot diverge.
library LibInstitutionalReservationSettlement {
    using EnumerableSet for EnumerableSet.Bytes32Set;

    uint8 internal constant _CONFIRMED = 1;
    uint8 internal constant _ACCESS_AUTHORIZED = 2;
    uint8 internal constant _SETTLED = 3;

    /// @notice Returns whether a reservation may leave the active lifecycle now.
    /// @dev An access-authorized reservation without SessionStarted evidence is
    ///      deliberately held until the configured attestation deadline.
    function isEconomicallyExpired(
        AppStorage storage s,
        Reservation storage reservation,
        bytes32 key,
        uint256 currentTime
    ) internal view returns (bool) {
        bytes32 reservationId = LibReservationIdentity.currentReservationId(s, key);
        if (s.emergencyCheckInReviews[reservationId].settlementExcluded) {
            return false;
        }
        if (reservation.status == _CONFIRMED) {
            return reservation.end < currentTime;
        }
        if (reservation.status != _ACCESS_AUTHORIZED) {
            return false;
        }

        if (s.reservationSessionStartedRecorded[reservationId]) {
            return reservation.end < currentTime;
        }

        return currentTime > LibReservationConfig.sessionAttestationDeadline(reservation.end);
    }

    /// @notice Returns whether provider payout may finalize an attested session.
    function isProviderPayoutEligible(
        AppStorage storage s,
        bytes32 key,
        Reservation storage reservation,
        uint256 labId,
        uint256 currentTime
    ) internal view returns (bool) {
        bytes32 reservationId = LibReservationIdentity.currentReservationId(s, key);
        return reservation.labId == labId && reservation.status == _ACCESS_AUTHORIZED
            && !s.emergencyCheckInReviews[reservationId].settlementExcluded
            && s.reservationSessionStartedRecorded[reservationId] && reservation.end < currentTime;
    }

    /// @dev Applies the complete refund/receivable and lifecycle transition.
    ///      This is private so no production route can bypass the common path.
    function _finalizeReservation(
        AppStorage storage s,
        bytes32 key,
        Reservation storage reservation,
        uint256 labId
    ) private {
        bytes32 reservationId = LibReservationIdentity.currentReservationId(s, key);
        uint8 previousStatus = reservation.status;
        bool sessionStartedRecorded = s.reservationSessionStartedRecorded[reservationId];

        LibHeap.removePayoutCandidates(s, labId, key);
        s.activeConcurrentReservationKeysByLab[labId].remove(reservationId);
        if (sessionStartedRecorded) {
            if (reservation.providerShare > 0) {
                LibProviderReceivable.accrueReceivable(labId, reservation.providerShare, key);
                LibProviderReceivable.updateAccruedTimestamp(labId, block.timestamp);
            }
        } else if (reservation.price > 0) {
            uint96 providerFee;
            uint96 refundAmount = reservation.price;
            if (s.labs[labId].resourceType == 0) {
                (providerFee, refundAmount) = LibRevenue.computeNoShowSettlement(reservation.price);
                if (providerFee > 0) {
                    LibProviderReceivable.accrueReceivable(labId, providerFee, key);
                    LibProviderReceivable.updateAccruedTimestamp(labId, block.timestamp);
                }
            }
            if (refundAmount > 0) {
                IInstitutionalTreasuryFacetSettlement(address(this))
                    .refundToInstitutionalTreasuryForReservation(
                        reservation.payerInstitution, s.reservationPucHash[reservationId], key, refundAmount
                    );
            }
        }

        LibCreditLedger.finalizeReservationCreditAllocations(reservation.payerInstitution, reservationId);

        reservation.status = _SETTLED;
        LibReservationIdentity.snapshotCurrentReservation(s, key);
        if (previousStatus == _ACCESS_AUTHORIZED && sessionStartedRecorded) {
            LibReputation.recordCompletion(labId);
        }
        if (previousStatus == _CONFIRMED || previousStatus == _ACCESS_AUTHORIZED) {
            if (s.labActiveReservationCount[labId] > 0) s.labActiveReservationCount[labId]--;
            if (s.providerActiveReservationCount[reservation.labProvider] > 0) {
                s.providerActiveReservationCount[reservation.labProvider]--;
            }
        }
        LibReservationIndexCleanup.removeFinalizedReservationIndexes(s, key, reservation);
        if (s.totalReservationsCount > 0) s.totalReservationsCount--;
    }

    /// @notice Finalizes a reservation only when the full economic deadline passed.
    function finalizeExpiredReservation(
        AppStorage storage s,
        bytes32 key,
        Reservation storage reservation,
        uint256 labId,
        uint256 currentTime
    ) internal returns (bool) {
        if (reservation.labId != labId || !isEconomicallyExpired(s, reservation, key, currentTime)) return false;
        _finalizeReservation(s, key, reservation, labId);
        return true;
    }

    /// @notice Finalizes an attested session for provider payout.
    function finalizeProviderPayoutReservation(
        AppStorage storage s,
        bytes32 key,
        Reservation storage reservation,
        uint256 labId,
        uint256 currentTime
    ) internal returns (bool) {
        if (!isProviderPayoutEligible(s, key, reservation, labId, currentTime)) return false;
        _finalizeReservation(s, key, reservation, labId);
        return true;
    }
}
