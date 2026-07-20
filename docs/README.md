# Documentation guide

This documentation describes the current public surface of the DecentraLabs
Diamond. It is written for integrators and operators.
The Solidity source, the selector manifest and the tests remain authoritative
when a document and an implementation differ.

## Choose a reading path

| If you need to… | Start here | Then read |
| --- | --- | --- |
| Understand the protocol boundary | [Architecture](architecture.md) | [Roles and permissions](roles-and-permissions.md) |
| Publish or operate a lab | [Labs and metadata](labs.md) | [Reservations](reservations.md) and [Institutional access](institutional-access.md) |
| Integrate institutional booking | [Reservations](reservations.md) | [Institutional access](institutional-access.md) and [Intents](reference/intents.md) |
| Reconcile credits or provider payouts | [Service credits and settlement](credits-and-settlement.md) | [Reservations](reservations.md) |
| Deploy the Diamond | [Deployment](deployment.md) | `deployments/` and the generated deployment artifacts |

## Core vocabulary

| Term | Meaning |
| --- | --- |
| **Diamond** | The single EIP-2535 proxy address that consumers call. |
| **Facet** | An implementation contract selected by the Diamond from the calldata selector. |
| **Lab** | A provider-managed ERC-721 token whose on-chain fields define bookable behaviour. |
| **Reservation key** | The bytes32 identifier used by reservation, credit, access and settlement records. Institutional paths derive it from the lab ID and start time. |
| **PUC hash** | A bytes32 hash identifying an institutional user or lab creator without placing the raw identifier on-chain. |
| **Service credit** | An internal accounting unit. It is neither native currency nor an ERC-20 asset. |
| **Intent** | A signed, one-time EIP-712 authorization for a specific payload and executor. |
| **SessionStarted evidence** | Provider-signed, hash-only evidence that an access-authorized session actually began. |

## What is public

Call the deployed Diamond with the ABI generated for that deployment. A facet
source file or a compiled facet is not automatically part of the production
surface: its functions must be present in `selectors/diamond.json` and be
installed by a Diamond cut. Direct calls to a facet use the facet's own storage
and are not equivalent to calls through the Diamond.

Deployment JSON under `deployments/` is the source for a network's Diamond and
implementation addresses. The `*-latest.json` artifact is a convenience
snapshot, not a replacement for recording the exact artifact used by an
integration.

## Boundaries and non-goals

The contract is authoritative for protocol state: roles, lab ownership and
configuration, reservation lifecycle, credit accounting, access evidence and
provider receivables. Metadata, SAML assertions, JWTs, invoices and payment
documents remain off-chain. Their hashes can be recorded as references, but
their contents do not change on-chain state by themselves.
