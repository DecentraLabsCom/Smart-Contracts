// SPDX-License-Identifier: GPL-3.0-or-later
pragma solidity ^0.8.31;

import {EnumerableSet} from "@openzeppelin/contracts/utils/structs/EnumerableSet.sol";
import {AppStorage, LibAppStorage, Reservation, INSTITUTION_ROLE} from "../../libraries/LibAppStorage.sol";
import {LibIntent} from "../../libraries/LibIntent.sol";
import {ReservationIntentPayload, ActionIntentPayload} from "../../libraries/IntentTypes.sol";
import {LibInstitutionalOrg} from "../../libraries/LibInstitutionalOrg.sol";
import {LibInstitutionalReservation} from "../../libraries/LibInstitutionalReservation.sol";
import {LibERC721Storage} from "../../libraries/LibERC721Storage.sol";
import {LibInstitutionalReservationConfirmation} from "../../libraries/LibInstitutionalReservationConfirmation.sol";

// Custom errors for gas-efficient reverts (Solidity 0.8.26+)
error IntentUnknownInstitution();
error IntentNotAuthorizedInstitution();
error IntentLabDoesNotExist();
error IntentExecutorMustBeCaller();
error IntentInstitutionMustBeCaller();
error IntentInstitutionBackendRequired();
error IntentUnknownReservation();
error ReservationPriceOverflow();

