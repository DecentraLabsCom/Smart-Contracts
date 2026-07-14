# Reservations

Reservations represent time-bounded use of a lab token. The contract stores the
reservation key, lab, renter/tracking identity, price, timestamps, provider and
institutional accounting context.

## Status lifecycle

| Value | Status | Meaning |
| ---: | --- | --- |
| `0` | `PENDING` | Request exists but has not been confirmed; it does not occupy the active calendar. |
| `1` | `CONFIRMED` | Request is confirmed and credits are locked/captured according to the flow; the time range is active. |
| `2` | `ACCESS_AUTHORIZED` | On-chain access authorization has been recorded; the reservation remains active. |
| `3` | `SETTLED` | The reservation has been finalized and provider receivable accounting has been updated. |
| `4` | `CANCELLED` | The request or booking was cancelled and its active indexes were cleaned. |

`ACCESS_AUTHORIZED` means that the contract authorized access. It is not, by
itself, proof that a remote session actually started. The separate
SessionStarted attestation is required by provider settlement.

## Availability and reservation keys

Exclusive resources use `RivalIntervalTreeLibrary` to detect overlapping
intervals. The reservation key is derived from the lab and start context in the
current request/intent flow; callers should use the key supplied by the
integration contract rather than inventing a second identifier.

Useful read paths include:

- `getReservation` and `userOfReservation` for a single reservation.
- `checkAvailable`, `isLabBusy` and `getNextAvailableSlot` for calendar checks.
- paginated reservation queries for a lab or tracking user.
- active, upcoming, recent and past reservation views maintained by the
  enumerable reservation base.

## Public and institutional flows

The codebase has separate paths for ordinary and institutional reservations.
Institutional reservations additionally bind:

- payer and collector institutions;
- the normalized user identity hash (`pucHash`);
- institutional treasury checks and spending limits;
- authorized backend execution;
- provider/session evidence used during settlement.

The institutional request path validates the lab, time range, expected price and
PUC binding before it creates a pending reservation. Confirmation then moves it
to `CONFIRMED` and establishes the provider share used for settlement.

## Expiration and cancellation

Pending requests have a bounded request period. Expired pending requests can be
released without becoming active bookings. Confirmed or access-authorized
reservations can be finalized after their end time; finalization removes active
indexes and moves the reservation to `SETTLED`.

Cancellation behavior depends on the current state and caller. Confirmed
bookings may be cancelled only under the configured time and authorization
rules. Access-authorized cancellations are intentionally restricted so that an
already authorized access cannot be rewritten as an ordinary pre-access
cancellation.
