// SPDX-License-Identifier: GPL-3.0-or-later
pragma solidity ^0.8.33;

/// @notice Lifecycle state for an intent
enum IntentState {
    None,
    Pending,
    Executed,
    Cancelled,
    Expired
}

/// @notice Generic metadata stored for any intent
struct IntentMeta {
    bytes32 requestId;      // unique intent identifier (signed off-chain)
    address signer;         // address that signed the intent
    address executor;       // address that must execute the action (equals signer in this flow)
    uint8 action;           // numeric action discriminator
    bytes32 payloadHash;    // keccak256 hash of the payload struct
    uint256 nonce;          // signer-scoped nonce to avoid replay
    uint64 requestedAt;     // timestamp provided by signer
    uint64 expiresAt;       // deadline for execution
    IntentState state;      // lifecycle flag stored on-chain
}

/// @notice Payload used for reservation-related intents (request/cancel request)
struct ReservationIntentPayload {
    address executor;               // same as signer
    string schacHomeOrganization;   // optional org identifier
    string puc;                     // SAML schacPersonalUniqueCode
    bytes32 assertionHash;          // off-chain assertion hash (optional)
    uint256 labId;
    uint32 start;
    uint32 end;
    uint96 price;
    bytes32 reservationKey;         // precalculated key if available (labId + start)
}

/// @notice Payload used for lab actions and booking cancellations
struct ActionIntentPayload {
    address executor;               // same as signer
    string schacHomeOrganization;   // optional org identifier
    string puc;                     // SAML schacPersonalUniqueCode
    bytes32 assertionHash;          // off-chain assertion hash (optional)
    uint256 labId;
    bytes32 reservationKey;         // optional (for booking cancellation)
    string uri;                     // lab URI (for add/update)
    uint96 price;                   // lab price (for add/update)
    uint96 maxBatch;                // batch size for requestFunds intent (reuses action payload)
    string auth;                    // auth URI (for add/update)
    string accessURI;               // access URI (for add/update)
    string accessKey;               // access key (for add/update)
    string tokenURI;                // token URI (for setTokenURI)
}
