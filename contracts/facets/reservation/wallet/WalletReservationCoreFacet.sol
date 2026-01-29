// SPDX-License-Identifier: GPL-3.0-or-later
pragma solidity ^0.8.31;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {IERC721} from "@openzeppelin/contracts/token/ERC721/IERC721.sol";
import {EnumerableSet} from "@openzeppelin/contracts/utils/structs/EnumerableSet.sol";
import {BaseLightReservationFacet} from "../base/BaseLightReservationFacet.sol";
import {AppStorage, Reservation} from "../../../libraries/LibAppStorage.sol";
import {ReservableToken} from "../../../abstracts/ReservableToken.sol";

/// @title WalletReservationCoreFacet
/// @author Luis de la Torre Cubillo, Juan Luis Ramos Villalón
/// @notice Core reservation request and confirmation functions for wallet users
/// @dev Extracted from WalletReservationFacet to reduce contract size below EIP-170 limit

contract WalletReservationCoreFacet is BaseLightReservationFacet {
    using EnumerableSet for EnumerableSet.AddressSet;
    using EnumerableSet for EnumerableSet.Bytes32Set;

    error InsufficientFunds();
    error LabNotListed();
    error InsufficientStake();
    error InvalidRange();
    error LowAllowance();
    error SlotUnavailable();
    uint256 internal constant _PENDING_REQUEST_TTL = 1 hours;

    function reservationRequest(
        uint256 _labId,
        uint32 _start,
        uint32 _end
    ) external override exists(_labId) {
        _reservationRequest(_labId, _start, _end);
    }

    function _reservationRequest(
        uint256 _labId,
        uint32 _start,
        uint32 _end
    ) internal {
        AppStorage storage s = _s();

        if (!s.tokenStatus[_labId]) revert LabNotListed();

        address labOwner = IERC721(address(this)).ownerOf(_labId);
        uint256 listedLabsCount = s.providerStakes[labOwner].listedLabsCount;
        uint256 requiredStake = ReservableToken(address(this)).calculateRequiredStake(labOwner, listedLabsCount);
        if (s.providerStakes[labOwner].stakedAmount < requiredStake) revert InsufficientStake();

        uint256 userActiveCount = s.activeReservationCountByTokenAndUser[_labId][msg.sender];

        if (userActiveCount >= _MAX_RESERVATIONS_PER_LAB_USER - 2) {
            bytes32 earliestKey = s.activeReservationByTokenAndUser[_labId][msg.sender];
            if (earliestKey != bytes32(0)) {
                Reservation storage earliestReservation = s.reservations[earliestKey];
                if (earliestReservation.status == _CONFIRMED && earliestReservation.end < block.timestamp) {
                    _releaseExpiredReservationsInternal(_labId, msg.sender, _MAX_RESERVATIONS_PER_LAB_USER);
                    userActiveCount = s.activeReservationCountByTokenAndUser[_labId][msg.sender];
                }
            }
        }

        if (userActiveCount >= _MAX_RESERVATIONS_PER_LAB_USER) {
            revert MaxReservationsReached();
        }

        if (_start >= _end || _start <= block.timestamp + _RESERVATION_MARGIN) revert InvalidRange();

        uint96 price = s.labs[_labId].price;

        uint256 balance = IERC20(s.labTokenAddress).balanceOf(msg.sender);
        if (balance < price) revert InsufficientFunds();

        if (IERC20(s.labTokenAddress).allowance(msg.sender, address(this)) < price) revert LowAllowance();

        bytes32 reservationKey = _getReservationKey(_labId, _start);

        Reservation storage existing = s.reservations[reservationKey];
        if (existing.renter != address(0) && existing.status != _CANCELLED && existing.status != _COLLECTED) {
            bool isStalePending = existing.status == _PENDING
                && (existing.requestPeriodStart == 0
                    || block.timestamp >= existing.requestPeriodStart + _PENDING_REQUEST_TTL);
            if (isStalePending) {
                _cancelReservation(reservationKey);
            } else {
                revert SlotUnavailable();
            }
        }

        s.reservationKeysByToken[_labId].add(reservationKey);

        s.reservations[reservationKey] = Reservation({
            labId: _labId,
            renter: msg.sender,
            labProvider: labOwner,
            price: price,
            start: _start,
            end: _end,
            status: _PENDING,
            requestPeriodStart: uint64(block.timestamp),
            requestPeriodDuration: 0,
            payerInstitution: address(0),
            collectorInstitution: s.institutionalBackends[labOwner] != address(0) ? labOwner : address(0),
            providerShare: 0,
            projectTreasuryShare: 0,
            subsidiesShare: 0,
            governanceShare: 0
        });

        s.totalReservationsCount++;
        s.renters[msg.sender].add(reservationKey);

        s.reservationKeysByTokenAndUser[_labId][msg.sender].add(reservationKey);

        _recordRecent(s, _labId, msg.sender, reservationKey, _start);

        emit ReservationRequested(msg.sender, _labId, _start, _end, reservationKey);
    }
}
