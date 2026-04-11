// SPDX-License-Identifier: GPL-3.0-or-later
pragma solidity ^0.8.33;

import {RivalIntervalTreeLibrary, Tree} from "./RivalIntervalTreeLibrary.sol";
import {EnumerableSet} from "@openzeppelin/contracts/utils/structs/EnumerableSet.sol";
import {LibAppStorage, AppStorage, Reservation, ProviderNetworkStatus} from "./LibAppStorage.sol";
import {LibERC721Storage} from "./LibERC721Storage.sol";
import {LibRevenue} from "./LibRevenue.sol";
import {LibHeap} from "./LibHeap.sol";
import {LibReservationCancellation} from "./LibReservationCancellation.sol";
import {LibReservationDenyReason} from "./LibReservationDenyReason.sol";
import {LibCreditLedger} from "./LibCreditLedger.sol";

library LibReservationConfirmation {
    using EnumerableSet for EnumerableSet.Bytes32Set;
    using RivalIntervalTreeLibrary for Tree;

    error ReservationNotFound();
    error ReservationNotPending();
    error Unauthorized();

    event ReservationConfirmed(bytes32 indexed reservationKey, uint256 indexed tokenId);
    event ReservationRequestDenied(bytes32 indexed reservationKey, uint256 indexed tokenId, uint8 reason);

    uint8 internal constant _PENDING = 0;
    uint8 internal constant _CONFIRMED = 1;
    uint8 internal constant _IN_USE = 2;

    error MaxReservationsReached();
    uint8 internal constant _MAX_RESERVATIONS_PER_LAB_USER = 10;

    function confirmReservationRequest(
        bytes32 reservationKey
    ) external {
        AppStorage storage s = LibAppStorage.diamondStorage();
        Reservation storage reservation = s.reservations[reservationKey];
        _requirePending(reservation);
        _requireLabProviderOrBackend(s, reservation);
        _confirmReservationRequest(s, reservationKey, reservation);
    }

    function denyReservationRequest(
        bytes32 reservationKey
    ) external {
        AppStorage storage s = LibAppStorage.diamondStorage();
        Reservation storage reservation = s.reservations[reservationKey];
        _requirePending(reservation);
        _requireLabProviderOrBackend(s, reservation);
        LibReservationCancellation.cancelReservation(reservationKey);
        emit ReservationRequestDenied(reservationKey, reservation.labId, LibReservationDenyReason.PROVIDER_MANUAL);
    }

    function _requirePending(
        Reservation storage reservation
    ) private view {
        if (reservation.renter == address(0)) revert ReservationNotFound();
        if (reservation.status != _PENDING) revert ReservationNotPending();
    }

    function _requireLabProviderOrBackend(
        AppStorage storage s,
        Reservation storage reservation
    ) private view {
        address labOwner = LibERC721Storage.ownerOf(reservation.labId);
        address authorizedBackend = s.institutionalBackends[labOwner];
        if (msg.sender != labOwner && (authorizedBackend == address(0) || msg.sender != authorizedBackend)) {
            revert Unauthorized();
        }
    }

    function _confirmReservationRequest(
        AppStorage storage s,
        bytes32 reservationKey,
        Reservation storage reservation
    ) private {
        address labProvider = LibERC721Storage.ownerOf(reservation.labId);
        reservation.labProvider = labProvider;
        reservation.collectorInstitution = s.institutionalBackends[labProvider] != address(0) ? labProvider : address(0);

        if (!_providerCanFulfill(s, labProvider, reservation.labId)) {
            LibReservationCancellation.cancelReservation(reservationKey);
            emit ReservationRequestDenied(
                reservationKey, reservation.labId, LibReservationDenyReason.PROVIDER_NOT_ELIGIBLE
            );
            return;
        }

        // enforce per-user cap before collecting locked service credits
        if (
            s.activeReservationCountByTokenAndUser[reservation.labId][reservation.renter]
                >= _MAX_RESERVATIONS_PER_LAB_USER
        ) {
            revert MaxReservationsReached();
        }

        _setReservationSplit(reservation);

        if (LibCreditLedger.availableBalanceOf(reservation.renter) < reservation.price) {
            LibReservationCancellation.cancelReservation(reservationKey);
            emit ReservationRequestDenied(reservationKey, reservation.labId, LibReservationDenyReason.PAYMENT_FAILED);
            return;
        }
        LibCreditLedger.lockCredits(reservation.renter, uint256(reservation.price), reservationKey);

        if (s.labs[reservation.labId].resourceType == 0) {
            s.calendars[reservation.labId].insert(reservation.start, reservation.end);
        }
        reservation.status = _CONFIRMED;
        _incrementActiveReservationCounters(s, reservation);

        // increment per-user counters and indexes (was previously only done in ReservableTokenEnumerable.confirmReservationRequest)
        s.activeReservationCountByTokenAndUser[reservation.labId][reservation.renter]++;
        bool added = s.reservationKeysByTokenAndUser[reservation.labId][reservation.renter].add(reservationKey);

        _enqueuePayoutCandidate(s, reservation.labId, reservationKey, reservation.end);

        bytes32 currentIndexKey = s.activeReservationByTokenAndUser[reservation.labId][reservation.renter];
        if (currentIndexKey == bytes32(0)) {
            s.activeReservationByTokenAndUser[reservation.labId][reservation.renter] = reservationKey;
        } else {
            Reservation memory currentReservation = s.reservations[currentIndexKey];
            if (reservation.start < currentReservation.start) {
                s.activeReservationByTokenAndUser[reservation.labId][reservation.renter] = reservationKey;
            }
        }

        emit ReservationConfirmed(reservationKey, reservation.labId);
    }

    function _providerCanFulfill(
        AppStorage storage s,
        address labProvider,
        uint256 labId
    ) private view returns (bool) {
        if (!s.tokenStatus[labId]) return false;
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
}
