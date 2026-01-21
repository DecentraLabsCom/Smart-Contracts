// SPDX-License-Identifier: GPL-3.0-or-later
pragma solidity ^0.8.33;

import {LibAppStorage, AppStorage, Reservation} from "./LibAppStorage.sol";
import {LibRevenue} from "./LibRevenue.sol";
import {LibReservationCancellation} from "./LibReservationCancellation.sol";

interface IInstValidation {
    function validateInstRequest(
        address p,
        string calldata u,
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
    string u;
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
        string calldata puc,
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
        string calldata puc,
        uint256 labId,
        uint32 start,
        uint32 end
    ) internal {
        (address owner, bytes32 key, address trackingKey) =
            IInstValidation(address(this)).validateInstRequest(institutionalProvider, puc, labId, start, end);

        IInstCreation(address(this))
            .createInstReservation(
                InstInput({
                    p: institutionalProvider, o: owner, l: labId, s: start, e: end, u: puc, k: key, t: trackingKey
                })
            );
        IInstCreation(address(this)).recordRecentInstReservation(labId, trackingKey, key, start);
    }

    function cancelReservationRequest(
        address institutionalProvider,
        string calldata puc,
        bytes32 reservationKey
    ) internal returns (uint256 labId) {
        AppStorage storage s = LibAppStorage.diamondStorage();
        if (s.institutionalBackends[institutionalProvider] == address(0)) revert BackendMissing();
        if (msg.sender != s.institutionalBackends[institutionalProvider]) revert UnauthorizedInstitution();

        Reservation storage reservation = s.reservations[reservationKey];
        if (reservation.renter == address(0)) revert InstReservationNotFound();
        if (reservation.payerInstitution != institutionalProvider) revert NotRenter();
        if (reservation.status != _PENDING) revert NotPending();
        if (!_pucMatches(s, reservation, reservationKey, puc)) revert PucMismatch();

        labId = reservation.labId;
        LibReservationCancellation.cancelReservation(reservationKey);
    }

    function cancelBooking(
        address institutionalProvider,
        string memory puc,
        bytes32 reservationKey
    ) internal returns (uint256 labId) {
        AppStorage storage s = LibAppStorage.diamondStorage();
        if (s.institutionalBackends[institutionalProvider] == address(0)) revert BackendMissing();
        if (msg.sender != s.institutionalBackends[institutionalProvider]) revert UnauthorizedInstitution();

        Reservation storage reservation = s.reservations[reservationKey];
        if (reservation.renter == address(0) || (reservation.status != _CONFIRMED && reservation.status != _IN_USE)) {
            revert InvalidStatus();
        }
        if (reservation.payerInstitution != institutionalProvider) revert NotRenter();
        if (!_pucMatches(s, reservation, reservationKey, puc)) revert PucMismatch();

        labId = reservation.labId;

        uint96 price = reservation.price;
        uint96 providerFee;
        uint96 treasuryFee;
        uint96 governanceFee;
        uint96 refundAmount = price;

        if (price > 0) {
            (providerFee, treasuryFee, governanceFee, refundAmount) = LibRevenue.computeCancellationFee(price);
        }

        LibReservationCancellation.cancelReservation(reservationKey);

        if (price > 0) {
            LibReservationCancellation.applyCancellationFees(labId, providerFee, treasuryFee, governanceFee);
        }

        IInstitutionalTreasuryFacet(address(this))
            .refundToInstitutionalTreasury(reservation.payerInstitution, puc, refundAmount);
    }

    function _pucMatches(
        AppStorage storage s,
        Reservation storage,
        bytes32 reservationKey,
        string memory puc
    ) internal view returns (bool) {
        bytes32 storedHash = s.reservationPucHash[reservationKey];
        return storedHash != bytes32(0) && storedHash == keccak256(bytes(puc));
    }
}
