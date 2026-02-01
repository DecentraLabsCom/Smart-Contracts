// SPDX-License-Identifier: GPL-3.0-or-later
pragma solidity ^0.8.33;

import {EnumerableSet} from "@openzeppelin/contracts/utils/structs/EnumerableSet.sol";
import {RivalIntervalTreeLibrary, Tree} from "./RivalIntervalTreeLibrary.sol";
import {LibAppStorage, AppStorage, Reservation, PastReservationBuffer} from "./LibAppStorage.sol";
import {LibRevenue} from "./LibRevenue.sol";
import {LibReputation} from "./LibReputation.sol";
import {LibReservationCancellation} from "./LibReservationCancellation.sol";

library LibWalletRelease {
    using EnumerableSet for EnumerableSet.Bytes32Set;
    using RivalIntervalTreeLibrary for Tree;

    event ReservationsReleased(address indexed user, uint256 indexed tokenId, uint256 count);

    uint8 internal constant _PENDING = 0;
    uint8 internal constant _CONFIRMED = 1;
    uint8 internal constant _IN_USE = 2;
    uint8 internal constant _COMPLETED = 3;
    uint8 internal constant _COLLECTED = 4;
    uint8 internal constant _CANCELLED = 5;

    uint256 internal constant _PENDING_REQUEST_TTL = 1 hours;
    uint8 internal constant _TOKEN_BUFFER_CAP = 40;
    uint8 internal constant _USER_BUFFER_CAP = 20;

    function releaseExpiredReservations(
        uint256 labId,
        address user,
        uint256 maxBatch
    ) external returns (uint256 processed) {
        if (msg.sender != user) revert("Only user can release their quota");
        if (maxBatch == 0 || maxBatch > 50) revert("Invalid batch size");

        AppStorage storage s = LibAppStorage.diamondStorage();
        EnumerableSet.Bytes32Set storage userReservations = s.reservationKeysByTokenAndUser[labId][user];
        uint256 len = userReservations.length();
        uint256 i;
        uint256 currentTime = block.timestamp;

        while (i < len && processed < maxBatch) {
            bytes32 key = userReservations.at(i);
            Reservation storage reservation = s.reservations[key];

            if (reservation.end < currentTime && reservation.status == _CONFIRMED) {
                _finalizeReservationForPayout(s, key, reservation, labId);
                len = userReservations.length();
                unchecked {
                    ++processed;
                }
                continue;
            }
            if (reservation.status == _PENDING) {
                uint256 ttl = reservation.requestPeriodDuration;
                if (ttl == 0) ttl = _PENDING_REQUEST_TTL;
                bool expired =
                    reservation.requestPeriodStart == 0 || currentTime >= reservation.requestPeriodStart + ttl;
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

        if (processed > 0) {
            emit ReservationsReleased(user, labId, processed);
        }
        return processed;
    }

    function _finalizeReservationForPayout(
        AppStorage storage s,
        bytes32 key,
        Reservation storage reservation,
        uint256 labId
    ) private returns (bool) {
        if (reservation.status == _COLLECTED || reservation.status == _CANCELLED) return false;

        address trackingKey = reservation.renter;
        uint256 reservationPrice = reservation.price;

        if (reservation.status == _CONFIRMED || reservation.status == _IN_USE) {
            _removeReservationFromCalendar(s, labId, reservation.start);
        }

        if (_isActiveReservationStatus(reservation.status)) {
            _decrementActiveReservationCounters(s, reservation);
        }

        uint8 previousStatus = reservation.status;
        reservation.status = _COLLECTED;
        if (previousStatus == _IN_USE) {
            LibReputation.recordCompletion(labId);
        }

        if (reservationPrice > 0) {
            _creditRevenueBuckets(s, reservation);
        }

        _recordPast(s, labId, trackingKey, key, reservation.end);

        s.reservationKeysByToken[labId].remove(key);
        s.renters[reservation.renter].remove(key);
        if (s.totalReservationsCount > 0) s.totalReservationsCount--;

        if (s.activeReservationCountByTokenAndUser[labId][trackingKey] > 0) {
            s.activeReservationCountByTokenAndUser[labId][trackingKey]--;
        }
        s.reservationKeysByTokenAndUser[labId][trackingKey].remove(key);

        if (s.activeReservationByTokenAndUser[labId][trackingKey] == key) {
            bytes32 nextKey = _findNextEarliestReservation(s, labId, trackingKey);
            s.activeReservationByTokenAndUser[labId][trackingKey] = nextKey;
        }

        if (s.payoutHeapContains[key]) s.payoutHeapContains[key] = false;

        return true;
    }

    function _updatePendingProviderTimestamp(
        AppStorage storage s,
        uint256 labId,
        uint256 timestamp
    ) private {
        if (timestamp > s.pendingProviderLastUpdated[labId]) {
            s.pendingProviderLastUpdated[labId] = timestamp;
        }
    }

    function _creditRevenueBuckets(
        AppStorage storage s,
        Reservation storage reservation
    ) private {
        uint96 providerShare = reservation.providerShare;
        uint96 treasuryShare = reservation.projectTreasuryShare;
        uint96 subsidiesShare = reservation.subsidiesShare;
        uint96 governanceShare = reservation.governanceShare;

        if (providerShare > 0) {
            s.pendingProviderPayout[reservation.labId] += providerShare;
            _updatePendingProviderTimestamp(s, reservation.labId, reservation.end);
        }
        if (treasuryShare > 0) s.pendingProjectTreasury += treasuryShare;
        if (subsidiesShare > 0) s.pendingSubsidies += subsidiesShare;
        if (governanceShare > 0) s.pendingGovernance += governanceShare;
    }

    function _recordPast(
        AppStorage storage s,
        uint256 labId,
        address userTrackingKey,
        bytes32 reservationKey,
        uint32 endTime
    ) private {
        _insertPast(s.pastReservationsByToken[labId], reservationKey, endTime, _TOKEN_BUFFER_CAP);
        _insertPast(s.pastReservationsByTokenAndUser[labId][userTrackingKey], reservationKey, endTime, _USER_BUFFER_CAP);
    }

    function _insertPast(
        PastReservationBuffer storage buf,
        bytes32 key,
        uint32 endTime,
        uint8 cap
    ) private {
        uint8 size = buf.size;
        if (size > cap) {
            size = cap;
            buf.size = cap;
        }
        if (size == cap && endTime <= buf.ends[size - 1]) {
            return;
        }
        uint8 pos = size;
        while (pos > 0 && endTime > buf.ends[pos - 1]) {
            pos--;
        }
        uint8 upper = size < cap ? size : cap - 1;
        for (uint8 i = upper; i > pos; i--) {
            buf.keys[i] = buf.keys[i - 1];
            buf.ends[i] = buf.ends[i - 1];
        }
        buf.keys[pos] = key;
        buf.ends[pos] = endTime;
        if (size < cap) {
            buf.size = size + 1;
        }
    }

    function _findNextEarliestReservation(
        AppStorage storage s,
        uint256 labId,
        address user
    ) private view returns (bytes32) {
        EnumerableSet.Bytes32Set storage tokenUserReservations = s.reservationKeysByTokenAndUser[labId][user];
        bytes32 earliestKey = bytes32(0);
        uint32 earliestStart = type(uint32).max;
        uint256 length = tokenUserReservations.length();
        for (uint256 i; i < length;) {
            bytes32 key = tokenUserReservations.at(i);
            Reservation storage res = s.reservations[key];
            if (
                (res.status == _CONFIRMED || res.status == _IN_USE) && res.end >= block.timestamp
                    && res.start < earliestStart
            ) {
                earliestKey = key;
                earliestStart = res.start;
            }
            unchecked {
                ++i;
            }
        }
        return earliestKey;
    }

    function _isActiveReservationStatus(
        uint8 status
    ) private pure returns (bool) {
        return status == _CONFIRMED || status == _IN_USE || status == _COMPLETED;
    }

    function _decrementActiveReservationCounters(
        AppStorage storage s,
        Reservation storage reservation
    ) private {
        if (s.labActiveReservationCount[reservation.labId] > 0) {
            s.labActiveReservationCount[reservation.labId]--;
        }
        if (s.providerActiveReservationCount[reservation.labProvider] > 0) {
            s.providerActiveReservationCount[reservation.labProvider]--;
        }
    }

    function _removeReservationFromCalendar(
        AppStorage storage s,
        uint256 labId,
        uint32 start
    ) private {
        Tree storage calendar = s.calendars[labId];
        if (calendar.root == 0) {
            return;
        }
        if (calendar.exists(start)) {
            calendar.remove(start);
        }
    }
}
