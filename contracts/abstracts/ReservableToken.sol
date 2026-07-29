// SPDX-License-Identifier: GPL-3.0-or-later
pragma solidity ^0.8.31;

import {LibAppStorage, AppStorage, Reservation} from "../libraries/LibAppStorage.sol";
import {LibERC721Storage} from "../libraries/LibERC721Storage.sol";
import {RivalIntervalTreeLibrary, Tree} from "../libraries/RivalIntervalTreeLibrary.sol";

/// @title ReservableToken Abstract Contract
/// @author
/// - Juan Luis Ramos Villalón
/// - Luis de la Torre Cubillo
/// @notice Read-only reservation and availability functionality for ERC721 lab tokens.
/// @dev Reservation writes live in the institutional and intent facets.
///
/// @notice Listing lifecycle operations are exposed by LabAdminFacet so every path
///         applies the same active-booking and ownership policy.
///
/// @dev Key features include:
/// - Reservation request system with pending/confirmed/access-authorized/settled/cancelled states
/// - Calendar management for avoiding time slot overlaps
/// - Event emission for tracking reservation lifecycle
/// - Access control for token owners and renters
///
/// @dev Dependencies:
/// - Requires RivalIntervalTreeLibrary for managing time intervals
/// - Assumes EIP-2535 Diamond standard compliance
/// - Integrates with ERC721 token standard
abstract contract ReservableToken {
    using RivalIntervalTreeLibrary for Tree;

    /// @notice The status of a reservation follows this lifecycle:
    /// - _PENDING: Reservation requested but not yet confirmed. Does NOT block calendar slot.
    /// - _CONFIRMED: Reservation confirmed and paid. Blocks calendar slot. Actively reserving the lab.
    /// - _ACCESS_AUTHORIZED: Access has been authorized on-chain. This is not proof that a remote session started.
    /// - status value 3 is reserved and unused.
    /// - _SETTLED: The reservation's economic outcome was applied: provider
    ///             receivable accrued when SessionStarted evidence exists, or
    ///             the priced reservation was refunded otherwise.
    /// - _CANCELLED: Reservation cancelled by payer, provider or expiry.
    /// @dev The status is represented as an 8-bit unsigned integer for gas efficiency.
    /// @dev State transition rules:
    ///      _PENDING → _CONFIRMED (on provider confirmation with credit lock,
    ///      or the atomic own-lab DIRECT_BOOKING path)
    ///      _PENDING → _CANCELLED (on provider denial or payer cancellation)
    ///      _CONFIRMED → _ACCESS_AUTHORIZED (on access authorization/check-in)
    ///      _CONFIRMED → _SETTLED (after end through the common economic finalizer)
    ///      _ACCESS_AUTHORIZED → _SETTLED (after end with SessionStarted, or
    ///      after the one-day attestation deadline without it)
    ///      _CONFIRMED → _CANCELLED (on cancellation with partial release/capture)
    ///      _ACCESS_AUTHORIZED → _CANCELLED is intentionally disallowed
    ///      _SETTLED, _CANCELLED are terminal states

    /// @dev External institutional requests are confirmed or denied by the
    ///      current lab owner or its authorized backend. Payer-side authority
    ///      applies only to request/cancellation paths and own-lab DIRECT_BOOKING.
    uint8 internal constant _CONFIRMED = 1;
    uint8 internal constant _ACCESS_AUTHORIZED = 2;

    /// @dev Custom errors to replace require strings for better gas efficiency and clarity.
    /// @dev These errors are used to revert transactions with specific error messages.
    error TokenNotFound();
    error ReservationNotFound();
    error AvailabilityResultTruncated();
    error InvalidAvailabilityPage();

    /// @dev Modifier to check if a token with the given ID exists.
    /// @param _tokenId The ID of the token to check.
    /// @notice Reverts if the token does not exist (i.e., its owner is the zero address).
    modifier exists(
        uint256 _tokenId
    ) {
        _checkExists(_tokenId);
        _;
    }

    function _checkExists(
        uint256 _tokenId
    ) internal view {
        if (LibERC721Storage.ownerOfOptional(_tokenId) == address(0)) revert TokenNotFound();
    }

    /// @notice Checks if a token with the given ID is listed.
    /// @param _tokenId The ID of the token to check.
    /// @return A boolean value indicating whether the token is listed.
    /// @dev The function requires the token to exist, enforced by the `exists` modifier.
    function isTokenListed(
        uint256 _tokenId
    ) external view exists(_tokenId) returns (bool) {
        return _s().tokenStatus[_tokenId];
    }

    /// @notice Retrieves the address of the renter associated with a specific reservation key.
    /// @param _reservationKey The unique identifier for the reservation.
    /// @return The address of the renter linked to the reservation.
    /// @dev Reverts with "Not found" if no renter is associated with the given reservation key.
    function userOfReservation(
        bytes32 _reservationKey
    ) external view returns (address) {
        address renter = _s().reservations[_reservationKey].renter;
        if (renter == address(0)) revert ReservationNotFound();
        return renter;
    }

    /// @notice Retrieves the details of a reservation using a reservation key.
    /// @param _reservationKey The unique identifier for the reservation.
    /// @return A `Reservation` struct containing the details of the reservation.
    /// @dev Reverts with "Not found" if the reservation does not exist (i.e., the renter address is zero).
    function getReservation(
        bytes32 _reservationKey
    ) external view returns (Reservation memory) {
        Reservation memory reservation = _s().reservations[_reservationKey];
        if (reservation.renter == address(0)) revert ReservationNotFound();
        return reservation;
    }

    /// @param _reservationKey The unique identifier for the reservation.
    /// @param _user The address of the user to check for an active booking.
    /// @return bool Returns true if the user has an active booking, otherwise false.
    function hasActiveBooking(
        bytes32 _reservationKey,
        address _user
    ) external view virtual returns (bool) {
        Reservation memory reservation = _s().reservations[_reservationKey];
        uint32 time = uint32(block.timestamp);

        // _ACCESS_AUTHORIZED means access-authorized; both statuses are active bookings.
        // The reservation window is intentionally evaluated against chain time.
        // slither-disable-next-line timestamp
        return (reservation.renter == _user
                && (reservation.status == _CONFIRMED || reservation.status == _ACCESS_AUTHORIZED)
                && reservation.start <= time && reservation.end >= time);
    }

    /// @notice Checks if a specific time range is available for a given token ID.
    /// @dev The function verifies that the start time is less than the end time and that the start time is in the future.
    ///      It then checks if the specified time range overlaps with any existing reservations in the token's calendar.
    ///      Logic flow: hasConflict() returns TRUE if overlap exists, so we negate it to return TRUE when available.
    /// @param _tokenId The ID of the token to check availability for.
    /// @param _start The start timestamp of the time range to check.
    /// @param _end The end timestamp of the time range to check.
    /// @return bool Returns true if the time range is available (no overlaps), false otherwise (has conflicts).
    function checkAvailable(
        uint256 _tokenId,
        uint256 _start,
        uint256 _end
    ) public view virtual exists(_tokenId) returns (bool) {
        // Early return pattern - invalid ranges are not available
        // Availability is intentionally evaluated against chain time.
        // slither-disable-next-line timestamp
        if (_start >= _end || _start <= block.timestamp) return false;

        return !_s().calendars[_tokenId].hasConflict(_start, _end);
    }

    /// @notice Finds the next available time slot after a given start time
    /// @dev Uses the interval tree to efficiently find the earliest blocking reservation.
    ///      This is useful for UX to show users when the next available slot is.
    ///      Time complexity: O(log n) where n is the number of reservations
    /// @param _tokenId The ID of the token (lab) to check
    /// @param _afterTime Find slots after this timestamp (Unix timestamp)
    /// @return nextSlotStart The start timestamp when next slot is available (0 if no reservations exist)
    /// @return blockedUntil If a reservation blocks the requested time, when it ends (0 if slot is free)
    /// @custom:example If _afterTime = 1000 and reservation exists [1000-2000], returns (1000, 2000)
    ///                  meaning "slot is blocked, next available after 2000"
    function getNextAvailableSlot(
        uint256 _tokenId,
        uint32 _afterTime
    ) external view virtual exists(_tokenId) returns (uint32 nextSlotStart, uint32 blockedUntil) {
        Tree storage calendar = _s().calendars[_tokenId];

        // If no reservations at all, everything is available
        if (calendar.root == 0) {
            return (_afterTime, 0);
        }

        // Find first reservation at or after _afterTime using binary search
        // This is O(log n) thanks to the Red-Black tree structure
        uint256 cursor = calendar.root;
        uint256 candidate = 0;

        while (cursor != 0) {
            // Check the predecessor interval as well as nodes that start at or
            // after the requested timestamp. Otherwise a query inside a
            // booking incorrectly reports the booking's start as the next
            // available slot.
            if (_afterTime >= cursor && _afterTime < calendar.nodes[cursor].end) {
                // forge-lint: disable-next-line(unsafe-typecast)
                return (_afterTime, uint32(calendar.nodes[cursor].end));
            }
            if (cursor >= _afterTime) {
                // This node starts at or after our target time
                candidate = cursor;
                // Check if there's an earlier one in left subtree
                cursor = calendar.nodes[cursor].left;
            } else {
                // This node is too early, check right subtree
                cursor = calendar.nodes[cursor].right;
            }
        }

        if (candidate == 0) {
            // No reservations after _afterTime, entire future is available
            return (_afterTime, 0);
        }

        // Found a reservation at/after the requested time
        // Return when it starts and when it ends
        // forge-lint: disable-next-line(unsafe-typecast)
        return (uint32(candidate), uint32(calendar.nodes[candidate].end));
    }

    /// @notice Retrieves booked time slots for a given token (lab).
    /// @dev Returns a complete result up to the safe 100-entry bound. Larger
    ///      calendars fail closed instead of returning a misleading prefix.
    /// @param _tokenId The ID of the token (lab) to get booked slots for
    /// @return starts Array of start timestamps (max 100 results)
    /// @return ends Array of end timestamps (max 100 results)
    /// @custom:example If lab has reservations [1000-2000] and [3000-4000], returns ([1000, 3000], [2000, 4000])
    function getBookedSlots(
        uint256 _tokenId
    ) external view virtual exists(_tokenId) returns (uint32[] memory starts, uint32[] memory ends) {
        Tree storage calendar = _s().calendars[_tokenId];
        uint256 bookingCount = _countSlotsLimited(calendar, calendar.root, 101);
        if (bookingCount > 100) revert AvailabilityResultTruncated();
        return _collectBookedSlots(calendar, bookingCount);
    }

    /// @notice Retrieves a bounded page of booked time slots.
    /// @dev The `hasMore` flag makes pagination explicit and prevents callers
    ///      from treating a capped response as a complete calendar.
    function getBookedSlotsPaginated(
        uint256 _tokenId,
        uint256 _offset,
        uint256 _limit
    ) external view virtual exists(_tokenId) returns (uint32[] memory starts, uint32[] memory ends, bool hasMore) {
        if (_limit == 0 || _limit > 100) revert InvalidAvailabilityPage();

        Tree storage calendar = _s().calendars[_tokenId];
        starts = new uint32[](_limit);
        ends = new uint32[](_limit);

        uint256 cursor = calendar.first();
        uint256 visited = 0;
        uint256 filled = 0;
        while (cursor != 0) {
            if (visited >= _offset) {
                if (filled == _limit) {
                    hasMore = true;
                    break;
                }
                // forge-lint: disable-next-line(unsafe-typecast)
                starts[filled] = uint32(cursor);
                // forge-lint: disable-next-line(unsafe-typecast)
                ends[filled] = uint32(calendar.nodes[cursor].end);
                unchecked {
                    ++filled;
                }
            }
            unchecked {
                ++visited;
            }
            cursor = calendar.next(cursor);
        }

        if (filled < _limit) {
            uint32[] memory trimmedStarts = new uint32[](filled);
            uint32[] memory trimmedEnds = new uint32[](filled);
            for (uint256 i; i < filled; i++) {
                trimmedStarts[i] = starts[i];
                trimmedEnds[i] = ends[i];
            }
            return (trimmedStarts, trimmedEnds, false);
        }

        return (starts, ends, hasMore);
    }

    function _collectBookedSlots(
        Tree storage calendar,
        uint256 bookingCount
    ) private view returns (uint32[] memory starts, uint32[] memory ends) {
        starts = new uint32[](bookingCount);
        ends = new uint32[](bookingCount);
        if (bookingCount > 0) {
            _collectSlotsLimited(calendar, calendar.root, starts, ends, 0, bookingCount);
        }
        return (starts, ends);
    }

    /// @dev Helper function to collect slots via in-order traversal with limit
    /// @param calendar The interval tree storage
    /// @param cursor Current node being examined
    /// @param starts Array to store start times
    /// @param ends Array to store end times
    /// @param index Current index in output arrays
    /// @param maxResults Maximum number of results to collect (stops when reached)
    /// @return nextIndex Updated index after processing this subtree
    function _collectSlotsLimited(
        Tree storage calendar,
        uint256 cursor,
        uint32[] memory starts,
        uint32[] memory ends,
        uint256 index,
        uint256 maxResults
    ) private view returns (uint256 nextIndex) {
        if (cursor == 0 || index >= maxResults) return index;

        // In-order: left subtree -> current node -> right subtree
        // This naturally orders reservations chronologically
        index = _collectSlotsLimited(calendar, calendar.nodes[cursor].left, starts, ends, index, maxResults);

        // Check limit before adding current node
        if (index < maxResults) {
            // forge-lint: disable-next-line(unsafe-typecast)
            starts[index] = uint32(cursor);
            // forge-lint: disable-next-line(unsafe-typecast)
            ends[index] = uint32(calendar.nodes[cursor].end);
            index++;
        }

        // Only traverse right if we haven't hit the limit
        if (index < maxResults) {
            index = _collectSlotsLimited(calendar, calendar.nodes[cursor].right, starts, ends, index, maxResults);
        }

        return index;
    }

    /// @notice Find which reservation (if any) occupies a specific timestamp
    /// @dev Uses binary search through the Red-Black tree for O(log n) complexity.
    ///      Searches for a reservation where: start <= timestamp < end
    /// @param _tokenId The ID of the token (lab) to check
    /// @param _timestamp The specific point in time to check (Unix timestamp)
    /// @return start Start time of the reservation covering this timestamp (0 if none)
    /// @return end End time of the reservation covering this timestamp (0 if none)
    /// @custom:example If reservation [1000-2000] exists and _timestamp=1500, returns (1000, 2000)
    ///                  If _timestamp=2500 and no reservation covers it, returns (0, 0)
    /// @custom:use-case Admin panel: "Who has the lab right now?", Debugging, Access control
    function findReservationAt(
        uint256 _tokenId,
        uint32 _timestamp
    ) external view virtual exists(_tokenId) returns (uint32 start, uint32 end) {
        Tree storage calendar = _s().calendars[_tokenId];

        // If no reservations at all
        if (calendar.root == 0) {
            return (0, 0);
        }

        // Binary search for the reservation
        uint256 cursor = calendar.root;

        while (cursor != 0) {
            // forge-lint: disable-next-line(unsafe-typecast)
            uint32 nodeStart = uint32(cursor);
            // forge-lint: disable-next-line(unsafe-typecast)
            uint32 nodeEnd = uint32(calendar.nodes[cursor].end);

            // Check if this node covers the timestamp
            if (_timestamp >= nodeStart && _timestamp < nodeEnd) {
                return (nodeStart, nodeEnd);
            }

            // Navigate tree based on timestamp
            if (_timestamp < nodeStart) {
                cursor = calendar.nodes[cursor].left;
            } else {
                cursor = calendar.nodes[cursor].right;
            }
        }

        // No reservation found covering this timestamp
        return (0, 0);
    }

    /// @notice Find all available time slots within a specific range
    /// @dev Returns gaps between reservations. Only returns slots >= minDuration.
    ///      Time complexity: O(n) where n is the number of reservations in range
    ///      SECURITY: Fails closed when more than 100 bookings would make the
    ///      bounded response incomplete. Use getBookedSlotsPaginated for reads.
    /// @param _tokenId The ID of the token (lab) to search
    /// @param _rangeStart Start of the search range (Unix timestamp)
    /// @param _rangeEnd End of the search range (Unix timestamp)
    /// @param _minDuration Minimum duration in seconds for a slot to be included
    /// @return slotStarts Array of available slot start times (max 100 gaps)
    /// @return slotEnds Array of available slot end times (max 100 gaps)
    /// @custom:example Range [0-10000], minDuration=1000, reservations [2000-3000], [5000-6000]
    ///                  Returns: ([0, 3000, 6000], [2000, 5000, 10000]) - three available slots
    /// @custom:use-case Booking assistant: "Show all 2-hour slots available this week"
    function findAvailableSlots(
        uint256 _tokenId,
        uint32 _rangeStart,
        uint32 _rangeEnd,
        uint32 _minDuration
    ) external view virtual exists(_tokenId) returns (uint32[] memory slotStarts, uint32[] memory slotEnds) {
        require(_rangeStart < _rangeEnd, "Invalid range");

        Tree storage calendar = _s().calendars[_tokenId];

        // If no reservations, entire range is available
        if (calendar.root == 0) {
            if (_rangeEnd - _rangeStart >= _minDuration) {
                slotStarts = new uint32[](1);
                slotEnds = new uint32[](1);
                slotStarts[0] = _rangeStart;
                slotEnds[0] = _rangeEnd;
            } else {
                slotStarts = new uint32[](0);
                slotEnds = new uint32[](0);
            }
            return (slotStarts, slotEnds);
        }

        // A capped booking read must never be used to infer a complete set of
        // gaps. Fail closed once a 101st booking exists instead of returning a
        // potentially false final availability interval.
        uint256 bookingCount = _countSlotsLimited(calendar, calendar.root, 101);
        if (bookingCount > 100) revert AvailabilityResultTruncated();

        // Get all bookings internally, avoiding a cross-selector self-call.
        (uint32[] memory bookStarts, uint32[] memory bookEnds) = _collectBookedSlots(calendar, bookingCount);

        // Find gaps - worst case: n+1 gaps (before first, between each, after last)
        uint32[] memory tempStarts = new uint32[](bookStarts.length + 1);
        uint32[] memory tempEnds = new uint32[](bookStarts.length + 1);
        uint32 gapCount = 0;

        uint32 searchStart = _rangeStart;

        for (uint256 i = 0; i < bookStarts.length;) {
            // Skip bookings that end before our range
            if (bookEnds[i] <= _rangeStart) {
                unchecked {
                    ++i;
                }
                continue;
            }

            // Stop if booking starts after our range
            if (bookStarts[i] >= _rangeEnd) break;

            // Check gap before this booking
            uint32 gapEnd = bookStarts[i] < _rangeEnd ? bookStarts[i] : _rangeEnd;
            if (gapEnd > searchStart && (gapEnd - searchStart) >= _minDuration) {
                tempStarts[gapCount] = searchStart;
                tempEnds[gapCount] = gapEnd;
                gapCount++;
            }

            // Move search start to after this booking
            searchStart = bookEnds[i] > searchStart ? bookEnds[i] : searchStart;

            // If we've covered the entire range, stop
            if (searchStart >= _rangeEnd) break;

            unchecked {
                ++i;
            }
        }

        // Check final gap after last booking
        if (searchStart < _rangeEnd && (_rangeEnd - searchStart) >= _minDuration) {
            tempStarts[gapCount] = searchStart;
            tempEnds[gapCount] = _rangeEnd;
            gapCount++;
        }

        // Copy to correctly sized arrays
        slotStarts = new uint32[](gapCount);
        slotEnds = new uint32[](gapCount);

        for (uint256 i = 0; i < gapCount;) {
            slotStarts[i] = tempStarts[i];
            slotEnds[i] = tempEnds[i];
            unchecked {
                ++i;
            }
        }

        return (slotStarts, slotEnds);
    }

    function _countSlotsLimited(
        Tree storage calendar,
        uint256 cursor,
        uint256 limit
    ) private view returns (uint256 count) {
        if (cursor == 0 || count >= limit) return 0;
        count = _countSlotsLimited(calendar, calendar.nodes[cursor].left, limit);
        if (count >= limit) return count;
        count++;
        if (count >= limit) return count;
        count += _countSlotsLimited(calendar, calendar.nodes[cursor].right, limit - count);
    }

    /// @notice Fast check if lab has any active booking at the current time
    /// @dev O(1) if empty, O(log n) binary search otherwise.
    ///      Uses current block.timestamp to check if lab is currently reserved/busy.
    /// @param _tokenId The ID of the token (lab) to check
    /// @return bool True if lab is currently booked, false if available
    /// @custom:example At timestamp 1500: reservation [1000-2000] exists → returns true
    ///                  At timestamp 500: reservation [1000-2000] exists → returns false
    /// @custom:use-case Real-time availability checks, access control gates, status indicators
    function isLabBusy(
        uint256 _tokenId
    ) external view virtual exists(_tokenId) returns (bool) {
        Tree storage calendar = _s().calendars[_tokenId];

        // Fast O(1) check: if no reservations at all
        if (calendar.root == 0) {
            return false;
        }

        // Binary search for current time - O(log n)
        uint32 currentTime = uint32(block.timestamp);
        (uint32 start, uint32 end) = this.findReservationAt(_tokenId, currentTime);

        // The busy check is intentionally evaluated against chain time.
        // slither-disable-next-line timestamp
        return start != 0 && end > currentTime; // If we found a reservation, lab is busy
    }

    /// @notice Get the end time of the current or next active reservation
    /// @dev Useful for automatic cleanup, status updates, or showing "available in X hours".
    ///      Time complexity: O(log n)
    /// @param _tokenId The ID of the token (lab) to check
    /// @return uint32 End timestamp of current/next reservation (0 if no future reservations)
    /// @custom:example Current time 1500, reservation [1000-2000] active → returns 2000
    ///                  Current time 500, next reservation [1000-2000] → returns 2000
    ///                  Current time 3000, no future reservations → returns 0
    /// @custom:use-case UI: "Available in 2 hours", Automatic status updates, Cleanup scheduling
    function getNextExpiration(
        uint256 _tokenId
    ) external view virtual exists(_tokenId) returns (uint32) {
        Tree storage calendar = _s().calendars[_tokenId];

        // If no reservations at all
        if (calendar.root == 0) {
            return 0;
        }

        uint32 currentTime = uint32(block.timestamp);

        // First check if we're currently in a reservation
        (uint32 currentStart, uint32 currentEnd) = this.findReservationAt(_tokenId, currentTime);
        // The active window is intentionally evaluated against chain time.
        // slither-disable-next-line timestamp
        if (currentStart != 0) {
            return currentEnd; // Return end of current reservation
        }

        // Not currently booked, find next future reservation
        (uint32 nextStart, uint32 nextEnd) = this.getNextAvailableSlot(_tokenId, currentTime);

        // The next reservation is intentionally evaluated against chain time.
        // slither-disable-next-line timestamp
        if (nextStart != 0 && nextEnd > 0) {
            return nextEnd; // Return end of next reservation
        }

        return 0; // No future reservations
    }

    /// @dev Internal pure function to retrieve the application storage structure.
    ///      This function provides access to the `AppStorage` instance by calling
    ///      the `diamondStorage` function from the `LibAppStorage` library.
    ///      Assuming EIP-2535 compliant contract
    /// @return s The storage instance of type `AppStorage`.
    function _s() internal pure returns (AppStorage storage s) {
        return LibAppStorage.diamondStorage();
    }
}
