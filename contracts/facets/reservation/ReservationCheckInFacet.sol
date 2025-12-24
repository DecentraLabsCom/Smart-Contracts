// SPDX-License-Identifier: GPL-3.0-or-later
pragma solidity ^0.8.31;

import {ECDSA} from "@openzeppelin/contracts/utils/cryptography/ECDSA.sol";
import {EnumerableSet} from "@openzeppelin/contracts/utils/structs/EnumerableSet.sol";
import {LibAppStorage, AppStorage, Reservation} from "../../libraries/LibAppStorage.sol";

/// @title ReservationCheckInFacet
/// @notice Allows lab owners or their authorized backends to mark reservations as in use
contract ReservationCheckInFacet {
    using EnumerableSet for EnumerableSet.AddressSet;

    uint8 internal constant _CONFIRMED = 1;
    uint8 internal constant _IN_USE = 2;

    bytes32 private constant EIP712_DOMAIN_TYPEHASH =
        keccak256("EIP712Domain(string name,string version,uint256 chainId,address verifyingContract)");
    bytes32 private constant CHECKIN_TYPEHASH =
        keccak256("CheckIn(address signer,bytes32 reservationKey,bytes32 pucHash,uint64 timestamp)");
    bytes32 private constant NAME_HASH = keccak256("DecentraLabsIntent");
    bytes32 private constant VERSION_HASH = keccak256("1");

    uint256 internal constant MAX_CHECKIN_DELAY = 5 minutes;

    event ReservationCheckedIn(bytes32 indexed reservationKey, uint256 indexed labId, address indexed checker);

    modifier onlyDefaultAdminRole() {
        AppStorage storage s = LibAppStorage.diamondStorage();
        if (!s.roleMembers[s.DEFAULT_ADMIN_ROLE].contains(msg.sender)) {
            revert("Only default admin");
        }
        _;
    }

    function checkInReservation(bytes32 reservationKey) external onlyDefaultAdminRole {
        AppStorage storage s = LibAppStorage.diamondStorage();
        Reservation storage reservation = s.reservations[reservationKey];
        _validateReservationWindow(reservation);
        reservation.status = _IN_USE;
        emit ReservationCheckedIn(reservationKey, reservation.labId, msg.sender);
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

        bytes32 expectedPucHash = _expectedPucHash(reservation);
        if (pucHash != expectedPucHash) revert("Puc hash mismatch");

        bytes32 digest = _hashCheckIn(signer, reservationKey, pucHash, timestamp);
        address recovered = ECDSA.recover(digest, signature);
        if (recovered != signer) revert("Signature mismatch");

        _validateSigner(s, reservation, signer, expectedPucHash);

        reservation.status = _IN_USE;
        emit ReservationCheckedIn(reservationKey, reservation.labId, msg.sender);
    }

    function _validateReservationWindow(Reservation storage reservation) private view {
        if (reservation.renter == address(0)) revert("Reservation not found");
        if (reservation.status != _CONFIRMED) revert("Not confirmed");

        uint256 nowTs = block.timestamp;
        if (nowTs < reservation.start || nowTs > reservation.end) revert("Outside reservation window");
    }

    function _validateTimestamp(uint64 timestamp) private view {
        uint256 nowTs = block.timestamp;
        if (timestamp > nowTs) revert("Timestamp in future");
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

    function _expectedPucHash(Reservation storage reservation) private view returns (bytes32) {
        if (bytes(reservation.puc).length == 0) {
            return bytes32(0);
        }
        return keccak256(bytes(reservation.puc));
    }

    function _hashCheckIn(
        address signer,
        bytes32 reservationKey,
        bytes32 pucHash,
        uint64 timestamp
    ) private view returns (bytes32) {
        bytes32 structHash = keccak256(
            abi.encode(CHECKIN_TYPEHASH, signer, reservationKey, pucHash, timestamp)
        );
        return keccak256(abi.encodePacked("\x19\x01", _domainSeparator(), structHash));
    }

    function _domainSeparator() private view returns (bytes32) {
        return keccak256(
            abi.encode(
                EIP712_DOMAIN_TYPEHASH,
                NAME_HASH,
                VERSION_HASH,
                block.chainid,
                address(this)
            )
        );
    }
}
