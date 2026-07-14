# Development and testing

## Tooling

The project uses Solidity `0.8.33`, Foundry and OpenZeppelin libraries. The
standard local commands are:

```powershell
forge build
forge fmt --check
forge test
```

Run a focused test while developing:

```powershell
forge test --match-path test/InstitutionalReservationConfirmation.t.sol -vv
```

## Test areas

The Foundry suite covers:

- Diamond initialization, loupe routing and access control;
- lab publication, metadata, listing and reputation;
- reservation calendars, long-duration ranges and institutional PUC checks;
- service-credit accounting and provider receivables;
- SessionStarted and check-in evidence;
- interval-tree invariants, fuzzing and gas behavior.

The institutional gas benchmark is
`test/GasInstitutionalReservations.t.sol`. Do not treat a gas snapshot as a
protocol invariant; rerun the functional tests when changing storage or
reservation logic.

## Adding a facet

1. Put the facet under the domain directory in `contracts/facets/`.
2. Use `LibAppStorage.diamondStorage()` for shared application state.
3. Keep storage additions appended to `AppStorage`; do not reorder existing
   members.
4. Add or update focused Foundry tests before changing deployment scripts.
5. Generate/update the ABI and verify selector collisions.
6. Add the facet to the [facet reference](reference/facets.md) when its public
   responsibility is stable.

## Storage and upgrade safety

Diamond facets execute in the Diamond's storage context. A direct call to a
facet deployment is not equivalent to a call through the Diamond. Changes to
`AppStorage`, libraries that write it, selector routing or initializer calldata
require an upgrade review.

## Generated artifacts

`out/`, `cache/`, `broadcast/`, ABI files and deployment JSON files are generated
or environment-specific. Update tracked artifacts only when the project flow
requires them and make the corresponding source/test/deployment change clear in
the commit.
