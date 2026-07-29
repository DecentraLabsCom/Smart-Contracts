// SPDX-License-Identifier: GPL-3.0-or-later
pragma solidity ^0.8.33;

import {LibAppStorage, AppStorage, Reservation} from "./LibAppStorage.sol";
import {LibRevenue} from "./LibRevenue.sol";
import {LibReservationCancellation} from "./LibReservationCancellation.sol";
import {LibERC721Storage} from "./LibERC721Storage.sol";
import {LibReputation} from "./LibReputation.sol";
import {LibReservationConfig} from "./LibReservationConfig.sol";
import {LibReservationDenyReason} from "./LibReservationDenyReason.sol";

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
    function refundToInstitutionalTreasuryForReservation(
        address provider,
        bytes32 pucHash,
        bytes32 reservationKey,
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
    error UnauthorizedProvider();
    error InvalidProviderCancellationReason();

    uint8 internal constant _PENDING = 0;
    uint8 internal constant _CONFIRMED = 1;
    uint8 internal constant _ACCESS_AUTHORIZED = 2;

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
        uint96 providerFee = 0;
        uint96 refundAmount = price;

        if (price > 0 && s.labs[labId].resourceType == 0) {
            (providerFee, refundAmount) = LibRevenue.computeCancellationFee(price);
        }

        LibReservationCancellation.cancelReservation(reservationKey);

        if (price > 0) {
            LibReservationCancellation.applyCancellationFees(labId, providerFee, reservationKey);
        }

        IInstitutionalTreasuryFacet(address(this))
            .refundToInstitutionalTreasuryForReservation(
                reservation.payerInstitution, pucHash, reservationKey, refundAmount
            );
    }

    /// @notice Cancel a confirmed institutional booking at the provider's initiative.
    /// @dev Only the current lab owner or its authorized backend may use this path.
    ///      Ordinary cancellations are limited to the pre-start window and apply a
    ///      notice-based reputation penalty. PROVIDER_SERVICE_FAILURE is the explicit
    ///      provider admission that service was not delivered; it is also available
    ///      after start while the session-attestation grace remains open and applies
    ///      the stronger penalty. Every provider path refunds the full price.
    function cancelConfirmedBookingByProvider(
        bytes32 reservationKey,
        uint8 reasonCode
    )
        internal
        returns (uint256 labId, address payerInstitution, address provider, bytes32 pucHash, uint96 refundAmount)
    {
        AppStorage storage s = LibAppStorage.diamondStorage();
        Reservation storage reservation = s.reservations[reservationKey];
        if (reservation.renter == address(0)) revert InvalidStatus();
        bool serviceFailure = reasonCode == LibReservationDenyReason.PROVIDER_SERVICE_FAILURE;
        if (serviceFailure) {
            if (reservation.status != _CONFIRMED && reservation.status != _ACCESS_AUTHORIZED) revert InvalidStatus();
            if (s.reservationSessionStartedRecorded[reservationKey]) revert InvalidStatus();
            if (!LibReservationConfig.isWithinSessionAttestationGrace(reservation.end, block.timestamp)) {
                revert InvalidStatus();
            }
        } else {
            if (reservation.status != _CONFIRMED) revert InvalidStatus();
            if (block.timestamp >= reservation.start) revert InvalidStatus();
        }
        if (reasonCode == 0) revert InvalidProviderCancellationReason();

        provider = LibERC721Storage.ownerOf(reservation.labId);
        address backend = s.institutionalBackends[provider];
        if (msg.sender != provider && (backend == address(0) || msg.sender != backend)) {
            revert UnauthorizedProvider();
        }

        labId = reservation.labId;
        payerInstitution = reservation.payerInstitution;
        pucHash = s.reservationPucHash[reservationKey];
        if (pucHash == bytes32(0)) revert PucMismatch();
        refundAmount = reservation.price;

        LibReservationCancellation.cancelReservation(reservationKey);
        if (serviceFailure) {
            LibReputation.recordProviderServiceFailure(labId);
        } else {
            LibReputation.recordProviderCancellation(labId, reservation.start);
        }

        IInstitutionalTreasuryFacet(address(this))
            .refundToInstitutionalTreasuryForReservation(payerInstitution, pucHash, reservationKey, refundAmount);
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
