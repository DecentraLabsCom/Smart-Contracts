# DecentraLabs Smart Contracts

This repository contains the current DecentraLabs on-chain protocol: one
EIP-2535 Diamond for labs, institutional reservations, internal service-credit
accounting, access evidence and provider settlement.

## Protocol at a glance

- A lab is a provider-managed ERC-721 token with an on-chain price, resource
  type and access-routing identifiers.
- The Diamond delegates each approved selector to a facet while all domain
  state remains in shared `AppStorage`.
- The canonical booking write paths are institutional. The active Marketplace
  flow uses one-time intents; the Diamond also retains direct institutional
  cancellation selectors for the registered backend. These selectors are not
  WebAuthn-aware. See `docs/institutional-access.md` for the trust boundary and
  `DIRECT_BOOKING` selector mapping.
- Service credits are internal, non-refundable accounting units; the protocol
  has no active external `$LAB` token settlement flow.
- A provider receivable is earned only after the reservation lifecycle and the
  required session evidence permit settlement.
- `resourceType = 0` is an exclusive physical/remote resource. `resourceType = 1`
  is the concurrent FMU path.

## Documentation

Start with the [documentation guide](docs/README.md), or browse the complete
[table of contents](SUMMARY.md). The most common entry points are:

- [Architecture](docs/architecture.md)
- [Labs and metadata](docs/labs.md)
- [Reservations](docs/reservations.md)
- [Service credits and settlement](docs/credits-and-settlement.md)
- [Deployment](docs/deployment.md)
- [Facets and public API](docs/reference/facets.md)

## Source of truth

Solidity source, Foundry tests and `selectors/diamond.json` define the
protocol. `abi/Diamond.json` is the generated integration ABI; deployment JSON
contains network-specific addresses. The separate
[Lab-Metadata repository](https://github.com/DecentraLabsCom/Lab-Metadata)
defines the off-chain JSON schema and does not alter on-chain state.

## Quick verification

```powershell
forge build
forge fmt --check
forge test
npm run verify:contract-surface
npm run verify:repo-consistency
npm run docs:check
```

## Testing layers

- `forge test` runs the Solidity unit, component and Diamond integration tests.
- `forge test --match-path test/FullDiamondSurfaceIntegration.t.sol` runs the
  production-cut proxy smoke tests. The fixture installs all 28 production
  facets and checks all 201 selectors through the Diamond loupe.
- `forge test --match-path test/FullDiamondPublicBehaviorIntegration.t.sol`
  exercises the public Diamond surface with behavior, authorization/error,
  ERC-721, institutional, reservation, settlement and fuzz tests.
- `forge test --match-path test/EconomicStateInvariants.t.sol` runs stateful
  Foundry invariants for the service-credit ledger and provider settlement
  buckets; `test/ReservationGeneration.t.sol` also fuzzes repeated slot reuse
  to verify that reservation generations keep their credit allocations isolated.
- `npm run selectors:check` validates the ABI, selector manifest, deployment
  artifacts and that the full-Diamond fixture has not drifted from the manifest.
- `npm run selectors:coverage` reports which selectors have behavior-test
  references and which have only proxy-routing smoke coverage. The report is
  an inventory heuristic, not a replacement for semantic test review.

The JavaScript checks use Node's built-in `node:test` runner. They are repository
and ABI consistency checks; contract behavior remains tested with Foundry.

Selector, storage and deployment-artifact changes require the private maintainer
notes and the verification commands above; the public guides describe the
deployed protocol surface.
