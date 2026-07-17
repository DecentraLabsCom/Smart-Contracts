// SPDX-License-Identifier: GPL-3.0-or-later
pragma solidity ^0.8.33;

import {ECDSA} from "@openzeppelin/contracts/utils/cryptography/ECDSA.sol";
import {AppStorage, LibAppStorage, Reservation, ReservationSession} from "../../libraries/LibAppStorage.sol";
import {LibERC721Storage} from "../../libraries/LibERC721Storage.sol";

/// @title ReservationSessionFacet
/// @notice Records provider-signed proof that the lab session actually started after payer access authorization.
contract ReservationSessionFacet {
    uint8 internal constant _ACCESS_AUTHORIZED = 2;

    bytes32 private constant EIP712_DOMAIN_TYPEHASH =
        keccak256("EIP712Domain(string name,string version,uint256 chainId,address verifyingContract)");
    bytes32 private constant SESSION_STARTED_TYPEHASH = keccak256(
        "SessionStarted(address signer,bytes32 reservationKey,bytes32 labIdHash,bytes32 pucHash,bytes32 gatewayIdHash,bytes32 sessionIdHash,bytes32 accessTypeHash,uint64 startedAt,bytes32 nonce,bytes32 credentialHash,bytes32 clientProofHash)"
    );
    bytes32 private constant NAME_HASH = keccak256("DecentraLabsSession");
    bytes32 private constant VERSION_HASH = keccak256("1");

    struct SessionStartedInput {
        address signer;
        bytes32 reservationKey;
        string labId;
        bytes32 pucHash;
        string gatewayId;
        string sessionId;
        string accessType;
        uint64 startedAt;
        bytes32 nonce;
        bytes32 credentialHash;
        bytes32 clientProofHash;
        bytes signature;
    }

    event ReservationSessionStarted(
        bytes32 indexed reservationKey,
        uint256 indexed labId,
        address indexed signer,
        bytes32 gatewayIdHash,
        bytes32 sessionIdHash,
        bytes32 accessTypeHash,
        uint64 startedAt,
        bytes32 nonce,
        bytes32 credentialHash,
        bytes32 clientProofHash
    );

    function markSessionStarted(
        SessionStartedInput calldata input
    ) external {
        AppStorage storage s = LibAppStorage.diamondStorage();
        Reservation storage reservation = s.reservations[input.reservationKey];

        _validateReservation(s, reservation, input);

        bytes32 gatewayIdHash = keccak256(bytes(input.gatewayId));
        bytes32 sessionIdHash = keccak256(bytes(input.sessionId));
        bytes32 accessTypeHash = keccak256(bytes(input.accessType));
        bytes32 observationKey = keccak256(abi.encode(sessionIdHash, accessTypeHash));

        if (s.reservationSessionStartedRecorded[input.reservationKey]) revert("Session already started");
        if (s.sessionStartedNonceUsed[input.nonce]) revert("Nonce already used");
        if (s.sessionStartedObservationUsed[observationKey]) revert("Session already used");

        bytes32 digest = _hashSessionStarted(input, gatewayIdHash, sessionIdHash, accessTypeHash);
        address recovered = ECDSA.recover(digest, input.signature);
        if (recovered != input.signer) revert("Signature mismatch");

        s.reservationSessionStarted[input.reservationKey] = ReservationSession({
            signer: input.signer,
            gatewayIdHash: gatewayIdHash,
            sessionIdHash: sessionIdHash,
            accessTypeHash: accessTypeHash,
            startedAt: input.startedAt,
            nonce: input.nonce,
            credentialHash: input.credentialHash,
            clientProofHash: input.clientProofHash
        });
        s.reservationSessionStartedRecorded[input.reservationKey] = true;
        s.sessionStartedNonceUsed[input.nonce] = true;
        s.sessionStartedObservationUsed[observationKey] = true;

        emit ReservationSessionStarted(
            input.reservationKey,
            reservation.labId,
            input.signer,
            gatewayIdHash,
            sessionIdHash,
            accessTypeHash,
            input.startedAt,
            input.nonce,
            input.credentialHash,
            input.clientProofHash
        );
    }

    function getReservationSessionStarted(
        bytes32 reservationKey
    ) external view returns (ReservationSession memory) {
        return LibAppStorage.diamondStorage().reservationSessionStarted[reservationKey];
    }

    function hasReservationSessionStarted(
        bytes32 reservationKey
    ) external view returns (bool) {
        return LibAppStorage.diamondStorage().reservationSessionStartedRecorded[reservationKey];
    }

    function _validateReservation(
        AppStorage storage s,
        Reservation storage reservation,
        SessionStartedInput calldata input
    ) private view {
        if (reservation.renter == address(0)) revert("Reservation not found");
        if (reservation.status != _ACCESS_AUTHORIZED) revert("Access not authorized");
        if (input.startedAt < reservation.start || input.startedAt > reservation.end) {
            revert("Outside reservation window");
        }
        // forge-lint: disable-next-line(block-timestamp)
        // slither-disable-next-line timestamp
        if (input.startedAt > block.timestamp) revert("StartedAt in future");
        if (keccak256(bytes(input.labId)) != keccak256(bytes(_uintToString(reservation.labId)))) {
            revert("LabId mismatch");
        }
        if (input.pucHash != s.reservationPucHash[input.reservationKey]) revert("Puc hash mismatch");

        address provider = LibERC721Storage.ownerOf(reservation.labId);
        if (input.signer != provider) revert("Signer not provider");
    }

    function _hashSessionStarted(
        SessionStartedInput calldata input,
        bytes32 gatewayIdHash,
        bytes32 sessionIdHash,
        bytes32 accessTypeHash
    ) private view returns (bytes32) {
        bytes32 structHash = keccak256(
            abi.encode(
                SESSION_STARTED_TYPEHASH,
                input.signer,
                input.reservationKey,
                keccak256(bytes(input.labId)),
                input.pucHash,
                gatewayIdHash,
                sessionIdHash,
                accessTypeHash,
                input.startedAt,
                input.nonce,
                input.credentialHash,
                input.clientProofHash
            )
        );
        return keccak256(abi.encodePacked("\x19\x01", _domainSeparator(), structHash));
    }

    function _domainSeparator() private view returns (bytes32) {
        return keccak256(abi.encode(EIP712_DOMAIN_TYPEHASH, NAME_HASH, VERSION_HASH, block.chainid, address(this)));
    }

    function _uintToString(
        uint256 value
    ) private pure returns (string memory) {
        if (value == 0) {
            return "0";
        }

        uint256 temp = value;
        uint256 digits;
        while (temp != 0) {
            digits++;
            temp /= 10;
        }

        bytes memory buffer = new bytes(digits);
        while (value != 0) {
            digits -= 1;
            // forge-lint: disable-next-line(unsafe-typecast)
            buffer[digits] = bytes1(uint8(48 + uint256(value % 10)));
            value /= 10;
        }
        return string(buffer);
    }
}
