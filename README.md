# DecentraLabs Smart Contracts

This repository contains the current EIP-2535 Diamond implementation for
DecentraLabs laboratories, institutional reservations, internal service-credit
accounting and provider settlement.

The documentation in this repository is the canonical guide for the code in
`contracts/`. Start with the [table of contents](SUMMARY.md).

## Current contract model

- Labs are ERC-721 assets managed by provider accounts.
- The Diamond proxy exposes modular facets while keeping application state in
  the shared `AppStorage` layout.
- Institutions and their authorized backends create and manage institutional
  reservations.
- Reservations are funded by an internal, non-refundable service-credit ledger;
  there is no active external `$LAB` token settlement flow.
- Provider revenue is recorded as receivables and later moved through the
  settlement lifecycle.
- Physical/remote labs use exclusive calendar conflict checks. FMU resources
  use the concurrent-resource path identified by `resourceType = 1`.

## Read next

- [Architecture](docs/architecture.md) explains the Diamond and cross-project
  boundaries.
- [Labs and metadata](docs/labs.md) documents provider-owned lab NFTs and the
  off-chain metadata URI.
- [Reservations](docs/reservations.md) covers public and institutional booking
  lifecycles.
- [Service credits and settlement](docs/credits-and-settlement.md) describes
  funding, locking, capture, release, expiration and provider receivables.
- [Deployment and networks](docs/deployment.md) covers the deploy scripts and
  generated deployment artifacts.
- [Facet reference](docs/reference/facets.md) maps source directories to their
  public responsibilities.

## Source of truth

The Solidity implementation and tests are authoritative. Generated ABIs,
deployment JSON files and off-chain metadata are integration artifacts. The
separate [Lab-Metadata repository](https://github.com/DecentraLabsCom/Lab-Metadata)
documents the JSON metadata contract; it does not grant access or alter
reservation state.

## Quick validation

```powershell
forge build
forge test
```

The institutional gas benchmark is
`test/GasInstitutionalReservations.t.sol`. Deployment and selector verification
scripts are documented in [Development and testing](docs/development.md).
