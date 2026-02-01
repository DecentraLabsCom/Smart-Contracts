// SPDX-License-Identifier: GPL-3.0-or-later
pragma solidity ^0.8.33;

import {EnumerableSet} from "@openzeppelin/contracts/utils/structs/EnumerableSet.sol";
import {AppStorage, LibAppStorage} from "./LibAppStorage.sol";
import {ReservableToken} from "../abstracts/ReservableToken.sol";

library LibLabTransfer {
    using EnumerableSet for EnumerableSet.Bytes32Set;

    event LabUnlisted(uint256 indexed tokenId, address indexed owner);
    event ReservationProviderUpdated(
        bytes32 indexed reservationKey, uint256 indexed labId, address indexed oldProvider, address newProvider
    );

    uint8 internal constant _PENDING = 0;
    uint8 internal constant _CONFIRMED = 1;
    uint8 internal constant _IN_USE = 2;
    uint8 internal constant _COMPLETED = 3;

    function handleListingOnTransfer(
        address from,
        address to,
        uint256 tokenId
    ) external {
        AppStorage storage s = LibAppStorage.diamondStorage();

        if (!s.tokenStatus[tokenId]) {
            return;
        }

        s.tokenStatus[tokenId] = false;

        if (s.providerStakes[from].listedLabsCount > 0) {
            s.providerStakes[from].listedLabsCount--;
        }

        emit LabUnlisted(tokenId, from);

        uint256 recipientListedCount = s.providerStakes[to].listedLabsCount;
        if (recipientListedCount == 0) {
            return;
        }

        uint256 requiredStake = ReservableToken(address(this)).calculateRequiredStake(to, recipientListedCount);
        uint256 currentStake = s.providerStakes[to].stakedAmount;

        require(currentStake >= requiredStake, "Recipient lacks sufficient stake for their current listings");
    }

    function migrateReservationsOnTransfer(
        address from,
        address to,
        uint256 tokenId,
        uint256 maxCleanup
    ) external {
        AppStorage storage s = LibAppStorage.diamondStorage();
        EnumerableSet.Bytes32Set storage labReservations = s.reservationKeysByToken[tokenId];
        uint256 reservationCount = labReservations.length();
        require(reservationCount <= maxCleanup, "Too many active reservations to transfer");

        bool hasActiveReservation;

        for (uint256 i = 0; i < reservationCount;) {
            bytes32 key = labReservations.at(i);

            uint8 status = s.reservations[key].status;

            if (status == _PENDING) {
                revert("Pending reservations block transfer");
            }

            if (status == _CONFIRMED || status == _IN_USE || status == _COMPLETED) {
                hasActiveReservation = true;
                s.reservations[key].labProvider = to;
                s.reservations[key].collectorInstitution = s.institutionalBackends[to] != address(0) ? to : address(0);

                if (s.providerActiveReservationCount[from] > 0) {
                    s.providerActiveReservationCount[from]--;
                }
                s.providerActiveReservationCount[to]++;

                emit ReservationProviderUpdated(key, tokenId, from, to);
            }

            unchecked {
                ++i;
            }
        }

        uint256 fromLast = s.providerStakes[from].lastReservationTimestamp;
        uint256 toLast = s.providerStakes[to].lastReservationTimestamp;
        uint256 newLast = fromLast > toLast ? fromLast : toLast;
        if (hasActiveReservation && block.timestamp > newLast) {
            newLast = block.timestamp;
        }
        if (newLast > toLast) {
            s.providerStakes[to].lastReservationTimestamp = newLast;
        }
    }
}
