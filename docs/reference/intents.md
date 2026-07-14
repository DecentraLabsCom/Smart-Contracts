# Intent registry

The intent registry provides one-time authorization for institution-driven
operations. An intent is not a reservation and does not itself move credits; it
binds an authorized payload to an executor and allows the matching operation to
be consumed once.

## Intent lifecycle

1. The authorized signer registers a reservation or action intent with a request
   ID, action code, payload hash and nonce.
2. The institution or configured backend submits the matching operation.
3. The facet recomputes the payload hash, checks the executor and authorization,
   and consumes the intent.
4. A second submission or a payload mismatch reverts.

`IntentRegistryFacet` exposes registration, cancellation, lookup and nonce
operations. `ReservationIntentFacet` applies those checks to institutional
booking, direct booking and cancellation operations.

## Payload binding

Reservation payloads bind the lab, reservation key, time range, expected price,
PUC hash and executor context. Action payloads bind the reservation and the
action-specific fields. The contract also checks that the reservation key and
price agree with current on-chain state before applying the action.

## Integration guidance

- Persist the request ID and nonce with the off-chain operation.
- Retry the same signed payload when delivery fails; do not create a second
  intent for the same business operation unless the original is explicitly
  cancelled or expired by the protocol.
- Treat a successful transaction receipt as the source of truth for intent
  consumption.
- Keep raw signatures and private keys out of metadata and application logs.
