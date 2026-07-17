# Storage and data types

The application state is centralized in `LibAppStorage.AppStorage`. Every facet
that reads or writes domain state must use the same storage position through
`LibAppStorage.diamondStorage()`.

## Main records

| Record | Purpose |
| --- | --- |
| `ProviderBase` / `Provider` | Provider profile and account. |
| `LabBase` / `Lab` | ERC-721 lab configuration and query wrapper. |
| `Reservation` | Reservation identity, timestamps, status, payer/collector and provider share. |
| `ReservationSession` | Hashed SessionStarted evidence bound to a reservation. |
| `CreditLot` | Traceable credit issuance and FIFO remaining balance. |
| `CreditMovement` | Audit record for credit changes. |
| `LabReputation` | Score and event counters for a lab. |
| `InstitutionalUserSpending` | Current-period and historical institution-user spending. |
| `ProviderNetworkStatus` | Provider participation state. |

## Storage invariants

- Existing `AppStorage` members must not be reordered or removed in an upgrade.
- New state is appended at the end of the storage struct.
- Reservation and credit indexes must be updated together with the primary
  record; read helpers rely on those indexes for bounded queries.
- Institutional reservations use a hashed PUC identity and derived tracking
  keys rather than exposing the original institutional identifier on-chain.
- Credit movements and provider receivable transitions require an explicit
  reference where the public operation defines one.

## Time and amounts

Reservation timestamps are Unix seconds and stored in the widths defined by the
Solidity structs. Credit amounts are unsigned raw units with five decimal places
per credit. Off-chain callers must validate arithmetic before narrowing values
to the contract's bounded integer types.

The interval tree stores active exclusive reservations by time range. Heaps and
recent/past buffers support bounded reservation queries and payout processing
without requiring a full unbounded scan.
