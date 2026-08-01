# Institutional access and session evidence

## Two separate facts

The contract deliberately separates authorization to access a lab from proof
that a remote session started. `ACCESS_AUTHORIZED` is not enough to earn a
provider receivable.

```mermaid
sequenceDiagram
    participant I as Institution / backend
    participant D as Diamond
    participant G as Provider gateway
    I->>D: Confirmed reservation
    I->>D: emergencyCheckIn or signed check-in
    D-->>I: ACCESS_AUTHORIZED
    G->>G: Open off-chain session
    G->>D: markSessionStarted(provider signature)
    D-->>G: Hash-only session evidence recorded
    Note over D: Finalization uses status + evidence
```

JWTs, SAML assertions, passwords and raw session IDs stay off-chain. The
contract stores only the protocol fields and hashes needed to verify and audit
the evidence.

## Check-in: authorization

`ReservationCheckInFacet` moves a reservation from `CONFIRMED` to
`ACCESS_AUTHORIZED` only inside its reservation window. The normal signature
path accepts an EIP-712 check-in signed by:

- the renter for a non-institutional record; or
- the payer institution or its authorized backend for an institutional record.

The signature binds signer, reservation key, PUC hash, chain ID and Diamond
address. Its timestamp must not be in the future or more than five minutes old.
The gateway still performs the technical access flow independently.

The exceptional `emergencyCheckIn(bytes32,uint8)` selector is not a default-admin
operation. It is callable only by the Diamond owner when that owner is a contract
address, so production governance must be an approved multisig or timelock. A
non-zero reason code is mandatory. The operation emits `EmergencyCheckIn` and
`EmergencyCheckInSettlementReviewRequired`; it does not emit the normal
`ReservationCheckedIn` events. The reservation generation is excluded from all
provider settlement paths until governance calls `reviewEmergencyCheckIn`.

### Trust boundary and WebAuthn

WebAuthn is an off-chain institutional-backend control. The Diamond does not
parse or verify a WebAuthn assertion. The intent path verifies the caller,
executor, action, payload hash, registered intent, nonce and expiry; the
backend verifies SAML and WebAuthn before it reaches that path. Consequently,
WebAuthn protects the user only while the institutional backend and its signing
wallet are acting as honest authorities. It is not a cryptographic control
against compromise of that backend or wallet.

The reservation selectors must not be conflated:

| Selector | Current role | WebAuthn/intent property |
| --- | --- | --- |
| `institutionalDirectBookingWithIntent` | Active `DIRECT_BOOKING` path for an institution-owned lab; atomically requests and confirms | Requires a pending action-11 intent; WebAuthn remains an off-chain backend gate |
| `institutionalReservationRequestWithIntent` | Active `REQUEST_BOOKING` path for an external lab | Requires a pending action-8 intent; WebAuthn remains an off-chain backend gate |

The current Marketplace and canonical `Lab Gateway/blockchain-services` code
call the two `*WithIntent` selectors. The former direct selector had no active
caller and has been removed from the production selector manifest and ABI. A
reviewed Diamond upgrade is still required for already deployed instances.

The Marketplace registers the intent and creates the backend authorization
session before the user completes WebAuthn. That ordering is intentional for
latency and does not make the intent a proof of WebAuthn. If the backend or its
wallet is compromised, it can use its institution/backend authority without a
user's WebAuthn assertion. The current threat model therefore treats that
backend and wallet as the institution's trusted authority and relies on key
custody, least privilege, audit and segregation of duties. A stronger threat
model would require a separate attestor or second authorization signature;
removing the unused direct reservation route does not change that trust
assumption for the intent paths.

There is no default-admin check-in override. Emergency access is intentionally a
separate governed surface with an explicit audit event and a settlement hold.

## SessionStarted: proof

`ReservationSessionFacet.markSessionStarted` accepts provider-signed EIP-712
evidence only after access has been authorized. The input binds the reservation
key, string form of the lab ID, PUC hash, gateway/session/access-type hashes,
start time, nonce, credential hash and client-proof hash.

The contract verifies all of the following:

- the reservation is `ACCESS_AUTHORIZED` and `startedAt` is inside its window;
- the signer is the current ERC-721 lab owner;
- PUC and lab ID match the reservation;
- the attestation is not future-dated and is submitted no later than the
  reservation's `end + 1 day` session-attestation deadline;
- the reservation, nonce and gateway/session/access-type observation have not
  already been used.

Only hash values are persisted. Reusing a credential, nonce or observed session
across reservations is rejected by the corresponding uniqueness guard.

## Economic consequence

After the reservation ends, permissionless finalization waits through the
session-attestation deadline. An access-authorized reservation with valid
SessionStarted evidence can accrue provider revenue and contributes to
completion reputation. If that evidence never arrives, finalization refunds the
priced reservation instead of treating access authorization as proof of service.
