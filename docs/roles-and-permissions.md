# Roles and permissions

The Diamond combines contract ownership with application roles. A provider,
institution or backend must be authorized in the contract before it can use the
corresponding domain operations.

## Actors

| Actor | Main authority |
| --- | --- |
| Diamond owner | Performs Diamond cuts and privileged initialization. |
| Default admin | Manages providers, institutional roles, credit adjustments and other administrative operations. |
| Provider | Owns and publishes labs, controls listing and lab configuration, and receives settlement receivables. |
| Institution | Registers organization identifiers, configures its backend and initiates institutional reservations. |
| Institutional backend | Acts for a registered institution when the contract explicitly authorizes that backend. |
| Renter / institutional user | Is represented by the reservation renter and, for institutional flows, a hashed PUC (`pucHash`). |

## Provider authorization

`ProviderFacet` manages provider membership and provider metadata. The provider
role is separate from ERC-721 ownership: a provider account must be authorized
to create or administer labs, while the token owner remains the authority used
by ownership-sensitive operations.

Provider network status is tracked separately:

- `NONE`: no active network participation.
- `ACTIVE`: the provider may fulfill reservations.
- `SUSPENDED`: temporarily excluded from fulfillment.
- `TERMINATED`: permanently deactivated.

Reservation fulfillment requires the lab to be listed and the current provider
to have `ACTIVE` network status.

## Institutions and backends

An institution is granted `INSTITUTION_ROLE`. It can register normalized
`schacHomeOrganization` identifiers and associate a backend URL with each
identifier through `InstitutionalOrgRegistryFacet`.

The registered backend is an execution delegate, not a new economic owner. The
contract checks that the caller is either the institution wallet or its
configured backend before allowing institution-scoped intent and reservation
operations.

Organization identifiers are normalized before hashing. The registry exposes
both string-based resolution and hash-based lookup for backend integration.

## Security rules for operators

- Keep Diamond ownership separate from routine provider or backend keys.
- Treat `accessKey`, backend URLs and metadata URIs as identifiers/configuration,
  not as a place for secrets.
- Never grant a backend address unless it is controlled by the institution and
  is configured in the corresponding backend service.
- Use the generated ABI for the deployed Diamond; calling a facet address
  directly bypasses the Diamond storage context and is not the normal protocol
  path.
