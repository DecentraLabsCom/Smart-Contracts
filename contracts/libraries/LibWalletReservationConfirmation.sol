// SPDX-License-Identifier: GPL-3.0-or-later
pragma solidity ^0.8.31;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {IERC721} from "@openzeppelin/contracts/token/ERC721/IERC721.sol";
import {RivalIntervalTreeLibrary, Tree} from "./RivalIntervalTreeLibrary.sol";
import {LibAppStorage, AppStorage, Reservation} from "./LibAppStorage.sol";
import {LibRevenue} from "./LibRevenue.sol";
import {LibHeap} from "./LibHeap.sol";
import {LibReservationCancellation} from "./LibReservationCancellation.sol";

interface IStakingFacetWalletConfirm {
    function updateLastReservation(
        address provider
    ) external;
}

interface IReservableTokenCalcW {
    function calculateRequiredStake(
        address provider,
        uint256 listedLabsCount
    ) external view returns (uint256);
}

library LibWalletReservationConfirmation {
    using RivalIntervalTreeLibrary for Tree;

    error ReservationNotFound();
    error ReservationNotPending();
    error Unauthorized();

    event ReservationConfirmed(bytes32 indexed reservationKey, uint256 indexed tokenId);
    event ReservationRequestDenied(bytes32 indexed reservationKey, uint256 indexed tokenId);

    uint8 internal constant _PENDING = 0;
    uint8 internal constant _CONFIRMED = 1;
    uint8 internal constant _IN_USE = 2;

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
        emit ReservationRequestDenied(reservationKey, reservation.labId);
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
        address labOwner = IERC721(address(this)).ownerOf(reservation.labId);
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
        address labProvider = IERC721(address(this)).ownerOf(reservation.labId);
        reservation.labProvider = labProvider;
        reservation.collectorInstitution = s.institutionalBackends[labProvider] != address(0) ? labProvider : address(0);

        if (!_providerCanFulfill(s, labProvider, reservation.labId)) {
            LibReservationCancellation.cancelReservation(reservationKey);
            emit ReservationRequestDenied(reservationKey, reservation.labId);
            return;
        }

        _setReservationSplit(reservation);

        (bool success, bytes memory data) = s.labTokenAddress.call(
            abi.encodeWithSelector(
                IERC20.transferFrom.selector, reservation.renter, address(this), uint256(reservation.price)
            )
        );

        if (!success || (data.length != 0 && !abi.decode(data, (bool)))) {
            LibReservationCancellation.cancelReservation(reservationKey);
            emit ReservationRequestDenied(reservationKey, reservation.labId);
            return;
        }

        s.calendars[reservation.labId].insert(reservation.start, reservation.end);
        reservation.status = _CONFIRMED;
        _incrementActiveReservationCounters(s, reservation);
        _enqueuePayoutCandidate(s, reservation.labId, reservationKey, reservation.end);

        IStakingFacetWalletConfirm(address(this)).updateLastReservation(labProvider);

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
        uint256 listedLabsCount = s.providerStakes[labProvider].listedLabsCount;
        uint256 requiredStake = IReservableTokenCalcW(address(this)).calculateRequiredStake(labProvider, listedLabsCount);
        return s.providerStakes[labProvider].stakedAmount >= requiredStake;
    }

    function _setReservationSplit(
        Reservation storage reservation
    ) private {
        (uint96 prov, uint96 treas, uint96 subs, uint96 gov) = LibRevenue.calculateRevenueSplit(reservation.price);
        reservation.providerShare = prov;
        reservation.projectTreasuryShare = treas;
        reservation.subsidiesShare = subs;
        reservation.governanceShare = gov;
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
