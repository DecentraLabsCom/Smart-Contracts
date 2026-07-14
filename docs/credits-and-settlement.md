# Service credits and settlement

The active economic model is an internal service-credit ledger. Credits are
accounting units used by the reservation and provider-settlement facets; they
are not an external ERC-20 token and are not native currency held by the
Diamond.

## Credit units

The shared storage library defines:

- 5 decimal places per credit;
- `100,000` raw units per credit;
- a fixed accounting reference of 10 credits per EUR for configured funding
  and reporting paths.

Prices in `LabBase.price` and reservation amounts are raw credit units. Keep
all off-chain conversions explicit and do not silently treat raw units as whole
credits.

## Credit lifecycle

`ServiceCreditFacet` exposes the administrative and reservation-side movement
operations:

| Operation | Effect |
| --- | --- |
| Issue/mint | Creates available credits or a traceable credit lot. |
| Lock | Moves available balance into reservation-locked balance. |
| Capture | Consumes locked credits for a completed reservation. |
| Release | Returns locked credits when a request is denied or released. |
| Cancel | Applies the configured cancellation accounting. |
| Expire | Removes credits from expired lots. |
| Adjust | Records an explicitly referenced administrative correction. |

Every movement is represented in the credit movement audit trail with a kind,
amount, resulting balances, reference and timestamp. Funding lots preserve the
funding order, issue time, expiration and remaining amount; consumption is FIFO
within an account's lots.

## Reservation funding

For an institutional booking, the contract checks the payer institution's
available treasury and user spending policy before the reservation can be
created or confirmed. The exact path depends on whether the payer and provider
are the same institution and whether a direct-booking intent is used.

## Provider revenue

At confirmation, the reservation caches the provider share. The current split is
75% of the reservation price for the provider; the remaining 25% is the platform
margin and is not represented as a separate token balance.

When a reservation is finalized, provider revenue moves through receivable
buckets. `ProviderSettlementFacet` exposes the provider's eligible payout and
settlement operations, while `LibProviderReceivable` keeps accrued, invoiced,
approved, paid, reversed and disputed amounts separate.

Cancellation uses a 5% total fee with a minimum of 0.1 credits where applicable.
The provider allocation is 3% of the price and the remaining cancellation fee is
the platform share. Zero-price reservations do not create a credit movement.
