# Architecture

DecentraLabs uses one EIP-2535 Diamond as the on-chain entry point. The
Diamond owns the storage and delegates function calls to facet contracts. A
facet can be added, replaced or removed without changing the address that
Marketplace, `blockchain-services` or indexers use.

## Runtime layout

```text
Users, institutions and authorized backends
                    |
                    v
          DecentraLabs Diamond
          |       |       |
       labs   reservations  credits/settlement
          \       |       /
           shared AppStorage
```

`contracts/Diamond.sol` contains the fallback that resolves a function selector
to a facet and executes it with `delegatecall`. `contracts/libraries/LibDiamond.sol`
stores the selector-to-facet routing and ownership data. Domain state is kept in
`LibAppStorage.AppStorage` at the fixed application storage position.

## Facet groups

| Group | Responsibilities |
| --- | --- |
| Diamond core | Ownership, loupe queries, and `diamondCut` upgrades. |
| Initialization | First-time and reinitializer flows through `InitFacet` and initializer contracts. |
| Providers | Provider accounts, provider metadata, authorized backends and network status. |
| Labs | ERC-721 lab assets, metadata URI, listing, updates, transfers and reputation. |
| Reservations | Calendar availability, reservation state transitions, institutional requests and queries. |
| Access | On-chain authorization and SessionStarted evidence for settlement. |
| Credits | Service-credit issuance, lots, locks, captures, releases, expiry and audit movements. |
| Settlement | Provider receivables, batches, payout collection and settlement accounting. |
| Intents | Request/action intent registration, nonce management and one-time consumption. |

The complete source mapping is in the [facet reference](reference/facets.md).

## Upgrade boundary

Only the Diamond owner may call `diamondCut`. A cut may add, replace or remove
selectors and may execute an initializer using `delegatecall`. Upgrade scripts
must therefore be treated as privileged production operations:

1. Build the facet and regenerate its ABI.
2. Verify selectors and inheritance before preparing the cut.
3. Use an initializer when storage needs to be populated.
4. Simulate and test the cut before broadcasting it.
5. Record the resulting Diamond and facet addresses in the deployment artifact.

The Diamond deliberately has no `receive()` function. Bare native-asset
transfers revert instead of leaving funds without a contract operation.

## Cross-project boundaries

- **Marketplace** reads lab and reservation state through the Diamond ABI and
  builds user-facing booking/intents.
- **`blockchain-services`** is the institutional backend that validates identity
  and reservation context, then submits signed transactions through its wallet
  and outbox infrastructure.
- **Lab Gateway** enforces access to the provider resource after the backend
  authorizes the reservation.
- **Lab-Metadata** stores the off-chain JSON document referenced by `LabBase.uri`.

The contract is the authority for ownership, price, reservation timestamps,
reservation status, credit balances and settlement state. Off-chain documents
are descriptive and must not be used to override those values.
