# Service credits and settlement

## Economic model

Service credits are internal accounting units. They are not native currency,
an ERC-20 token, or an externally redeemable balance held by the Diamond.
Prices, reservations and provider receivables use raw credit units.

| Constant | Value | Meaning |
| --- | ---: | --- |
| Credit decimals | `7` | Display precision for one service credit. |
| Raw units per credit | `10,000,000` | Conversion from whole credits to stored amount. |
| Accounting reference | `10` credits/EUR | Reference used for configured funding and reporting paths. |
| Default user limit | `100,000,000` raw units | Ten credits per institutional spending period. |
| Default spending period | `120 days` | Used when an institution has not configured another duration. |

Keep conversion at the integration boundary. A `LabBase.price` is a raw amount
per second, and the reservation price is the raw total for the booked duration.
The canonical scale is 7 decimals: `10,000,000` raw units equal one
credit, so one raw unit per second equals `0.00036` credits per hour. UIs and
services must use the shared conversion helpers instead of hard-coded scale
constants.

### Scale migration

The seven-decimal scale is a representation change at the raw-unit boundary.
Existing SQL credit amounts are human-readable credits and only need the
`DECIMAL(24,7)` precision migration; they must not be multiplied by 100. Existing
on-chain balances do need an explicit administrative adjustment by a factor of
100 when their old five-decimal raw value is being preserved. Existing lab prices
must be recalculated from the intended human price using nearest-integer
per-second conversion; expired reservations are not rewritten by this migration.

## Credit lifecycle and provenance

```mermaid
flowchart LR
    F[Funding order] --> M[Mint credit lot]
    M --> A[Available credits]
    A --> L[Lock, when the operation uses a lock]
    L --> C[Capture]
    A --> C
    C --> R[Reservation source allocations]
    R --> X[Cancellation refund]
    X --> A
    M --> E[Expiry of remaining lot balance]
```

Each mint creates a `CreditLot` with a funding-order reference, EUR gross basis,
issue time, optional expiry and remaining amount. Consumption is FIFO across
available, non-expired lots. Every ledger movement records its kind, amount,
resulting available/locked balances, reference and timestamp.

| Movement | Accounting effect |
| --- | --- |
| `MINT` | Creates a traceable funding lot and available balance. |
| `LOCK` / `RELEASE` | Moves value into or out of the locked balance without consuming a lot. |
| `CAPTURE` | Consumes locked value from lots in FIFO order. |
| `CANCEL` | Refunds a previously allocated reservation amount. |
| `EXPIRE` | Removes a lot's remaining balance. |
| `ADJUST` | Records a referenced administrative correction. |

`ServiceCreditFacet` exposes the administrative ledger API and protects writes
with the default-admin role. Institutional booking uses the treasury path from
the reservation facets; clients should not substitute an arbitrary ledger call
for reservation confirmation.

The ledger bounds new state growth to 128 physical lots per account. Before an
append at that bound, spent/zero lots are removed and compatible lots are
merged when their funding order, expiry and remaining EUR-per-credit basis
match. `compactCreditLots(account)` is available for explicit maintenance of
legacy accounts. A capture can create at most 64 source allocations for one
reservation; a larger legacy refund must use `cancelCreditsBatch`, which
processes at most 32 allocations and returns a cursor for the next call.

## Reservation allocations and refunds

When a reservation consumes credits, the contract persists a
`CreditReservationAllocation` for every source lot. It retains the funding
order, amount, proportional EUR basis, expiry and the separately tracked refund
amounts. This lets reconciliation connect a reservation charge or refund to its
original funding provenance.

Use `getCreditReservationAllocations(account, reservationRef, offset, limit)`
for that evidence. Credit lots, movements and allocations are paginated and the
public facet caps each response at 50 records. Refunds cannot exceed the
recorded allocations and keep the original expiry context, so a cancellation
cannot create perpetual credits from an expiring lot.

## Institutional spending and cancellation

Reservation confirmation checks the payer institution's available balance and
the PUC-scoped spending allowance. The successful charge records the spending
period used by that reservation, allowing a later refund to reconcile the same
period correctly.

