# Labs and metadata

Each laboratory is an ERC-721 asset. The token ID is the stable on-chain
identifier used by reservations, access authorization, reputation and provider
settlement.

## On-chain lab record

`LabBase` contains the fields that affect protocol behavior:

| Field | Meaning |
| --- | --- |
| `uri` | URI of the off-chain lab metadata JSON. |
| `price` | Raw service-credit price per second. |
| `accessURI` | Provider gateway/service endpoint identifier. |
| `accessKey` | Public provider-side routing identifier; it is not a password. |
| `createdAt` | Registration timestamp. |
| `resourceType` | `0` for an exclusive physical/remote lab; `1` for a concurrent FMU simulation. |

The contract does not store the full descriptive document. Consumers resolve
`uri` and validate the JSON using the [Lab-Metadata repository](https://github.com/DecentraLabsCom/Lab-Metadata).

## Provider workflow

The lab administration facets provide the following lifecycle:

1. A provider creates a lab and supplies its URI, price and access identifiers.
2. The provider lists the lab when it is ready to accept reservations.
3. The provider may update metadata and access configuration while respecting
   the ownership and reservation guards in the facet.
4. The provider unlists or deletes the lab when it should no longer be offered.

`addAndListLab` is available for the atomic create-and-list path. Lab transfers
and owner migrations are handled by their dedicated facet/library logic and
must preserve the relationship between token ownership and provider state.

## Resource types

`resourceType = 0` uses the interval calendar to prevent overlapping active
reservations. `resourceType = 1` identifies a concurrent FMU simulation, so the
exclusive calendar conflict rule is not applied in the same way; concurrency is
described by off-chain metadata and provider runtime capacity.

The numeric value in `LabBase` is authoritative. Metadata is useful for
discovery, but changing a JSON attribute cannot change the resource type or
reservation economics already stored on-chain.

## Reputation

`LabReputationFacet` exposes a score and rating derived from lab lifecycle
events. A completed access-authorized reservation contributes to completion
tracking when the required SessionStarted evidence exists. Provider
cancellations and other configured events are recorded separately.
