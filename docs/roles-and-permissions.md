# Roles and permissions

## Separation of authority

Diamond ownership, the default-admin role and application roles are distinct.
Keep their keys separate: an upgrade key should not be the everyday provider or
backend key.

| Actor or role | Authority | Important limit |
| --- | --- | --- |
| Diamond owner | Executes `diamondCut` and privileged initialization | Does not replace application-role checks inside facets. |
| Default admin | Onboards/removes providers and institutions; administers credits and other protected operations | Must not be used as a general backend wallet. |
| Provider | Creates labs and maintains its provider profile | A lab's ERC-721 owner controls owner-sensitive lab operations. |
| Institution | Owns its treasury, spending policy and institutional reservation context | An organization name alone does not authorize a transaction. |
| Authorized backend | Executes the institution/provider paths explicitly delegated to its address | It is a delegate, not a new economic owner. |
| External reservation authority | The current lab owner or that owner's authorized backend confirms or denies a pending request | The payer can request/cancel; it cannot confirm or deny an external request. `DIRECT_BOOKING` is only for an own-lab request. |
| Settlement operator | Can perform the privileged financial claim transitions when configured | Claim references and lifecycle checks still apply. |
| Institutional user | Is represented by the reservation's `pucHash` and tracking key | The raw identifier is not stored on-chain. |

## Provider lifecycle

`ProviderFacet` manages provider membership and profile data. Adding a provider
also grants `INSTITUTION_ROLE`, creates the provider's initial institutional
defaults, and authorizes the provider wallet as its own backend. A provider is
therefore ready for the institutional side of the protocol, but an external
backend address still requires explicit authorization.

Provider network status is independent of role membership:

| Status | Reservation effect |
| --- | --- |
| `NONE` | Not participating in the fulfilment network. |
| `ACTIVE` | May confirm listed labs that are accepting new reservations. |
| `SUSPENDED` | Cannot fulfil new reservations. |
| `TERMINATED` | Permanently deactivated; the same wallet cannot be re-added. |

Removing a provider is guarded. It must have no locked credits and own no labs;
closed credit history is retained for audit. Confirmation also requires the
current lab owner to be `ACTIVE` and the lab to be listed and accepting intake.

## Institutional onboarding and organization registry

Use one of the atomic onboarding operations when possible:

| Operation | Result |
| --- | --- |
| `provisionProvider` | Creates the provider, grants institution capability, and registers or updates its organization record in one transaction. |
| `provisionInstitution` | Grants `INSTITUTION_ROLE` if needed, registers an organization, stores its backend URL, and initializes the institution wallet as executor when no backend is authorized. |
| `grantInstitutionRole` | Grants the role and registers an organization without the optional URL. |

Organization strings are normalized before hashing. An organization can belong
to only one institution wallet, and the registry's URL is configuration for
off-chain routing. It does **not** authorize an EVM address. Transactional
delegation is stored separately by `authorizeBackend`, `revokeBackend` and the
admin recovery operation; inspect `getAuthorizedBackend` for the active address.
When `provisionInstitution` is used for consumer onboarding, the missing
delegation is initialized to the institution wallet in the same transaction.
An already configured external backend is preserved; replacing it still
requires explicit backend authorization and proof outside this primitive.
For deployments created before this invariant, run
`npm run migrate:consumer-backends` for a read-only inventory and repeat with
`-- --broadcast` after reviewing the candidates.
The provisioning change itself requires deploying the updated
`InstitutionFacet` and replacing its Diamond selector before issuing new
pairings; the migration repairs already registered consumers independently.

The registry is an ownership/routing claim, not an identity proof. Validate
SAML/eduGAIN or equivalent federation evidence off-chain before treating an
organization-to-wallet result as an authenticated institution.

## Operational rules

- Never place secrets in `accessKey`, metadata URIs or backend URLs.
- Keep the deployment's Diamond address and generated ABI together; never call
  a facet address as if it were the Diamond.
- Treat a `pucHash` as personal-data-derived and only submit the canonical hash
  expected by the relevant integration.
- Verify roles, the authorized backend and provider network status before
  diagnosing a failed booking or settlement call.
