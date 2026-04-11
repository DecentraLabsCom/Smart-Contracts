// SPDX-License-Identifier: GPL-3.0-or-later
pragma solidity ^0.8.33;

import {AppStorage, LibAppStorage} from "./LibAppStorage.sol";

/// @dev Constant representing the hash of the string "SETTLEMENT_OPERATOR_ROLE".
///      This role gates write access to provider receivable lifecycle transitions.
bytes32 constant SETTLEMENT_OPERATOR_ROLE = keccak256("SETTLEMENT_OPERATOR_ROLE");

/// @title LibProviderReceivable — centralised provider receivable helpers
/// @notice Ensures every accrual is event-linked to its source reservation
///         and provides unsettled-balance queries for transfer guards.
library LibProviderReceivable {
    /// @notice Emitted every time provider receivable is accrued from a reservation
    /// @param labId     The lab whose receivable increased
    /// @param amount    The accrued amount (provider share or cancellation fee)
    /// @param reservationKey  The reservation key that originated the accrual
    event ProviderReceivableAccrued(uint256 indexed labId, uint256 amount, bytes32 indexed reservationKey);

    /// @notice Accrue provider receivable and emit a deterministic linkage event
    /// @param labId     Lab token id
    /// @param amount    Provider share to accrue (must be > 0)
    /// @param reservationKey  Source reservation key for audit linkage
    function accrueReceivable(
        uint256 labId,
        uint256 amount,
        bytes32 reservationKey
    ) internal {
        AppStorage storage s = LibAppStorage.diamondStorage();
        s.providerReceivableAccrued[labId] += amount;
        emit ProviderReceivableAccrued(labId, amount, reservationKey);
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
