# DecentraLabs Smart Contracts

Institutional-only smart contracts for lab access, reservations, internal service-credit accounting, and provider settlement, built with the EIP-2535 Diamond pattern.

## Active Model

- Labs are ERC-721 assets managed by providers.
- Institutions and authorized backends create and manage reservations.
- Reservations operate against an internal credit ledger.
- Provider monetization is tracked as receivables and settlement states.
- There is no external credit token and no wallet-reservation flow in this branch.

## Main Components

```text
Diamond Proxy
|- DiamondCutFacet
|- DiamondLoupeFacet
|- OwnershipFacet
|- InitFacet
|- IntentRegistryFacet
|- ProviderFacet
|- LabFacet / LabAdminFacet / LabIntentFacet / LabQueryFacet / LabReputationFacet
|- InstitutionFacet / InstitutionalOrgRegistryFacet / InstitutionalTreasuryFacet
|- InstitutionalReservation* facets
|- ReservationDenialFacet / ReservationIntentFacet / ReservationCheckInFacet / ReservationStatsFacet
`- ProviderSettlementFacet
```

## Reservation Flow

Reservation lifecycle:

- `PENDING`
- `CONFIRMED`
- `IN_USE`
- `COMPLETED`
- `SETTLED`
- `CANCELLED`

Operational model:

- Institutional request creation and validation
- Provider confirmation
- Credit lock, capture, release, and refund paths
- Provider receivable accrual and settlement transitions
- Interval-tree conflict detection for exclusive labs

## Accounting Model

Reservation settlement computes the provider allocation on-chain:

- `providerShare` (75%)

The platform margin (25%) is implicit (`price − providerShare`) and not
tracked as a separate on-chain bucket.

For cancellation penalties:

- `cancelFee` (5% of price, minimum 0.1 credits)
- `provider` receives 3% of price as cancellation fee
- platform receives 2% of price as cancellation fee (implicit by difference)

These are internal accounting entries, not token wallets.

## Deployment

Primary deploy flow:

- `scripts/deploy_credits.ps1`

Primary deployment artifacts:

- `deployments/sepolia-resume.json`
- `deployments/sepolia-latest.json`
- `deployments/sepolia-mica-open-2026-03-31.json`

## Validation

Typical local validation:

```powershell
forge build
forge test
```

Institutional gas benchmark:

- `test/GasInstitutionalReservations.t.sol`
