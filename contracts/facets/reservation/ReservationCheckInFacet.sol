// SPDX-License-Identifier: GPL-3.0-or-later
pragma solidity ^0.8.31;

import {ECDSA} from "@openzeppelin/contracts/utils/cryptography/ECDSA.sol";
import {AppStorage, EmergencyCheckInReview, LibAppStorage, Reservation} from "../../libraries/LibAppStorage.sol";
import {LibDiamond} from "../../libraries/LibDiamond.sol";
import {LibReservationIdentity} from "../../libraries/LibReservationIdentity.sol";

/// @title ReservationCheckInFacet
/// @notice Records payer-side on-chain access authorization by moving confirmed reservations to _ACCESS_AUTHORIZED.
/// @dev _ACCESS_AUTHORIZED means AccessAuthorized, not proof that the remote session started.
///      For external labs, the provider backend still issues the technical JWT/ticket separately.
contract ReservationCheckInFacet {
    uint8 internal constant _CONFIRMED = 1;
    uint8 internal constant _ACCESS_AUTHORIZED = 2;

    bytes32 private constant EIP712_DOMAIN_TYPEHASH =
        keccak256("EIP712Domain(string name,string version,uint256 chainId,address verifyingContract)");
    bytes32 private constant CHECKIN_TYPEHASH =
        keccak256("CheckIn(address signer,bytes32 reservationKey,bytes32 pucHash,uint64 timestamp)");
    bytes32 private constant NAME_HASH = keccak256("DecentraLabsIntent");
    bytes32 private constant VERSION_HASH = keccak256("1");

    uint256 internal constant MAX_CHECKIN_DELAY = 5 minutes;

    event ReservationCheckedIn(bytes32 indexed reservationKey, uint256 indexed labId, address indexed checker);
    event ReservationCheckedInByGeneration(
        bytes32 indexed reservationId, bytes32 indexed reservationKey, uint256 indexed labId, address checker
    );

    /// @notice Emitted for the governed emergency access-authorization path.
    event EmergencyCheckIn(
        bytes32 indexed reservationId,
        bytes32 indexed reservationKey,
        uint256 indexed labId,
        uint8 reasonCode,
        address executor,
        uint64 timestamp
    );

    /// @notice Operational alert emitted whenever emergency authorization puts
    /// a reservation on settlement hold.
    event EmergencyCheckInSettlementReviewRequired(
        bytes32 indexed reservationId,
        bytes32 indexed reservationKey,
        uint256 indexed labId,
        uint8 reasonCode,
        address executor,
        uint64 timestamp
    );

    /// @notice Emitted when governance explicitly releases an emergency check-in.
    event EmergencyCheckInSettlementReviewed(
        bytes32 indexed reservationId,
        bytes32 indexed reservationKey,
        uint256 indexed labId,
        address reviewer,
        uint64 timestamp
    );

    /// @notice Governed emergency access authorization for an in-window booking.
    /// @dev The Diamond owner must be a contract controlled by a multisig or
    ///      timelock. Emergency authorization is never emitted as a normal
    ///      check-in event and cannot enter settlement until reviewed.
    function emergencyCheckIn(
        bytes32 reservationKey,
        uint8 reasonCode
    ) external {
        _onlyEmergencyAuthority();
        if (reasonCode == 0) revert("Emergency reason required");

        AppStorage storage s = LibAppStorage.diamondStorage();
        Reservation storage reservation = s.reservations[reservationKey];
        _validateReservationWindow(reservation);

        bytes32 reservationId = LibReservationIdentity.currentReservationId(s, reservationKey);
        reservation.status = _ACCESS_AUTHORIZED;
        LibReservationIdentity.snapshotCurrentReservation(s, reservationKey);
        uint64 timestamp = uint64(block.timestamp);
        s.emergencyCheckInReviews[reservationId] = EmergencyCheckInReview({
            settlementExcluded: true,
            reasonCode: reasonCode,
            executor: msg.sender,
            checkedInAt: timestamp,
            reviewer: address(0),
            reviewedAt: 0
        });

        emit EmergencyCheckIn(reservationId, reservationKey, reservation.labId, reasonCode, msg.sender, timestamp);
        emit EmergencyCheckInSettlementReviewRequired(
            reservationId, reservationKey, reservation.labId, reasonCode, msg.sender, timestamp
        );
    }

    /// @notice Releases an emergency check-in from its settlement hold after review.
    /// @dev The same multisig/timelock authority must explicitly approve the release.
    function reviewEmergencyCheckIn(
        bytes32 reservationKey
    ) external {
        _onlyEmergencyAuthority();

        AppStorage storage s = LibAppStorage.diamondStorage();
        bytes32 reservationId = LibReservationIdentity.currentReservationId(s, reservationKey);
        EmergencyCheckInReview storage review = s.emergencyCheckInReviews[reservationId];
        if (!review.settlementExcluded) revert("Emergency review not pending");

        review.settlementExcluded = false;
        review.reviewer = msg.sender;
        review.reviewedAt = uint64(block.timestamp);
        emit EmergencyCheckInSettlementReviewed(
            reservationId, reservationKey, s.reservations[reservationKey].labId, msg.sender, review.reviewedAt
        );
    }

    /// @notice Returns the governance review state for the current reservation generation.
    function getEmergencyCheckInReview(
        bytes32 reservationKey
    )
        external
        view
        returns (
            bool settlementExcluded,
            uint8 reasonCode,
            address executor,
            uint64 checkedInAt,
            address reviewer,
            uint64 reviewedAt
        )
    {
        AppStorage storage s = LibAppStorage.diamondStorage();
        EmergencyCheckInReview storage review =
            s.emergencyCheckInReviews[LibReservationIdentity.currentReservationId(s, reservationKey)];
        return (
            review.settlementExcluded,
            review.reasonCode,
            review.executor,
            review.checkedInAt,
            review.reviewer,
            review.reviewedAt
        );
    }

    function checkInReservationWithSignature(
        bytes32 reservationKey,
        address signer,
        bytes32 pucHash,
        uint64 timestamp,
        bytes calldata signature
    ) external {
        AppStorage storage s = LibAppStorage.diamondStorage();
        Reservation storage reservation = s.reservations[reservationKey];

        _validateReservationWindow(reservation);
        _validateTimestamp(timestamp);

        bytes32 expectedPucHash = _expectedPucHash(s, reservationKey, reservation);
        if (pucHash != expectedPucHash) revert("Puc hash mismatch");

        bytes32 digest = _hashCheckIn(signer, reservationKey, pucHash, timestamp);
        address recovered = ECDSA.recover(digest, signature);
        if (recovered != signer) revert("Signature mismatch");

        _validateSigner(s, reservation, signer, expectedPucHash);

        reservation.status = _ACCESS_AUTHORIZED;
        LibReservationIdentity.snapshotCurrentReservation(s, reservationKey);
        emit ReservationCheckedIn(reservationKey, reservation.labId, msg.sender);
        emit ReservationCheckedInByGeneration(
            LibReservationIdentity.currentReservationId(s, reservationKey),
            reservationKey,
            reservation.labId,
            msg.sender
        );
    }

    function _validateReservationWindow(
        Reservation storage reservation
    ) private view {
        if (reservation.renter == address(0)) revert("Reservation not found");
        if (reservation.status != _CONFIRMED) revert("Not confirmed");

        uint256 nowTs = block.timestamp;
        // Check-in is intentionally bounded by chain time.
        // slither-disable-next-line timestamp
        if (nowTs < reservation.start || nowTs > reservation.end) revert("Outside reservation window");
    }

    function _onlyEmergencyAuthority() private view {
        if (msg.sender != LibDiamond.contractOwner()) revert("Emergency authority required");

        uint256 codeSize;
        address sender = msg.sender;
        assembly {
            codeSize := extcodesize(sender)
        }
        if (codeSize == 0) revert("Emergency authority must be multisig or timelock");
    }

    function _validateTimestamp(
        uint64 timestamp
    ) private view {
        uint256 nowTs = block.timestamp;
        // Check-in attestations are intentionally bounded by chain time.
        // slither-disable-next-line timestamp
        if (timestamp > nowTs) revert("Timestamp in future");
        // slither-disable-next-line timestamp
        if (nowTs - timestamp > MAX_CHECKIN_DELAY) revert("Signature expired");
    }

    function _validateSigner(
        AppStorage storage s,
        Reservation storage reservation,
        address signer,
        bytes32 expectedPucHash
    ) private view {
        if (expectedPucHash == bytes32(0)) {
            if (signer != reservation.renter) revert("Signer not renter");
            return;
        }

        address institution = reservation.payerInstitution;
        address backend = s.institutionalBackends[institution];
        if (signer != institution && (backend == address(0) || signer != backend)) {
            revert("Signer not institution");
        }
    }

    function _expectedPucHash(
        AppStorage storage s,
        bytes32 reservationKey,
        Reservation storage
    ) private view returns (bytes32) {
        return s.reservationPucHash[LibReservationIdentity.currentReservationId(s, reservationKey)];
    }

    function _hashCheckIn(
        address signer,
        bytes32 reservationKey,
        bytes32 pucHash,
        uint64 timestamp
    ) private view returns (bytes32) {
        bytes32 structHash = keccak256(abi.encode(CHECKIN_TYPEHASH, signer, reservationKey, pucHash, timestamp));
        return keccak256(abi.encodePacked("\x19\x01", _domainSeparator(), structHash));
    }

    function _domainSeparator() private view returns (bytes32) {
        return keccak256(abi.encode(EIP712_DOMAIN_TYPEHASH, NAME_HASH, VERSION_HASH, block.chainid, address(this)));
    }
}
