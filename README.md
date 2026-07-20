# DecentraLabs Smart Contracts

This repository contains the current DecentraLabs on-chain protocol: one
EIP-2535 Diamond for labs, institutional reservations, internal service-credit
accounting, access evidence and provider settlement.

## Protocol at a glance

- A lab is a provider-managed ERC-721 token with an on-chain price, resource
  type and access-routing identifiers.
- The Diamond delegates each approved selector to a facet while all domain
  state remains in shared `AppStorage`.
- The canonical booking write paths are institutional. An institution and its
  authorized backend use direct calls or one-time intents.
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
```

Selector, storage and deployment-artifact changes require the private maintainer
notes and the verification commands above; the public guides describe the
deployed protocol surface.
