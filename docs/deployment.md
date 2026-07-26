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
