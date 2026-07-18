# Deployment and networks

Deployments are performed with Foundry and the repository's PowerShell/Node
helpers. The Diamond address is the public integration address; facet and
library addresses are implementation details recorded alongside it.

## Prerequisites

Install Foundry and Node.js, copy `.env.example` to `.env`, and provide the RPC,
deployer and verification settings required by the selected network. Never
commit `.env`, private keys or generated wallet material.

## Primary deployment flow

The current primary flow is:

```powershell
.\scripts\deploy_credits.ps1
```

Use the script's dry-run/default behavior before broadcasting. For a real
deployment, follow the script's explicit broadcast option and preserve the
generated artifact.

The repository keeps deployment snapshots such as:

- `deployments/sepolia-latest.json`
- `deployments/sepolia-resume.json`
- `deployments/sepolia-mica-open-2026-03-31.json`

Each snapshot identifies the network, chain ID, Diamond, facets, libraries,
deployer and configuration. Do not infer an address from source code when an
environment-specific deployment artifact is available.

## Upgrades

Facet upgrades use `diamondCut` and the selector/verification helpers in
`scripts/`. Typical operations include adding selectors, replacing a facet,
removing unsupported selectors and executing an initializer. Review the generated
cut and verify that the target Diamond is the intended deployment before
broadcasting.

## Post-deployment checks

After deployment or upgrade:

1. validate the ABI and selector routing;
2. confirm `DiamondLoupeFacet` exposes the expected facets;
3. verify supported ERC-165/ERC-721 interfaces;
4. run read-only checks against the generated address;
5. update the deployment snapshot and integration configuration together.

The backend and Marketplace must be configured with the Diamond address and
ABI belonging to the same deployment snapshot.
