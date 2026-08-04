// SPDX-License-Identifier: GPL-3.0-or-later
pragma solidity ^0.8.31;

import {EnumerableSet} from "@openzeppelin/contracts/utils/structs/EnumerableSet.sol";
import {RivalIntervalTreeLibrary, Tree} from "./RivalIntervalTreeLibrary.sol";
import {
    LibAppStorage,
    AppStorage,
    Reservation,
    UserActiveReservation,
    INSTITUTION_ROLE,
    ProviderNetworkStatus
} from "./LibAppStorage.sol";
import {LibERC721Storage} from "./LibERC721Storage.sol";
import {LibTracking} from "./LibTracking.sol";
import {LibRevenue} from "./LibRevenue.sol";
import {LibHeap} from "./LibHeap.sol";
import {LibReservationCancellation} from "./LibReservationCancellation.sol";
import {LibReservationConfig} from "./LibReservationConfig.sol";
import {LibReservationDenyReason} from "./LibReservationDenyReason.sol";
import {LibReservationIdentity} from "./LibReservationIdentity.sol";

interface IInstitutionalTreasuryFacetConfirmLib {
    function spendFromInstitutionalTreasuryForReservation(
        address institution,
        bytes32 pucHash,
        bytes32 reservationKey,
        uint256 amount
    ) external;
}

