# Deployment and networks

## Deployment contract

The Diamond address is the only application endpoint. Facet and linked-library
addresses are implementation details recorded in the deployment artifact. Keep
the Diamond address, public ABI and consumer configuration from the same
artifact together.

## Prerequisites

Install Foundry and Node.js, then copy `.env.example` to `.env` and populate
the selected network's RPC, signer and verification settings. Do not commit the
resulting `.env`, private key or generated wallet data.

Run the local checks before a deployment or upgrade:

```powershell
forge build
forge fmt --check
forge test
npm run verify:contract-surface
npm run verify:repo-consistency
npm run docs:check
```

## Primary deployment flow

`scripts/deploy_credits.ps1` deploys the linked libraries, Diamond core and
facets, validates selector uniqueness, performs the cut and writes deployment
artifacts. Its default flow is a dry run:

```powershell
.\scripts\deploy_credits.ps1
.\scripts\deploy_credits.ps1 -Broadcast
.\scripts\deploy_credits.ps1 -Resume -ResumeFile <path>
```

Use the dry run first. Before broadcasting, verify the network, target Diamond
when upgrading, deployer/owner address, initializer arguments and the exact
selector plan. The script writes a timestamped artifact and refreshes the
network's `*-latest.json` snapshot after a successful deployment.

## Upgrade procedure

1. Build and test the changed facet and linked libraries.
2. Update and validate `selectors/diamond.json`; never resolve a selector
   collision by deployment order.
3. Compare the intended manifest with the live Diamond when an RPC is available:

   ```powershell
   npm run selectors:plan-live -- --simulate
   ```

4. Simulate the complete replacement/removal cut locally when the surface
   changes: `node scripts/simulate-contract-surface-upgrade.cjs`.
5. Broadcast the reviewed cut, run loupe/interface/read-only checks, and
   preserve the exact output artifact.
6. Update Marketplace and backend ABI/address configuration together.

For the retired direct institutional reservation route, the intended cut is a
single removal of selector `0xc2cfb850`, the selector for
`institutionalReservationRequest(address,bytes32,uint256,uint32,uint32)`.
After the manifest and ABI changes, inspect and simulate the targeted cut:

```powershell
node scripts/remove-institutional-reservation-selector.cjs --simulate
```

Review that the helper targets only `0xc2cfb850`, then broadcast it with the
Diamond owner:

```powershell
node scripts/remove-institutional-reservation-selector.cjs --broadcast
```

Do not use a broad selector-reconciliation cut to remove this route when other
pending upgrades are present. Do not deploy the backend release or replace the
pinned deployment manifest until the targeted cut is mined and the loupe
confirms that the selector maps to the zero address.

Reservation authorization is implemented in the linked
`LibInstitutionalReservationConfirmation`, `LibReservationConfirmation` and
`LibInstitutionalReservationRequestValidation` libraries as well as their
facets. If any of these libraries or facets changes, the upgrade must deploy
the new linked bytecode and replace the live facet; reusing an old resume
artifact is not a valid security upgrade. Verify the live routes for external
request validation, confirmation, denial and `DIRECT_BOOKING` before enabling
provider automation.

The source external-request timing is a five-minute pending-request TTL and a
ten-minute minimum creation lead. The canonical backend still requires 12
confirmations and uses 15-second polling/retry defaults. If finality or provider
processing misses the five-minute decision deadline, the request must expire
without confirmation or credit capture. Changing `PENDING_REQUEST_TTL`, the
confirmation depth or polling budget requires a reviewed upgrade/configuration
change that preserves this fail-closed ordering on every provider deployment.
These values are source/deployment targets; an already deployed Diamond keeps
its previous embedded constants until the reviewed cut is mined and verified.

Only the Diamond owner can cut selectors. A cut can execute an initializer via
`delegatecall`, so treat it with the same key-management and review discipline
as a privileged production migration.

For the service-credit scale migration, update raw balances through the ledger
adjustment path and update each active lab price from its intended display price.
Do not reuse five-decimal raw prices unchanged: the same numeric raw value would
be interpreted as one hundredth of its former credit value after the migration.

## Verification and artifacts

Use `scripts/verify_facets.ps1` for block-explorer verification when required.
Deployment snapshots such as `deployments/sepolia-latest.json` identify network,
chain ID, Diamond, facets, libraries, deployer and deployment configuration.
Do not infer an address from source code or an old run: record the artifact
actually supplied to each integration.

The committed network matrix and current Sepolia Diamond address are maintained
in [the generated public API reference](reference/facets.md). It intentionally
shows no mainnet address until a reviewed mainnet artifact is committed.
