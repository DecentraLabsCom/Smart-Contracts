# Facet reference

This page maps the current source layout to protocol responsibilities. Public
functions are exposed through the Diamond after their selectors are installed;
the source file alone does not imply that a facet address is directly callable.

## Canonical selector surface

`selectors/diamond.json` is the allowlist for the production Diamond. Deployment
and upgrade scripts must derive each facet cut from that manifest; compiling a
public function is not enough to install it. `abi/Diamond.json` is generated from
the same source, so consumer ABIs cannot silently retain deprecated selectors.

Use these checks before every upgrade:

- `npm run selectors:check` verifies selector uniqueness, facet ownership and the
  forbidden legacy signatures.
- `npm run verify:contract-surface` validates the manifest and regenerates the
  public ABI.
- `npm run selectors:plan-live -- --simulate` compares the deployed Diamond with
  the manifest and simulates any removal as the current Diamond owner without
  broadcasting a transaction. `RPC_URL` must point to the target network.
- `node scripts/simulate-contract-surface-upgrade.cjs` exercises the complete
  replacement/removal cut on a local chain with ID `31337`.

## Core and initialization

| Source | Responsibility |
| --- | --- |
| `facets/diamond/DiamondCutFacet.sol` | Add, replace and remove selectors; owner-only upgrades. |
| `facets/diamond/DiamondLoupeFacet.sol` | Discover facets, selectors and supported interfaces. |
| `facets/diamond/OwnershipFacet.sol` | Ownership transfer and acceptance. |
| `facets/InitFacet.sol` | Coordinated initialization of provider and lab state. |
| `upgradeInitializers/` | Delegatecalled initialization payloads for deployment/upgrade. |

## Providers and labs

| Source | Responsibility |
| --- | --- |
| `facets/ProviderFacet.sol` | Provider roles, profile, backend authorization and network status. |
| `facets/lab/LabFacet.sol` | ERC-721 behavior and lab-level events. |
| `facets/lab/LabAdminFacet.sol` | Create, update, list, unlist and delete labs. |
| `facets/lab/LabQueryFacet.sol` | Lab reads and pagination. |
| `facets/lab/LabIntentFacet.sol` | Intent-aware lab operations. |
| `facets/lab/LabReputationFacet.sol` | Scores, ratings and reputation-aware URI reads. |

## Reservations and access

| Source | Responsibility |
| --- | --- |
| `facets/reservation/` | Public reservation, institutional reservation, check-in, sessions, denials, stats and intents. |
| `facets/reservation/institutional/InstitutionFacet.sol` | Institution role and institutional configuration. |
| `facets/reservation/institutional/InstitutionalOrgRegistryFacet.sol` | Organization-to-institution and backend URL registry. |
| `facets/reservation/institutional/InstitutionalTreasuryFacet.sol` | Institutional spending limits and treasury checks. |
| `facets/reservation/ProviderSettlementFacet.sol` | Provider receivables and settlement operations. |
| `facets/reservation/ReservationCheckInFacet.sol` | Moves a confirmed reservation to access-authorized. |
| `facets/reservation/ReservationSessionFacet.sol` | Stores SessionStarted evidence and uniqueness guards. |
| `facets/reservation/ReservationIntentFacet.sol` | Consumes institutional reservation/action intents. |

## Credits and intents

| Source | Responsibility |
| --- | --- |
| `facets/ServiceCreditFacet.sol` | Credit balances, lots, locks, captures, releases, expiry and movements. |
| `facets/IntentRegistryFacet.sol` | Request/action intent registration, cancellation and nonce reads. |

The `facets/test/` directory is test-only support and must not be installed as
a production selector set.
