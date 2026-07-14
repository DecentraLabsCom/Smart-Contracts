# Institutional access and check-in

Institutional access is split into two on-chain facts:

1. the reservation becomes `ACCESS_AUTHORIZED`; and
2. the provider/backend records cryptographic evidence that the session started.

Keeping these facts separate prevents an authorization transaction from being
mistaken for proof that a remote connection was actually established.

## Authorization

`ReservationCheckInFacet` moves a confirmed reservation to
`ACCESS_AUTHORIZED` after validating the institution, reservation and identity
context required by the selected flow. The status remains active until the
reservation is finalized.

## SessionStarted evidence

`ReservationSessionFacet` stores a reservation-scoped session record containing
the protocol's hashed identifiers and timestamps, including:

- signer/provider identity;
- gateway and session identifiers;
- access type;
- start timestamp;
- one-time nonce;
- credential hash;
- client proof hash.

The signed payload is domain-separated with the chain ID and Diamond address.
The contract validates the reservation window, provider signer, PUC hash, lab
identifier and nonce/observation uniqueness before recording the evidence.

The session record is durable protocol evidence, not a bearer credential. Raw
JWTs, passwords and private keys must remain off-chain.

## Intent-based execution

Institutional backends can submit one-time intents for reservation and action
operations. An intent binds a request ID, action code, payload hash, executor
and signer nonce. The contract consumes it exactly once and rejects mismatched
or replayed payloads.

See the [intent registry reference](reference/intents.md) for the intent
boundary and the [reservations guide](reservations.md) for the state machine.

## Settlement requirement

Provider settlement only treats an access-authorized reservation as eligible
when the required SessionStarted evidence is present. If an access flow fails
after authorization, operators must reconcile the attestation and settlement
state rather than manually changing the reservation status.