/// @title ReservationIntentFacet
/// @author
/// - Luis de la Torre Cubillo
/// - Juan Luis Ramos Villalón
/// @notice Facet for intent-based institutional reservations.
contract ReservationIntentFacet {
    using EnumerableSet for EnumerableSet.AddressSet;

    /// @notice Event of institutional intents
    event ReservationIntentProcessed(
        bytes32 indexed requestId,
        bytes32 reservationKey,
        string action,
        bytes32 pucHash,
        address institution,
        bool success,
        string reason
    );

    function _s() internal pure returns (AppStorage storage s) {
        s = LibAppStorage.diamondStorage();
    }

    function _onlyInstitutionalBackend(
        address institution
    ) internal view {
        AppStorage storage s = _s();
        require(s.roleMembers[INSTITUTION_ROLE].contains(institution), IntentUnknownInstitution());
        address backend = s.institutionalBackends[institution];
        require(backend != address(0), IntentInstitutionBackendRequired());
        require(msg.sender == backend, IntentNotAuthorizedInstitution());
    }

    /// @dev Resolves the institution from the lab owner for the atomic own-lab
    /// path. The executor may be the owner wallet or its registered backend;
    /// the reservation itself must remain owned and paid by the institution,
    /// never by the backend address.
    function _ownLabBookingInstitution(
        AppStorage storage s,
        uint256 labId
    ) internal view returns (address institution) {
        institution = LibERC721Storage.ownerOf(labId);
        require(s.roleMembers[INSTITUTION_ROLE].contains(institution), IntentUnknownInstitution());
        address backend = s.institutionalBackends[institution];
        require(
            msg.sender == institution || (backend != address(0) && msg.sender == backend),
            IntentNotAuthorizedInstitution()
        );
    }

    /// @dev Resolves the payer institution from the organization bound into
    /// the signed reservation intent. The executor may be that institution or
    /// its registered backend, but the backend is never stored as the payer.
    function _institutionFromIntentOrganization(
        AppStorage storage s,
        string memory organization
    ) internal view returns (address institution) {
        string memory normalized = LibInstitutionalOrg.normalizeOrganization(organization);
        // forge-lint: disable-next-line(asm-keccak256)
        bytes32 organizationHash = keccak256(bytes(normalized));
        institution = s.organizationInstitutionWallet[organizationHash];
        require(institution != address(0), IntentUnknownInstitution());
        require(s.roleMembers[INSTITUTION_ROLE].contains(institution), IntentUnknownInstitution());

        address backend = s.institutionalBackends[institution];
        require(
            msg.sender == institution || (backend != address(0) && msg.sender == backend),
            IntentNotAuthorizedInstitution()
        );
    }

    modifier exists(
        uint256 labId
    ) {
        _exists(labId);
        _;
    }

    function _exists(
        uint256 labId
    ) internal view {
        require(_s().activeLabIndexPlusOne[labId] != 0, IntentLabDoesNotExist());
    }

    function _getReservationKey(
        uint256 labId,
        uint32 start
    ) internal pure returns (bytes32) {
        // forge-lint: disable-next-line(asm-keccak256)
        return keccak256(abi.encodePacked(labId, start));
    }

    function _consumeReservationIntent(
        bytes32 requestId,
        uint8 action,
        ReservationIntentPayload memory payload
    ) internal {
        require(payload.executor == msg.sender, IntentExecutorMustBeCaller());
        bytes32 payloadHash = LibIntent.hashReservationPayload(payload);
        LibIntent.consumeIntent(requestId, action, payloadHash, msg.sender);
    }

    function _consumeActionIntent(
        bytes32 requestId,
        uint8 action,
        ActionIntentPayload memory payload
    ) internal {
        require(payload.executor == msg.sender, IntentExecutorMustBeCaller());
        bytes32 payloadHash = LibIntent.hashActionPayload(payload);
        LibIntent.consumeIntent(requestId, action, payloadHash, msg.sender);
    }

    function _pucHashMatches(
        AppStorage storage s,
        bytes32 reservationKey,
        bytes32 pucHash
    ) internal view returns (bool) {
        bytes32 storedHash = s.reservationPucHash[reservationKey];
        return storedHash != bytes32(0) && storedHash == pucHash;
    }

    /// @dev Own-institution reservations follow the same zero-price rule as
    /// InstitutionalReservationRequestCreationFacet. Keep the intent
    /// validation aligned with the reservation record that is created later.
    function _reservationPrice(
        AppStorage storage s,
        address institution,
        uint256 labId,
        uint32 start,
        uint32 end
    ) internal view returns (uint96) {
        if (s.institutionalBackends[institution] != address(0) && LibERC721Storage.ownerOf(labId) == institution) {
            return 0;
        }

        uint256 totalPrice = uint256(s.labs[labId].price) * uint256(end - start);
        if (totalPrice > type(uint96).max) revert ReservationPriceOverflow();
        return uint96(totalPrice);
    }

    /// @notice Institutional reservation request via intent
    // State is committed before the final audit event; the library call stays within the Diamond.
    // slither-disable-next-line reentrancy-events
    function institutionalReservationRequestWithIntent(
        bytes32 requestId,
        ReservationIntentPayload calldata payload
    ) external exists(payload.labId) {
        AppStorage storage s = _s();
        address institution = _institutionFromIntentOrganization(s, payload.schacHomeOrganization);
        bytes32 expectedKey = _getReservationKey(payload.labId, payload.start);
        require(payload.reservationKey == expectedKey, "RESERVATION_KEY_MISMATCH");
        uint96 expectedPrice = _reservationPrice(s, institution, payload.labId, payload.start, payload.end);
        require(payload.price == expectedPrice, "LAB_PRICE_MISMATCH");
        _consumeReservationIntent(requestId, LibIntent.ACTION_REQUEST_BOOKING, payload);

        LibInstitutionalReservation.requestReservation(
            institution, payload.pucHash, payload.labId, payload.start, payload.end
        );
        emit ReservationIntentProcessed(
            requestId, payload.reservationKey, "RESERVATION_REQUEST", payload.pucHash, institution, true, ""
        );
    }

    /// @notice Atomic request + confirm for own-lab bookings (same institution is both payer and provider)
    /// @dev Only valid when the caller is the ERC-721 owner of the lab or its
    ///      registered backend. The owner remains the payer/provider identity.
    ///      Saves one on-chain transaction and one round-trip versus the two-step request→confirm flow.
    // State is committed before the final audit event; the library calls stay within the Diamond.
    // slither-disable-next-line reentrancy-events
    function institutionalDirectBookingWithIntent(
        bytes32 requestId,
        ReservationIntentPayload calldata payload
    ) external exists(payload.labId) {
        AppStorage storage s = _s();
        address institution = _ownLabBookingInstitution(s, payload.labId);
        require(
            _institutionFromIntentOrganization(s, payload.schacHomeOrganization) == institution, "INSTITUTION_MISMATCH"
        );
        bytes32 expectedKey = _getReservationKey(payload.labId, payload.start);
        require(payload.reservationKey == expectedKey, "RESERVATION_KEY_MISMATCH");
        uint96 expectedPrice = _reservationPrice(s, institution, payload.labId, payload.start, payload.end);
        require(payload.price == expectedPrice, "LAB_PRICE_MISMATCH");
        _consumeReservationIntent(requestId, LibIntent.ACTION_DIRECT_BOOKING, payload);

        LibInstitutionalReservation.requestReservation(
            institution, payload.pucHash, payload.labId, payload.start, payload.end
        );
        LibInstitutionalReservationConfirmation._confirmInstitutionalReservationRequestWithPucHash(
            s, institution, expectedKey, payload.pucHash
        );
        emit ReservationIntentProcessed(
            requestId, payload.reservationKey, "DIRECT_BOOKING", payload.pucHash, institution, true, ""
        );
    }

    /// @notice Institutional cancellation of reservation request via intent
    function cancelInstitutionalReservationRequestWithIntent(
        bytes32 requestId,
        ReservationIntentPayload calldata payload
    ) external {
        AppStorage storage s = _s();
        Reservation storage reservation = s.reservations[payload.reservationKey];
        require(reservation.labId != 0, IntentUnknownReservation());
        _onlyInstitutionalBackend(reservation.payerInstitution);
        require(payload.labId == reservation.labId, "LAB_ID_MISMATCH");
        require(payload.start == reservation.start, "RESERVATION_START_MISMATCH");
        require(payload.end == reservation.end, "RESERVATION_END_MISMATCH");
        require(payload.price == reservation.price, "RESERVATION_PRICE_MISMATCH");
        require(_pucHashMatches(s, payload.reservationKey, payload.pucHash), "RESERVATION_PUC_MISMATCH");

        _consumeReservationIntent(requestId, LibIntent.ACTION_CANCEL_REQUEST_BOOKING, payload);

        uint256 cancelledLabId = LibInstitutionalReservation.cancelReservationRequest(
            reservation.payerInstitution, payload.pucHash, payload.reservationKey
        );
        require(cancelledLabId == reservation.labId, "RESERVATION_LAB_ID_MISMATCH");
        emit ReservationIntentProcessed(
            requestId,
            payload.reservationKey,
            "CANCEL_RESERVATION_REQUEST",
            payload.pucHash,
            reservation.payerInstitution,
            true,
            ""
        );
    }

    /// @notice Cancels a confirmed booking via intent
    // State is committed before the final audit event; the library call stays within the Diamond.
    // slither-disable-next-line reentrancy-events
    function cancelInstitutionalBookingWithIntent(
        bytes32 requestId,
        ActionIntentPayload calldata payload
    ) external {
        AppStorage storage s = _s();
        Reservation storage reservation = s.reservations[payload.reservationKey];
        require(reservation.labId != 0, IntentUnknownReservation());
        _onlyInstitutionalBackend(reservation.payerInstitution);
        require(payload.labId == reservation.labId, "LAB_ID_MISMATCH");
        require(payload.price == reservation.price, "RESERVATION_PRICE_MISMATCH");
        require(_pucHashMatches(s, payload.reservationKey, payload.pucHash), "RESERVATION_PUC_MISMATCH");

        _consumeActionIntent(requestId, LibIntent.ACTION_CANCEL_BOOKING, payload);

        uint256 cancelledLabId = LibInstitutionalReservation.cancelBooking(
            reservation.payerInstitution, payload.pucHash, payload.reservationKey
        );
        require(cancelledLabId == reservation.labId, "RESERVATION_LAB_ID_MISMATCH");
        emit ReservationIntentProcessed(
            requestId, payload.reservationKey, "CANCEL_BOOKING", payload.pucHash, reservation.payerInstitution, true, ""
        );
    }
}
