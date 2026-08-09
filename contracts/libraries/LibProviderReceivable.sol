// SPDX-License-Identifier: GPL-3.0-or-later
pragma solidity ^0.8.33;

import {AppStorage, LibAppStorage, Reservation} from "./LibAppStorage.sol";
import {LibReservationIdentity} from "./LibReservationIdentity.sol";

/// @dev Constant representing the hash of the string "SETTLEMENT_OPERATOR_ROLE".
///      This role gates provider payout requests and settlement invalidations.
bytes32 constant SETTLEMENT_OPERATOR_ROLE = keccak256("SETTLEMENT_OPERATOR_ROLE");

/// @dev Role required to approve a submitted provider settlement claim.
bytes32 constant SETTLEMENT_APPROVER_ROLE = keccak256("SETTLEMENT_APPROVER_ROLE");

/// @dev Role required to record payment for an approved provider settlement claim.
bytes32 constant SETTLEMENT_PAYER_ROLE = keccak256("SETTLEMENT_PAYER_ROLE");

/// @title LibProviderReceivable — centralised provider receivable helpers
/// @notice Ensures every accrual is event-linked to its source reservation
///         and provides unsettled-balance queries for transfer guards.
library LibProviderReceivable {
    /// @notice Emitted every time provider receivable is accrued from a reservation
    /// @param labId     The lab whose receivable increased
    /// @param amount    The accrued amount (provider share or cancellation fee)
    /// @param reservationId  The immutable reservation generation that originated the accrual
    event ProviderReceivableAccrued(uint256 indexed labId, uint256 amount, bytes32 indexed reservationId);

    /// @notice Accrue provider receivable and emit a deterministic linkage event
    /// @param labId     Lab token id
    /// @param amount    Provider share to accrue (must be > 0)
    /// @param reservationKey  Source reservation key or generation id
    function accrueReceivable(
        uint256 labId,
        uint256 amount,
        bytes32 reservationKey
    ) internal {
        require(amount > 0, "Receivable amount required");
        AppStorage storage s = LibAppStorage.diamondStorage();
        bytes32 reservationId = LibReservationIdentity.resolveReservationRef(s, reservationKey);
        bytes32 reservationSlot = LibReservationIdentity.reservationKeyForId(s, reservationId);
        if (s.reservationKeyById[reservationId] != bytes32(0)) {
            Reservation storage historicalSource = s.reservationHistoryById[reservationId];
            require(historicalSource.renter != address(0), "Receivable source not found");
            require(historicalSource.labId == labId, "Receivable source lab mismatch");
        } else {
            Reservation storage currentSource = s.reservations[reservationSlot];
            require(currentSource.renter != address(0), "Receivable source not found");
            require(currentSource.labId == labId, "Receivable source lab mismatch");
        }

        s.providerReceivableAccrued[labId] += amount;
        bytes32 accrualLeaf = keccak256(abi.encode(labId, reservationId, amount));
        s.providerReceivableAccruedScopeRoot[labId] =
            keccak256(abi.encode(s.providerReceivableAccruedScopeRoot[labId], accrualLeaf));
        emit ProviderReceivableAccrued(labId, amount, reservationId);
    }

    /// @notice Update the last-accrued timestamp for a lab
    function updateAccruedTimestamp(
        uint256 labId,
        uint256 timestamp
    ) internal {
        AppStorage storage s = LibAppStorage.diamondStorage();
        if (timestamp > s.providerReceivableLastAccruedAt[labId]) {
            s.providerReceivableLastAccruedAt[labId] = timestamp;
        }
    }

    /// @notice Returns true when a lab has any receivable balance that has not
    ///         reached a terminal state (PAID or REVERSED)
    function hasUnsettledReceivable(
        uint256 labId
    ) internal view returns (bool) {
        AppStorage storage s = LibAppStorage.diamondStorage();
        return s.providerReceivableAccrued[labId] > 0 || s.providerSettlementQueue[labId] > 0
            || s.providerReceivableInvoiced[labId] > 0 || s.providerReceivableApproved[labId] > 0
            || s.providerReceivableDisputed[labId] > 0;
    }
}
