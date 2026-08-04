// SPDX-License-Identifier: GPL-3.0-or-later
pragma solidity ^0.8.31;

import {EnumerableSet} from "@openzeppelin/contracts/utils/structs/EnumerableSet.sol";
import {LibAppStorage, AppStorage, Reservation, INSTITUTION_ROLE} from "./LibAppStorage.sol";
import {LibTracking} from "./LibTracking.sol";
import {LibReservationCancellation} from "./LibReservationCancellation.sol";
import {LibReservationConfig} from "./LibReservationConfig.sol";
import {LibInstitutionalReservationSettlement} from "./LibInstitutionalReservationSettlement.sol";

library LibInstitutionalReservationRelease {
    using EnumerableSet for EnumerableSet.Bytes32Set;
    using EnumerableSet for EnumerableSet.AddressSet;

    error InvalidBatchSize();
    error InvalidPucHash();
    error UnknownInstitution();

    uint8 internal constant _PENDING = 0;
    uint256 internal constant _PENDING_REQUEST_TTL = LibReservationConfig.PENDING_REQUEST_TTL;

    /// @notice Finalize expired reservations for an institutional user.
    /// @dev Permissionless by design: refunds and provider receivable accruals are
    ///      determined from the reservation state, so they do not depend on the
    ///      payer institution's backend remaining available or cooperating.
    function releaseInstitutionalExpiredReservations(
        address institutionalProvider,
        bytes32 pucHash,
        uint256 labId,
        uint256 maxBatch
    ) external returns (uint256 processed) {
        AppStorage storage s = LibAppStorage.diamondStorage();
        if (!s.roleMembers[INSTITUTION_ROLE].contains(institutionalProvider)) revert UnknownInstitution();

        if (maxBatch == 0 || maxBatch > 50) revert InvalidBatchSize();
        if (pucHash == bytes32(0)) revert InvalidPucHash();

        address trackingKey = LibTracking.trackingKeyFromInstitutionHash(institutionalProvider, pucHash);
        return _releaseExpiredReservationsInternal(s, labId, trackingKey, maxBatch);
    }

    function _releaseExpiredReservationsInternal(
        AppStorage storage s,
        uint256 labId,
        address trackingKey,
        uint256 maxBatch
    ) private returns (uint256 processed) {
        EnumerableSet.Bytes32Set storage userReservations = s.reservationKeysByTokenAndUser[labId][trackingKey];
        uint256 len = userReservations.length();
        uint256 i = 0;
        uint256 currentTime = block.timestamp;

        while (i < len && processed < maxBatch) {
            bytes32 key = userReservations.at(i);
            Reservation storage reservation = s.reservations[key];

            if (LibInstitutionalReservationSettlement.finalizeExpiredReservation(
                    s, key, reservation, labId, currentTime
                )) {
                len = userReservations.length();
                unchecked {
                    ++processed;
                }
                continue;
            }
            if (reservation.status == _PENDING) {
                uint256 ttl = reservation.requestPeriodDuration;
                if (ttl == 0) ttl = _PENDING_REQUEST_TTL;
                bool expired = reservation.requestPeriodStart == 0
                    || LibReservationConfig.isPendingRequestExpired(
                        reservation.requestPeriodStart, ttl, reservation.start, currentTime
                    );
                if (expired) {
                    LibReservationCancellation.cancelReservation(key);
                    len = userReservations.length();
                    unchecked {
                        ++processed;
                    }
                    continue;
                }
            }
            unchecked {
                ++i;
            }
        }

        return processed;
    }
}
