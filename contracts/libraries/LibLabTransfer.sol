// SPDX-License-Identifier: GPL-3.0-or-later
pragma solidity ^0.8.33;

import {EnumerableSet} from "@openzeppelin/contracts/utils/structs/EnumerableSet.sol";
import {AppStorage, LibAppStorage} from "./LibAppStorage.sol";

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
        emit LabUnlisted(tokenId, from);
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

        for (uint256 i = 0; i < reservationCount;) {
            bytes32 key = labReservations.at(i);

            uint8 status = s.reservations[key].status;

            if (status == _PENDING) {
                revert("Pending reservations block transfer");
            }

            if (status == _CONFIRMED || status == _IN_USE || status == _COMPLETED) {
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
    }
}
