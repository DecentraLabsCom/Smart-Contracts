// SPDX-License-Identifier: GPL-3.0-or-later
pragma solidity ^0.8.33;

import {LibAppStorage, AppStorage, Reservation} from "./LibAppStorage.sol";
import {LibRevenue} from "./LibRevenue.sol";
import {LibReservationCancellation} from "./LibReservationCancellation.sol";

interface IInstValidation {
    function validateInstRequest(
        address p,
        bytes32 u,
        uint256 l,
        uint32 st,
        uint32 en
    ) external returns (address, bytes32, address);
}

struct InstInput {
    address p;
    address o;
    uint256 l;
    uint32 s;
    uint32 e;
    bytes32 u;
    bytes32 k;
    address t;
}

interface IInstCreation {
    function createInstReservation(
        InstInput calldata i
    ) external;
    function recordRecentInstReservation(
        uint256 l,
        address t,
        bytes32 k,
        uint32 st
    ) external;
}

interface IInstitutionalTreasuryFacet {
    function refundToInstitutionalTreasury(
        address provider,
        bytes32 pucHash,
        uint256 amount
    ) external;
}

library LibInstitutionalReservation {
    error BackendMissing();
    error UnauthorizedInstitution();
    error InstReservationNotFound();
    error NotRenter();
    error NotPending();
    error PucMismatch();
    error InvalidStatus();

    uint8 internal constant _PENDING = 0;
    uint8 internal constant _CONFIRMED = 1;
    uint8 internal constant _IN_USE = 2;

    function requestReservation(
        address institutionalProvider,
        bytes32 pucHash,
        uint256 labId,
        uint32 start,
        uint32 end
    ) internal {
        (address owner, bytes32 key, address trackingKey) =
            IInstValidation(address(this)).validateInstRequest(institutionalProvider, pucHash, labId, start, end);

        IInstCreation(address(this))
            .createInstReservation(
                InstInput({
                p: institutionalProvider, o: owner, l: labId, s: start, e: end, u: pucHash, k: key, t: trackingKey
            })
            );
        IInstCreation(address(this)).recordRecentInstReservation(labId, trackingKey, key, start);
    }

    function cancelReservationRequest(
        address institutionalProvider,
        bytes32 pucHash,
        bytes32 reservationKey
    ) internal returns (uint256 labId) {
        AppStorage storage s = LibAppStorage.diamondStorage();
        if (s.institutionalBackends[institutionalProvider] == address(0)) revert BackendMissing();
        if (msg.sender != s.institutionalBackends[institutionalProvider]) revert UnauthorizedInstitution();

        Reservation storage reservation = s.reservations[reservationKey];
        if (reservation.renter == address(0)) revert InstReservationNotFound();
        if (reservation.payerInstitution != institutionalProvider) revert NotRenter();
        if (reservation.status != _PENDING) revert NotPending();
        if (!_pucHashMatches(s, reservationKey, pucHash)) revert PucMismatch();

        labId = reservation.labId;
        LibReservationCancellation.cancelReservation(reservationKey);
    }

    function cancelBooking(
        address institutionalProvider,
        bytes32 pucHash,
        bytes32 reservationKey
    ) internal returns (uint256 labId) {
        AppStorage storage s = LibAppStorage.diamondStorage();
        if (s.institutionalBackends[institutionalProvider] == address(0)) revert BackendMissing();
        if (msg.sender != s.institutionalBackends[institutionalProvider]) revert UnauthorizedInstitution();

        Reservation storage reservation = s.reservations[reservationKey];
        if (reservation.renter == address(0) || reservation.status != _CONFIRMED) {
            revert InvalidStatus();
        }
        if (block.timestamp >= reservation.start) {
            revert InvalidStatus();
        }
        if (reservation.payerInstitution != institutionalProvider) revert NotRenter();
        if (!_pucHashMatches(s, reservationKey, pucHash)) revert PucMismatch();

        labId = reservation.labId;

        uint96 price = reservation.price;
        uint96 providerFee;
        uint96 refundAmount = price;

        if (price > 0) {
            (providerFee, refundAmount) = LibRevenue.computeCancellationFee(price);
        }

        LibReservationCancellation.cancelReservation(reservationKey);

        if (price > 0) {
            LibReservationCancellation.applyCancellationFees(labId, providerFee, reservationKey);
        }

        IInstitutionalTreasuryFacet(address(this))
            .refundToInstitutionalTreasury(reservation.payerInstitution, pucHash, refundAmount);
    }

    function _pucHashMatches(
        AppStorage storage s,
        bytes32 reservationKey,
        bytes32 pucHash
    ) internal view returns (bool) {
        bytes32 storedHash = s.reservationPucHash[reservationKey];
        return storedHash != bytes32(0) && storedHash == pucHash;
    }
}
