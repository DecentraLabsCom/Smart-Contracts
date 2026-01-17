// SPDX-License-Identifier: GPL-3.0-or-later
pragma solidity ^0.8.31;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {IERC721} from "@openzeppelin/contracts/token/ERC721/IERC721.sol";
import {EnumerableSet} from "@openzeppelin/contracts/utils/structs/EnumerableSet.sol";
import {BaseWalletReservationFacet, IStakingFacetW} from "../base/BaseWalletReservationFacet.sol";
import {RivalIntervalTreeLibrary, Tree} from "../../../libraries/RivalIntervalTreeLibrary.sol";
import {AppStorage, Reservation} from "../../../libraries/LibAppStorage.sol";

/// @title WalletReservationConfirmationFacet
/// @author Luis de la Torre Cubillo, Juan Luis Ramos Villalón
/// @notice Confirmation and denial functions for wallet reservations
/// @dev Extracted from WalletReservationCoreFacet to reduce contract size below EIP-170 limit

contract WalletReservationConfirmationFacet is BaseWalletReservationFacet {
    using EnumerableSet for EnumerableSet.Bytes32Set;
    using RivalIntervalTreeLibrary for Tree;

    function confirmReservationRequest(bytes32 _reservationKey)
        external
        override
        reservationPending(_reservationKey)
    {
        _requireLabProviderOrBackend(_reservationKey);
        _confirmReservationRequest(_reservationKey);
    }

    function denyReservationRequest(bytes32 _reservationKey)
        external
        override
        reservationPending(_reservationKey)
    {
        _requireLabProviderOrBackend(_reservationKey);
        _denyReservationRequest(_reservationKey);
    }

    function _requireLabProviderOrBackend(bytes32 _reservationKey) internal view {
        AppStorage storage s = _s();
        Reservation storage reservation = s.reservations[_reservationKey];
        address labOwner = IERC721(address(this)).ownerOf(reservation.labId);
        address authorizedBackend = s.institutionalBackends[labOwner];
        
        require(
            msg.sender == labOwner || (authorizedBackend != address(0) && msg.sender == authorizedBackend),
            "Only lab provider or authorized backend"
        );
    }

    function _confirmReservationRequest(bytes32 _reservationKey) internal override {
        AppStorage storage s = _s();
        Reservation storage reservation = s.reservations[_reservationKey];

        address labProvider = IERC721(address(this)).ownerOf(reservation.labId);

        reservation.labProvider = labProvider;
        reservation.collectorInstitution = s.institutionalBackends[labProvider] != address(0) ? labProvider : address(0);

        if (!_providerCanFulfill(s, labProvider, reservation.labId)) {
            _cancelReservation(_reservationKey);
            emit ReservationRequestDenied(_reservationKey, reservation.labId);
            return;
        }

        (bool success, bytes memory data) = s.labTokenAddress.call(
            abi.encodeWithSelector(IERC20.transferFrom.selector, reservation.renter, address(this), uint256(reservation.price))
        );

        if (!success || (data.length != 0 && !abi.decode(data, (bool)))) {
            _cancelReservation(_reservationKey);
            emit ReservationRequestDenied(_reservationKey, reservation.labId);
            return;
        }

        _setReservationSplit(reservation);
        s.calendars[reservation.labId].insert(reservation.start, reservation.end);
        
        reservation.status = _CONFIRMED;
        _incrementActiveReservationCounters(reservation);
        _enqueuePayoutCandidate(s, reservation.labId, _reservationKey, reservation.end);
        
        IStakingFacetW(address(this)).updateLastReservation(labProvider);
        
        bytes32 currentIndexKey = s.activeReservationByTokenAndUser[reservation.labId][reservation.renter];
        
        if (currentIndexKey == bytes32(0)) {
            s.activeReservationByTokenAndUser[reservation.labId][reservation.renter] = _reservationKey;
        } else {
            Reservation memory currentReservation = s.reservations[currentIndexKey];
            if (reservation.start < currentReservation.start) {
                s.activeReservationByTokenAndUser[reservation.labId][reservation.renter] = _reservationKey;
            }
        }
        
        emit ReservationConfirmed(_reservationKey, reservation.labId);
    }

    function _denyReservationRequest(bytes32 _reservationKey) internal override {
        Reservation storage reservation = _s().reservations[_reservationKey];
        _cancelReservation(_reservationKey);
        emit ReservationRequestDenied(_reservationKey, reservation.labId);
    }
}