library LibInstitutionalReservationConfirmation {
    using EnumerableSet for EnumerableSet.AddressSet;
    using EnumerableSet for EnumerableSet.Bytes32Set;
    using RivalIntervalTreeLibrary for Tree;

    error InstitutionNotRegistered();
    error UnauthorizedInstitutionCall();
    error PayerMismatch();
    error PucMissing();
    error PucMismatch();

    uint8 internal constant _PENDING = 0;
    uint8 internal constant _CONFIRMED = 1;
    uint8 internal constant _ACCESS_AUTHORIZED = 2;

    event ReservationConfirmed(bytes32 indexed reservationKey, uint256 indexed tokenId);
    event ReservationRequestDenied(bytes32 indexed reservationKey, uint256 indexed tokenId, uint8 reason);
    event ReservationConfirmedByGeneration(
        bytes32 indexed reservationId, bytes32 indexed reservationKey, uint256 indexed tokenId
    );
    event ReservationRequestDeniedByGeneration(
        bytes32 indexed reservationId, bytes32 indexed reservationKey, uint256 indexed tokenId, uint8 reason
    );

    function confirmInstitutionalReservationRequestWithPucHash(
        address institution,
        bytes32 key,
        bytes32 pucHash
    ) external {
        AppStorage storage s = LibAppStorage.diamondStorage();
        if (!EnumerableSet.contains(s.roleMembers[INSTITUTION_ROLE], institution)) revert InstitutionNotRegistered();

        Reservation storage r = s.reservations[key];
        if (r.renter == address(0)) revert();
        if (r.status != _PENDING) revert();

        address labOwner = LibERC721Storage.ownerOf(r.labId);
        address providerBackend = s.institutionalBackends[labOwner];

        bool providerCaller = msg.sender == labOwner || (providerBackend != address(0) && msg.sender == providerBackend);
        if (!providerCaller) revert UnauthorizedInstitutionCall();

        _confirmInstitutionalReservationRequestWithPucHash(s, institution, key, pucHash);
    }

    function _confirmInstitutionalReservationRequestWithPucHash(
        AppStorage storage s,
        address institution,
        bytes32 key,
        bytes32 pucHash
    ) internal {
        Reservation storage r = s.reservations[key];
        if (r.payerInstitution != institution) revert PayerMismatch();

        bytes32 reservationId = LibReservationIdentity.currentReservationId(s, key);
        bytes32 storedHash = s.reservationPucHash[reservationId];
        if (storedHash == bytes32(0)) revert PucMissing();
        if (storedHash != pucHash) revert PucMismatch();

        address trackingKey = LibTracking.trackingKeyFromInstitutionHash(institution, storedHash);
        uint256 d = r.requestPeriodDuration;
        if (d == 0) d = s.institutionalSpendingPeriod[institution];
        if (d == 0) d = LibAppStorage.DEFAULT_SPENDING_PERIOD;
        if (
            block.timestamp >= r.start || block.timestamp >= r.end
                || LibReservationConfig.isPendingRequestExpired(r.requestPeriodStart, d, r.start, block.timestamp)
        ) {
            LibReservationCancellation.cancelReservation(key);
            emit ReservationRequestDenied(key, r.labId, LibReservationDenyReason.REQUEST_EXPIRED);
            emit ReservationRequestDeniedByGeneration(
                reservationId, key, r.labId, LibReservationDenyReason.REQUEST_EXPIRED
            );
            return;
        }

        address labProvider = LibERC721Storage.ownerOf(r.labId);
        r.labProvider = labProvider;

        if (!_providerCanFulfill(s, labProvider, r.labId)) {
            LibReservationCancellation.cancelReservation(key);
            emit ReservationRequestDenied(key, r.labId, LibReservationDenyReason.PROVIDER_NOT_ELIGIBLE);
            emit ReservationRequestDeniedByGeneration(
                reservationId, key, r.labId, LibReservationDenyReason.PROVIDER_NOT_ELIGIBLE
            );
            return;
        }

        r.collectorInstitution = s.institutionalBackends[labProvider] != address(0) ? labProvider : address(0);

        if (r.price == 0) {
            _finalize(s, r, key, trackingKey);
            return;
        }

        try IInstitutionalTreasuryFacetConfirmLib(address(this))
            .spendFromInstitutionalTreasuryForReservation(r.payerInstitution, pucHash, key, r.price) {
            _finalize(s, r, key, trackingKey);
        } catch {
            LibReservationCancellation.cancelReservation(key);
            emit ReservationRequestDenied(key, r.labId, LibReservationDenyReason.TREASURY_SPEND_FAILED);
            emit ReservationRequestDeniedByGeneration(
                reservationId, key, r.labId, LibReservationDenyReason.TREASURY_SPEND_FAILED
            );
        }
    }

    function _finalize(
        AppStorage storage s,
        Reservation storage r,
        bytes32 key,
        address trackingKey
    ) private {
        bytes32 reservationId = LibReservationIdentity.currentReservationId(s, key);
        _setReservationSplit(r);
        if (s.labs[r.labId].resourceType == 0) {
            s.calendars[r.labId].insert(r.start, r.end);
        }
        s.activeConcurrentReservationKeysByLab[r.labId].add(reservationId);
        r.status = _CONFIRMED;
        LibReservationIdentity.snapshotCurrentReservation(s, key);
        if (s.labPendingReservationCount[r.labId] > 0) {
            s.labPendingReservationCount[r.labId]--;
        }
        _incrementActiveReservationCounters(s, r);
        s.activeReservationCountByTokenAndUser[r.labId][trackingKey]++;
        _enqueuePayoutCandidate(s, r.labId, key, r.end);
        _enqueueInstitutionalActiveReservation(s, r.labId, r, key);
        bytes32 currentKey = s.activeReservationByTokenAndUser[r.labId][trackingKey];
        if (currentKey == bytes32(0) || r.start < s.reservations[currentKey].start) {
            s.activeReservationByTokenAndUser[r.labId][trackingKey] = key;
        }

        emit ReservationConfirmed(key, r.labId);
        emit ReservationConfirmedByGeneration(reservationId, key, r.labId);
    }

    function _providerCanFulfill(
        AppStorage storage s,
        address labProvider,
        uint256 labId
    ) private view returns (bool) {
        if (!s.tokenStatus[labId] || s.labReservationIntakeStopped[labId]) return false;
        if (s.providerNetworkStatus[labProvider] != ProviderNetworkStatus.ACTIVE) return false;
        return true;
    }

    function _setReservationSplit(
        Reservation storage reservation
    ) private {
        reservation.providerShare = LibRevenue.calculateRevenueSplit(reservation.price);
    }

    function _incrementActiveReservationCounters(
        AppStorage storage s,
        Reservation storage reservation
    ) private {
        s.labActiveReservationCount[reservation.labId]++;
        s.providerActiveReservationCount[reservation.labProvider]++;
    }

    function _enqueuePayoutCandidate(
        AppStorage storage s,
        uint256 labId,
        bytes32 key,
        uint32 end
    ) private {
        LibHeap.enqueuePayoutCandidate(s, labId, key, end);
    }

    function _enqueueInstitutionalActiveReservation(
        AppStorage storage s,
        uint256 labId,
        Reservation storage reservation,
        bytes32 reservationKey
    ) private {
        bytes32 storedHash = s.reservationPucHash[LibReservationIdentity.currentReservationId(s, reservationKey)];
        if (storedHash == bytes32(0)) return;
        address trackingKey = LibTracking.trackingKeyFromInstitutionHash(reservation.renter, storedHash);
        _enqueueActiveReservation(s, labId, trackingKey, reservationKey, reservation.start);
    }

    function _enqueueActiveReservation(
        AppStorage storage s,
        uint256 labId,
        address trackingKey,
        bytes32 reservationKey,
        uint32 start
    ) private {
        bytes32 reservationId = LibReservationIdentity.currentReservationId(s, reservationKey);
        if (trackingKey == address(0) || s.activeReservationHeapContains[reservationId]) return;
        UserActiveReservation[] storage heap = s.activeReservationHeaps[labId][trackingKey];
        heap.push(UserActiveReservation({start: start, key: reservationId}));
        s.activeReservationHeapContains[reservationId] = true;
        _activeHeapifyUp(heap, heap.length - 1);
    }

    function _activeHeapifyUp(
        UserActiveReservation[] storage heap,
        uint256 index
    ) private {
        while (index > 0) {
            uint256 parent = (index - 1) / 2;
            if (heap[index].start >= heap[parent].start) break;
            UserActiveReservation memory temp = heap[index];
            heap[index] = heap[parent];
            heap[parent] = temp;
            index = parent;
        }
    }
}
