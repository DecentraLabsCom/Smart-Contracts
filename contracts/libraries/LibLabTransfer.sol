// SPDX-License-Identifier: GPL-3.0-or-later
pragma solidity ^0.8.33;

import {EnumerableSet} from "@openzeppelin/contracts/utils/structs/EnumerableSet.sol";
import {AppStorage, LibAppStorage} from "./LibAppStorage.sol";

library LibLabTransfer {
    using EnumerableSet for EnumerableSet.Bytes32Set;

    event LabUnlisted(uint256 indexed tokenId, address indexed owner);
    uint8 internal constant _SETTLED = 3;
    uint8 internal constant _CANCELLED = 4;

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

    function validateNoActiveReservationsOnTransfer(
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

            if (status != _SETTLED && status != _CANCELLED) {
                revert("Non-terminal reservations block transfer");
            }

            unchecked {
                ++i;
            }
        }
    }
}
