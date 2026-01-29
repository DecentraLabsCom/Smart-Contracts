// SPDX-License-Identifier: GPL-3.0-or-later
pragma solidity ^0.8.31;

import {EnumerableSet} from "@openzeppelin/contracts/utils/structs/EnumerableSet.sol";
import {ReservableTokenEnumerable} from "../../../abstracts/ReservableTokenEnumerable.sol";
import {AppStorage, Reservation, UserActiveReservation, INSTITUTION_ROLE} from "../../../libraries/LibAppStorage.sol";
import {LibTracking} from "../../../libraries/LibTracking.sol";
import {LibRevenue} from "../../../libraries/LibRevenue.sol";
import {LibHeap} from "../../../libraries/LibHeap.sol";
import {LibReputation} from "../../../libraries/LibReputation.sol";

/// @title BaseLightReservationFacet - Minimal base for size-constrained facets
/// @notice Provides only essential functionality without heavy helpers
abstract contract BaseLightReservationFacet is ReservableTokenEnumerable {
    using EnumerableSet for EnumerableSet.Bytes32Set;
    using EnumerableSet for EnumerableSet.AddressSet;
    uint256 internal constant _PENDING_REQUEST_TTL = 1 hours;

    modifier onlyInstitution(
        address institution
    ) {
        _onlyInstitution(institution);
        _;
    }

    function _onlyInstitution(
        address institution
    ) internal view {
        AppStorage storage s = _s();
        if (!s.roleMembers[INSTITUTION_ROLE].contains(institution)) revert("Unknown institution");
        address backend = s.institutionalBackends[institution];
        if (!(msg.sender == institution || (backend != address(0) && msg.sender == backend))) {
            revert("Unauthorized institution");
        }
    }

    function _trackingKeyFromInstitutionHash(
        address provider,
        bytes32 pucHash
    ) internal pure returns (address) {
        return LibTracking.trackingKeyFromInstitutionHash(provider, pucHash);
    }

    function _pucHashForReservation(
        bytes32 reservationKey,
        Reservation storage
    ) internal view returns (bytes32) {
        return _s().reservationPucHash[reservationKey];
    }

    function _isInstitutionalReservation(
        bytes32 reservationKey,
        Reservation storage
    ) internal view returns (bool) {
        return _s().reservationPucHash[reservationKey] != bytes32(0);
    }

    function _computeTrackingKey(
        bytes32 reservationKey,
        Reservation storage reservation
    ) internal view returns (address) {
        bytes32 pucHash = _s().reservationPucHash[reservationKey];
        return pucHash == bytes32(0) ? reservation.renter : _trackingKeyFromInstitutionHash(reservation.renter, pucHash);
    }

    function _releaseExpiredReservationsInternal(
        uint256 _labId,
        address _user,
        uint256 maxBatch
    ) internal returns (uint256 processed) {
        AppStorage storage s = _s();
        EnumerableSet.Bytes32Set storage userReservations = s.reservationKeysByTokenAndUser[_labId][_user];
        uint256 len = userReservations.length();
        uint256 i;
        uint256 currentTime = block.timestamp;

        while (i < len && processed < maxBatch) {
            bytes32 key = userReservations.at(i);
            Reservation storage reservation = s.reservations[key];

            if (reservation.end < currentTime && reservation.status == _CONFIRMED) {
                _simpleFinalizeReservation(s, key, reservation, _labId, _user);
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
                    _cancelReservation(key);
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

    function _simpleFinalizeReservation(
        AppStorage storage s,
        bytes32 key,
        Reservation storage reservation,
        uint256 labId,
        address trackingKey
    ) internal {
        uint8 previousStatus = reservation.status;
        reservation.status = _COLLECTED;
        if (previousStatus == _IN_USE) {
            LibReputation.recordCompletion(labId);
        }
        s.reservationKeysByToken[labId].remove(key);
        s.renters[reservation.renter].remove(key);
        if (s.totalReservationsCount > 0) s.totalReservationsCount--;
        if (s.activeReservationCountByTokenAndUser[labId][trackingKey] > 0) {
            s.activeReservationCountByTokenAndUser[labId][trackingKey]--;
        }
        s.reservationKeysByTokenAndUser[labId][trackingKey].remove(key);
    }

    // === Provider / Staking check ===
    function _providerCanFulfill(
        AppStorage storage s,
        address labProvider,
        uint256 labId
    ) internal view returns (bool) {
        if (!s.tokenStatus[labId]) return false;
        uint256 listedLabsCount = s.providerStakes[labProvider].listedLabsCount;
        uint256 requiredStake = calculateRequiredStake(labProvider, listedLabsCount);
        return s.providerStakes[labProvider].stakedAmount >= requiredStake;
    }

    // === Revenue Split ===
    function _setReservationSplit(
        Reservation storage reservation
    ) internal {
        (uint96 prov, uint96 treas, uint96 subs, uint96 gov) = LibRevenue.calculateRevenueSplit(reservation.price);
        reservation.providerShare = prov;
        reservation.projectTreasuryShare = treas;
        reservation.subsidiesShare = subs;
        reservation.governanceShare = gov;
    }

    // === Payout Heap ===
    function _enqueuePayoutCandidate(
        AppStorage storage s,
        uint256 labId,
        bytes32 key,
        uint32 end
    ) internal {
        LibHeap.enqueuePayoutCandidate(s, labId, key, end);
    }

    // === Institutional Active Reservation Heap ===
    function _enqueueInstitutionalActiveReservation(
        AppStorage storage s,
        uint256 labId,
        Reservation storage reservation,
        bytes32 reservationKey
    ) internal {
        if (!_isInstitutionalReservation(reservationKey, reservation)) return;
        address trackingKey = _computeTrackingKey(reservationKey, reservation);
        _enqueueActiveReservation(s, labId, trackingKey, reservationKey, reservation.start);
    }

    function _enqueueActiveReservation(
        AppStorage storage s,
        uint256 labId,
        address trackingKey,
        bytes32 reservationKey,
        uint32 start
    ) internal {
        if (trackingKey == address(0) || s.activeReservationHeapContains[reservationKey]) return;
        UserActiveReservation[] storage heap = s.activeReservationHeaps[labId][trackingKey];
        heap.push(UserActiveReservation({start: start, key: reservationKey}));
        s.activeReservationHeapContains[reservationKey] = true;
        _activeHeapifyUp(heap, heap.length - 1);
    }

    function _activeHeapifyUp(
        UserActiveReservation[] storage heap,
        uint256 index
    ) internal {
        while (index > 0) {
            uint256 parent = (index - 1) / 2;
            if (heap[index].start >= heap[parent].start) break;
            UserActiveReservation memory temp = heap[index];
            heap[index] = heap[parent];
            heap[parent] = temp;
            index = parent;
        }
    }

    // === Virtual placeholder for override ===
    function _confirmInstitutionalReservationRequest(
        address,
        bytes32
    ) internal virtual {}
}
