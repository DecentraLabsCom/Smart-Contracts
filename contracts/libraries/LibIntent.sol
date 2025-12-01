// SPDX-License-Identifier: GPL-3.0-or-later
pragma solidity ^0.8.23;

import {ECDSA} from "@openzeppelin/contracts/utils/cryptography/ECDSA.sol";
import {IERC1271} from "@openzeppelin/contracts/interfaces/IERC1271.sol";
import {IntentMeta, IntentState, ReservationIntentPayload, ActionIntentPayload} from "./IntentTypes.sol";
import {LibAppStorage, AppStorage} from "./LibAppStorage.sol";

/// @notice Shared helpers to register and consume intents with EIP-712 verification
library LibIntent {
    using ECDSA for bytes32;

    // EIP-712 constants
    bytes32 internal constant EIP712_DOMAIN_TYPEHASH =
        keccak256("EIP712Domain(string name,string version,uint256 chainId,address verifyingContract)");
    bytes32 internal constant INTENT_META_TYPEHASH =
        keccak256(
            "IntentMeta(bytes32 requestId,address signer,address executor,uint8 action,bytes32 payloadHash,uint256 nonce,uint64 requestedAt,uint64 expiresAt)"
        );
    bytes32 internal constant RESERVATION_PAYLOAD_TYPEHASH =
        keccak256(
            "ReservationIntentPayload(address executor,string schacHomeOrganization,string puc,bytes32 assertionHash,uint256 labId,uint32 start,uint32 end,uint96 price,bytes32 reservationKey)"
        );
    bytes32 internal constant ACTION_PAYLOAD_TYPEHASH =
        keccak256(
            "ActionIntentPayload(address executor,string schacHomeOrganization,string puc,bytes32 assertionHash,uint256 labId,bytes32 reservationKey,string uri,uint96 price,string auth,string accessURI,string accessKey,string tokenURI)"
        );
    bytes32 internal constant NAME_HASH = keccak256("DecentraLabsIntent");
    bytes32 internal constant VERSION_HASH = keccak256("1");
    bytes4 internal constant EIP1271_MAGICVALUE = 0x1626ba7e;

    // Action discriminators (uint8 saves gas versus string)
    uint8 internal constant ACTION_LAB_ADD = 1;
    uint8 internal constant ACTION_LAB_ADD_AND_LIST = 2;
    uint8 internal constant ACTION_LAB_SET_URI = 3;
    uint8 internal constant ACTION_LAB_UPDATE = 4;
    uint8 internal constant ACTION_LAB_DELETE = 5;
    uint8 internal constant ACTION_LAB_LIST = 6;
    uint8 internal constant ACTION_LAB_UNLIST = 7;
    uint8 internal constant ACTION_REQUEST_BOOKING = 8;
    uint8 internal constant ACTION_CANCEL_REQUEST_BOOKING = 9;
    uint8 internal constant ACTION_CANCEL_BOOKING = 10;

    event IntentRegistered(bytes32 indexed requestId, address indexed signer, uint8 action, bytes32 payloadHash);
    event IntentCancelled(bytes32 indexed requestId, address indexed signer);
    event IntentExpired(bytes32 indexed requestId, address indexed signer);

    // ---------------------------------------------------------------------
    // Hash helpers
    // ---------------------------------------------------------------------

    function _domainSeparator() internal view returns (bytes32) {
        return
            keccak256(
                abi.encode(
                    EIP712_DOMAIN_TYPEHASH,
                    NAME_HASH,
                    VERSION_HASH,
                    block.chainid,
                    address(this)
                )
            );
    }

    function hashIntentMeta(IntentMeta memory meta) internal pure returns (bytes32) {
        return
            keccak256(
                abi.encode(
                    INTENT_META_TYPEHASH,
                    meta.requestId,
                    meta.signer,
                    meta.executor,
                    meta.action,
                    meta.payloadHash,
                    meta.nonce,
                    meta.requestedAt,
                    meta.expiresAt
                )
            );
    }

    function hashReservationPayload(ReservationIntentPayload memory payload) internal pure returns (bytes32) {
        return
            keccak256(
                abi.encode(
                    RESERVATION_PAYLOAD_TYPEHASH,
                    payload.executor,
                    keccak256(bytes(payload.schacHomeOrganization)),
                    keccak256(bytes(payload.puc)),
                    payload.assertionHash,
                    payload.labId,
                    payload.start,
                    payload.end,
                    payload.price,
                    payload.reservationKey
                )
            );
    }

    function hashActionPayload(ActionIntentPayload memory payload) internal pure returns (bytes32) {
        return
            keccak256(
                abi.encode(
                    ACTION_PAYLOAD_TYPEHASH,
                    payload.executor,
                    keccak256(bytes(payload.schacHomeOrganization)),
                    keccak256(bytes(payload.puc)),
                    payload.assertionHash,
                    payload.labId,
                    payload.reservationKey,
                    keccak256(bytes(payload.uri)),
                    payload.price,
                    keccak256(bytes(payload.auth)),
                    keccak256(bytes(payload.accessURI)),
                    keccak256(bytes(payload.accessKey)),
                    keccak256(bytes(payload.tokenURI))
                )
            );
    }

    // ---------------------------------------------------------------------
    // Registration
    // ---------------------------------------------------------------------

    function registerReservationIntent(
        IntentMeta calldata meta,
        ReservationIntentPayload calldata payload,
        bytes calldata signature
    ) internal {
        require(
            meta.action == ACTION_REQUEST_BOOKING || meta.action == ACTION_CANCEL_REQUEST_BOOKING,
            "Invalid reservation intent action"
        );
        bytes32 payloadHash = hashReservationPayload(payload);
        _registerIntent(meta, payloadHash, signature);
    }

    function registerActionIntent(
        IntentMeta calldata meta,
        ActionIntentPayload calldata payload,
        bytes calldata signature
    ) internal {
        require(
            meta.action == ACTION_LAB_ADD ||
                meta.action == ACTION_LAB_ADD_AND_LIST ||
                meta.action == ACTION_LAB_SET_URI ||
                meta.action == ACTION_LAB_UPDATE ||
                meta.action == ACTION_LAB_DELETE ||
                meta.action == ACTION_LAB_LIST ||
                meta.action == ACTION_LAB_UNLIST ||
                meta.action == ACTION_CANCEL_BOOKING,
            "Invalid action intent"
        );
        bytes32 payloadHash = hashActionPayload(payload);
        _registerIntent(meta, payloadHash, signature);
    }

    // ---------------------------------------------------------------------
    // Consumption / Cancellation
    // ---------------------------------------------------------------------

    function consumeIntent(
        bytes32 requestId,
        uint8 expectedAction,
        bytes32 expectedPayloadHash,
        address expectedSigner,
        address expectedExecutor
    ) internal {
        AppStorage storage s = LibAppStorage.diamondStorage();
        IntentMeta storage meta = s.intents[requestId];

        if (meta.state == IntentState.None) revert("Intent not registered");
        if (meta.state != IntentState.Pending) revert("Intent not pending");

        if (block.timestamp > meta.expiresAt) {
            meta.state = IntentState.Expired;
            emit IntentExpired(requestId, meta.signer);
            revert("Intent expired");
        }

        require(meta.action == expectedAction, "Action mismatch");
        require(meta.payloadHash == expectedPayloadHash, "Payload hash mismatch");
        require(meta.signer == expectedSigner, "Signer mismatch");
        require(meta.executor == expectedExecutor, "Executor mismatch");

        meta.state = IntentState.Executed;
    }

    function cancelIntent(bytes32 requestId, address caller) internal {
        AppStorage storage s = LibAppStorage.diamondStorage();
        IntentMeta storage meta = s.intents[requestId];
        require(meta.state == IntentState.Pending, "Not pending");
        require(meta.signer == caller, "Only signer");
        meta.state = IntentState.Cancelled;
        emit IntentCancelled(requestId, caller);
    }

    function getIntent(bytes32 requestId) internal view returns (IntentMeta memory) {
        return LibAppStorage.diamondStorage().intents[requestId];
    }

    function nextNonce(address signer) internal view returns (uint256) {
        return LibAppStorage.diamondStorage().intentNonces[signer];
    }

    // ---------------------------------------------------------------------
    // Internal helpers
    // ---------------------------------------------------------------------

    function _registerIntent(
        IntentMeta calldata meta,
        bytes32 calculatedPayloadHash,
        bytes calldata signature
    ) private {
        AppStorage storage s = LibAppStorage.diamondStorage();

        require(meta.requestId != bytes32(0), "requestId required");
        require(meta.signer != address(0) && meta.executor != address(0), "Invalid signer/executor");
        require(meta.executor == meta.signer, "Executor must equal signer");
        require(meta.nonce == s.intentNonces[meta.signer], "Invalid nonce");
        require(meta.payloadHash == calculatedPayloadHash, "Payload hash mismatch");
        require(meta.expiresAt > block.timestamp, "Intent expired");
        require(meta.requestedAt != 0, "requestedAt required");
        require(meta.requestedAt <= block.timestamp, "requestedAt in future");

        IntentMeta storage existing = s.intents[meta.requestId];
        require(existing.state == IntentState.None, "Intent already exists");

        bytes32 structHash = hashIntentMeta(meta);
        bytes32 digest = keccak256(abi.encodePacked("\x19\x01", _domainSeparator(), structHash));
        require(_isValidSignature(meta.signer, digest, signature), "Invalid signature");

        s.intentNonces[meta.signer] = meta.nonce + 1;

        IntentMeta memory stored = meta;
        stored.state = IntentState.Pending;
        s.intents[meta.requestId] = stored;

        emit IntentRegistered(meta.requestId, meta.signer, meta.action, calculatedPayloadHash);
    }

    function _isValidSignature(address signer, bytes32 digest, bytes memory signature) private view returns (bool) {
        if (signer.code.length == 0) {
            return ECDSA.recover(digest, signature) == signer;
        }

        try IERC1271(signer).isValidSignature(digest, signature) returns (bytes4 magicValue) {
            return magicValue == EIP1271_MAGICVALUE;
        } catch {
            return false;
        }
    }
}