For an eligible consumer cancellation before the start time on a physical lab,
the current policy charges a total fee of 10% with a minimum of 0.1 credits (or
the entire price when it is lower). Three fifths of that fee go to the provider,
equivalent to 6% of the price when the percentage fee applies; the remaining 4%
is the implicit platform margin. Simulations have no cancellation fee and refund
the full price. A zero-price reservation creates no credit movement. A
provider-initiated cancellation refunds the full price and does not accrue a
provider cancellation fee. It does, however, affect lab reputation: a
cancellation with at least 24 hours' notice applies -1, one with less than 24
hours' notice applies -2, and an explicit provider service-failure report
applies -3.

The service-failure path is only available while the reservation is still
active and its one-day `SessionStarted` attestation grace period remains open.
It requires that no `SessionStarted` evidence exists, so a payer no-show is not
automatically attributed to the provider. A technical denial of a pending
request does not carry this penalty.

Always call `previewInstitutionalBookingCancellation` before presenting a
confirmation screen. It returns the actual current fee, refund, spending-period
data and source expiry, rather than an off-chain estimate. The preview is a
bounded summary and intentionally returns an empty `allocations` array; query
the provenance with `getCreditReservationAllocations` in pages (use
`offset=0, limit=0` when only the allocation count is needed).

## Provider receivable and claim lifecycle

Provider revenue is a receivable, not a token payout. On successful finalization
with SessionStarted evidence, the reservation's cached provider share is added
to the lab's accrued receivable. `requestProviderPayout` processes a bounded
batch of eligible records and moves the entire accrued bucket into the
settlement queue. This also queues receivables that a previous permissionless
release, cap cleanup or reconciliation already accrued after removing the
reservation from the payout heap. An access-authorized reservation still inside
the attestation grace remains available for late `SessionStarted` evidence, but
bounded payout-heap scans do not let it block later settleable reservations.

All reservation finalization routes use the same economic transition: the
permissionless release, the per-user cap cleanup and provider payout share the
attestation deadline, refund/receivable decision, reputation update, counter
decrement and index/heap cleanup. An `ACCESS_AUTHORIZED` reservation without
`SessionStarted` is not refunded before the one-day grace period expires.

For a physical lab without `SessionStarted` after that deadline, the no-show
settlement retains 25%: 15% becomes provider receivable and 10% remains the
implicit platform margin; the remaining 75% is refunded. A simulation without
evidence is refunded in full.

```mermaid
stateDiagram-v2
    [*] --> ACCRUED: eligible reservation finalizes
    ACCRUED --> QUEUED: requestProviderPayout
    QUEUED --> INVOICED: submitProviderSettlementClaim
    INVOICED --> APPROVED: approveProviderSettlementClaim
    APPROVED --> PAID: recordProviderSettlementClaimPayment
```

The receivable read exposes `ACCRUED`, `QUEUED`, `INVOICED`, `APPROVED`, `PAID`,
`REVERSED` and `DISPUTED` buckets. A settlement claim has a unique non-zero
`claimId`, a lab, amount, reservation-scope hash and invoice-reference hash.
Submitting it atomically moves the claimed amount from `QUEUED` to `INVOICED`.
Approval requires a non-zero, previously unused external reference. Invoice
references are also unique at the contract boundary, so SQL uniqueness cannot
create a second claim with the same financial identity. Payment requires a
non-zero, previously unused payment reference plus an attestation hash, then
moves the claim from `APPROVED` to `PAID`.

Use `getLabProviderReceivableLifecycle` for aggregate amounts and
`getProviderSettlementClaim` for the audit record. Claim and financial
transitions are restricted to the current provider/authorized backend, a
configured settlement operator, or the default admin as defined by the facet.
The generic `transitionProviderReceivableState` selector is recovery-only for
the claim lifecycle: it cannot create `INVOICED`, `APPROVED` or `PAID` balance
states. Ordinary settlement must use the claim selectors; generic recovery may
move an existing bucket to `DISPUTED` or `REVERSED` with its non-zero audit
reference.

For the payout preview, `getLabProviderReceivable` returns four separate
values: provider payout from attested sessions, the potential provider fee
from finalizable physical-lab no-shows, the count of access-authorized
reservations still inside the SessionStarted grace period, and the already
outstanding receivable. The grace count is not included in the payout amount;
the three monetary values are the actionable preview. The paginated variant
returns the same categories per heap chunk.
