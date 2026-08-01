// SPDX-License-Identifier: GPL-3.0-or-later
pragma solidity ^0.8.33;

import {AppStorage, LibAppStorage} from "./LibAppStorage.sol";

/// @title LibReservationIdentity
/// @notice Separates a reusable public slot key from an immutable reservation
///         generation used by economic and historical sidecars.
library LibReservationIdentity {
    /// @notice Return the current generation for a public slot key.
    /// @dev The fallback preserves read/write behavior for reservations created
    ///      before generation storage was introduced.
    function currentReservationId(
        AppStorage storage s,
        bytes32 slotKey
    ) internal view returns (bytes32 reservationId) {
        reservationId = s.reservationIdByKey[slotKey];
        if (reservationId == bytes32(0)) return slotKey;
    }

    /// @notice Return the public slot key associated with a generation.
    /// @dev Unknown ids are treated as legacy keys for upgrade compatibility.
    function reservationKeyForId(
        AppStorage storage s,
        bytes32 reservationId
    ) internal view returns (bytes32 slotKey) {
        slotKey = s.reservationKeyById[reservationId];
        if (slotKey == bytes32(0)) return reservationId;
    }

    /// @notice Resolve a sidecar reference supplied by an old or new caller.
    /// @dev New contract paths pass either a slot key (resolved here) or an
    ///      already-resolved id (which has no slot-key entry and is unchanged).
    function resolveReservationRef(
        AppStorage storage s,
        bytes32 reservationRef
    ) internal view returns (bytes32) {
        bytes32 reservationId = s.reservationIdByKey[reservationRef];
        return reservationId == bytes32(0) ? reservationRef : reservationId;
    }

    /// @notice Create and register a fresh immutable generation for a slot.
    function createReservationId(
        AppStorage storage s,
        bytes32 slotKey
    ) internal returns (bytes32 reservationId) {
        ++s.reservationIdNext;
        reservationId =
            keccak256(abi.encodePacked("DECENTRALABS_RESERVATION_ID_V1", address(this), s.reservationIdNext, slotKey));
        s.reservationIdByKey[slotKey] = reservationId;
        s.reservationKeyById[reservationId] = slotKey;
    }

    /// @notice Store the current record under its immutable generation.
    /// @dev A distinct snapshot is retained for every generation; reusing a
    ///      slot can therefore never overwrite an earlier historical record.
    function snapshotCurrentReservation(
        AppStorage storage s,
        bytes32 slotKey
    ) internal {
        bytes32 reservationId = currentReservationId(s, slotKey);
        s.reservationHistoryById[reservationId] = s.reservations[slotKey];
    }

    /// @notice Convenience resolver for callers that already use Diamond storage.
    function currentReservationId(
        bytes32 slotKey
    ) internal view returns (bytes32) {
        return currentReservationId(LibAppStorage.diamondStorage(), slotKey);
    }
}
