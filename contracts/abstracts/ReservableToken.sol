// SPDX-License-Identifier: GPL-3.0-or-later
pragma solidity ^0.8.23;

import {IERC721} from "@openzeppelin/contracts/token/ERC721/IERC721.sol";
import {LibAppStorage, AppStorage, Reservation}  from "../libraries/LibAppStorage.sol";
import "../libraries/RivalIntervalTreeLibrary.sol";

/// @title ReservableToken Abstract Contract
/// @author
/// - Juan Luis Ramos Villalón
/// - Luis de la Torre Cubillo
/// @notice Abstract contract that implements reservation functionality for ERC721 tokens
/// @dev This contract provides the base functionality for making tokens reservable within specific time periods
///
/// @notice This contract allows token owners to:
/// - List and unlist their tokens for reservation
/// - Manage reservation requests
/// - Handle bookings and cancellations
/// - Track reservation statuses
///
/// @dev Key features include:
/// - Reservation request system with pending/booked/used/collected/cancelled states
/// - Calendar management for avoiding time slot overlaps
/// - Event emission for tracking reservation lifecycle
/// - Access control for token owners and renters
///
/// @dev Implements the following main functionalities:
/// - Token listing/unlisting
/// - Reservation requests and confirmations
/// - Booking management
/// - Reservation status tracking
/// - Calendar management for time slots
///
/// @dev Dependencies:
/// - Requires RivalIntervalTreeLibrary for managing time intervals
/// - Assumes EIP-2535 Diamond standard compliance
/// - Integrates with ERC721 token standard
///
/// @dev Security considerations:
/// - Implements access control through modifiers
/// - Validates time ranges and reservation states
/// - Checks for existing reservations before new bookings
/// - Ensures proper authorization for cancellations
abstract contract ReservableToken {
    using RivalIntervalTreeLibrary for Tree;
    
    /// @notice The status of a reservation can be one of the following:
    /// - PENDING: Reservation has been requested but not confirmed.
    /// - BOOKED: Reservation has been confirmed and is active.
    /// - USED: Reservation has been used, typically indicating the end of the reservation period.       
    /// - COLLECTED: Reservation has been collected, indicating the item has been picked up or used.
    /// - CANCELLED: Reservation has been cancelled, either by the renter or the owner.
    /// @dev The status is represented as an 8-bit unsigned integer for gas efficiency.
    /// @dev The reservation margin is a constant value that defines the minimum time before a reservation can start.
  
    uint8 internal constant PENDING = 0;
    uint8 internal constant BOOKED = 1;
    uint8 internal constant USED = 2;
    uint8 internal constant COLLECTED = 3;
    uint8 internal constant CANCELLED = 4;
    uint32 internal constant RESERVATION_MARGIN = 0;

    /// @notice Emitted when a reservation is requested for a token.
    /// @param renter The address of the user requesting the reservation.
    /// @param tokenId The ID of the token being reserved.
    /// @param start The start timestamp of the reservation period.
    /// @param end The end timestamp of the reservation period.
    /// @param reservationKey A unique key identifying the reservation.
    event ReservationRequested(address indexed renter, uint256 indexed tokenId, uint256 start, uint256 end, bytes32 reservationKey);
    
    /// @notice Emitted when a reservation is successfully confirmed.
    /// @param reservationKey The unique identifier for the confirmed reservation.
    /// @param tokenId The ID of the token associated with the reservation.
    event ReservationConfirmed(bytes32 indexed reservationKey, uint256 indexed tokenId);

    /// @notice Emitted when a reservation request is denied.
    /// @param reservationKey The unique key identifying the reservation that was denied.
    /// @param tokenId The ID of the token associated with the reservation.
    event ReservationRequestDenied(bytes32 indexed reservationKey, uint256 indexed tokenId);
    
    /// @notice Emitted when a reservation request is canceled.
    /// @param reservationKey The unique identifier of the reservation that was canceled.
    /// @param tokenId The ID of the token associated with the reservation.
    event ReservationRequestCanceled(bytes32 indexed reservationKey, uint256 indexed tokenId);
    
    /// @notice Emitted when a booking associated with a specific reservation key is canceled.
    /// @param reservationKey The unique identifier for the reservation that was canceled.
    /// @param tokenId The ID of the lab/token associated with the reservation.
    event BookingCanceled(bytes32 indexed reservationKey, uint256 indexed tokenId);

    /// @notice Emitted when a token is listed for reservations.
    /// @param tokenId The ID of the token that was listed.
    /// @param owner The address of the token owner who listed it.
    event LabListed(uint256 indexed tokenId, address indexed owner);

    /// @notice Emitted when a token is unlisted from reservations.
    /// @param tokenId The ID of the token that was unlisted.
    /// @param owner The address of the token owner who unlisted it.
    event LabUnlisted(uint256 indexed tokenId, address indexed owner);

    /// @dev Custom errors to replace require strings for better gas efficiency and clarity.
    /// @dev These errors are used to revert transactions with specific error messages.     
    error TokenNotFound();
    error OnlyTokenOwner();
    error ReservationNotFound();
    error ReservationNotPending();
    error InvalidTimeRange();
    error NotAvailable();
    error OnlyRenter();
    error Unauthorized();
    error InvalidBooking();

    
    /// @dev Modifier to check if a token with the given ID exists.
    /// @param _tokenId The ID of the token to check.
    /// @notice Reverts if the token does not exist (i.e., its owner is the zero address).
    modifier exists(uint256 _tokenId) {
        if (IERC721(address(this)).ownerOf(_tokenId) == address(0)) revert TokenNotFound();
        _;
    }

    /// @dev Modifier to check if the caller is the owner of a specific token.
    /// @param _tokenId The ID of the token to check.
    /// @notice Reverts if the caller is not the owner of the token. 
    modifier onlyTokenOwner(uint256 _tokenId) {
        if (IERC721(address(this)).ownerOf(_tokenId) != msg.sender) revert OnlyTokenOwner();
        _;
    }

    /// @dev Modifier to ensure that a reservation exists and is in a pending state.
    /// @param _reservationKey The unique key identifying the reservation.
    /// @notice Reverts if the reservation does not exist or if its status is not pending.
    modifier reservationPending(bytes32 _reservationKey) {
        Reservation storage reservation = _s().reservations[_reservationKey];
        if (reservation.renter == address(0)) revert ReservationNotFound();
        if (reservation.status != PENDING) revert ReservationNotPending();
        _;
    }

    /// @notice Marks a token as listed by updating its status so it's possible to reserve.
    /// @dev This function can only be called by the owner of the token.
    /// @dev Requires the provider to have sufficient staked tokens based on listed labs count.
    ///      Formula: 800 base + max(0, listedLabs - 10) * 200
    /// @param _tokenId The unique identifier of the token to be listed.
    function listToken(uint256 _tokenId) external onlyTokenOwner(_tokenId) {
        AppStorage storage s = _s();
        
        // Check if already listed to avoid double-counting
        if (s.tokenStatus[_tokenId]) {
            revert("Lab already listed");
        }
        
        // Calculate required stake for new count (including this lab)
        uint256 newListedCount = s.providerStakes[msg.sender].listedLabsCount + 1;
        uint256 requiredStake = calculateRequiredStake(msg.sender, newListedCount);
        
        if (s.providerStakes[msg.sender].stakedAmount < requiredStake) {
            revert("Insufficient stake to list lab");
        }
        
        // Update listed count and status
        s.providerStakes[msg.sender].listedLabsCount = newListedCount;
        s.tokenStatus[_tokenId] = true;
        
        emit LabListed(_tokenId, msg.sender);
    }

    /// @notice Unlists a token, marking it as unavailable for reservation or other operations.
    /// @dev This function updates the token's status to `false` in the storage mapping.
    /// @dev No stake verification is required - providers can always unlist their own labs.
    /// @dev Decrements the listed labs count for the provider.
    /// @param _tokenId The unique identifier of the token to be unlisted.
    /// @dev Caller must be the owner of the token.
    function unlistToken(uint256 _tokenId) external onlyTokenOwner(_tokenId) {
        AppStorage storage s = _s();
        
        // Check if actually listed to avoid under-counting
        if (!s.tokenStatus[_tokenId]) {
            revert("Lab not listed");
        }
        
        // Decrement listed count
        if (s.providerStakes[msg.sender].listedLabsCount > 0) {
            s.providerStakes[msg.sender].listedLabsCount--;
        }
        
        s.tokenStatus[_tokenId] = false;
        emit LabUnlisted(_tokenId, msg.sender);
    }

    /// @notice Checks if a token with the given ID is listed.
    /// @param _tokenId The ID of the token to check.
    /// @return A boolean value indicating whether the token is listed.
    /// @dev The function requires the token to exist, enforced by the `exists` modifier.
    /// @dev Also verifies that the provider has sufficient staked tokens (defense in depth).
    function isTokenListed(uint256 _tokenId) external view exists(_tokenId) returns (bool) {
        AppStorage storage s = _s();
        
        // Check if token is marked as listed
        if (!s.tokenStatus[_tokenId]) {
            return false;
        }
        
        // Verify provider still has sufficient stake for current listed labs count
        address owner = IERC721(address(this)).ownerOf(_tokenId);
        uint256 listedLabsCount = s.providerStakes[owner].listedLabsCount;
        uint256 requiredStake = calculateRequiredStake(owner, listedLabsCount);
        
        return s.providerStakes[owner].stakedAmount >= requiredStake;
    }

    /// @notice Request a reservation for a specific token during a time period
    /// @dev Creates a new reservation request if the time slot is available
    /// @param _tokenId The ID of the token to be reserved
    /// @param _start The start timestamp of the reservation (must be after RESERVATION_MARGIN)
    /// @param _end The end timestamp of the reservation (must be after start)
    /// @custom:throws "Invalid time range" if start/end times are invalid
    /// @custom:throws "Not available" if the slot is already reserved
    /// @custom:emits ReservationRequested when the reservation is successfully created
    /// @dev Reservation will be created with PENDING status
    function reservationRequest(uint256 _tokenId, uint32 _start, uint32 _end) external virtual exists(_tokenId) {
        AppStorage storage s = _s();
        
        // Combined validation
        if (_start >= _end || _start <= block.timestamp + RESERVATION_MARGIN) revert InvalidTimeRange();

        bytes32 reservationKey = _getReservationKey(_tokenId, _start);
        
        // Optimized availability check
        Reservation storage existingReservation = s.reservations[reservationKey];
        bool keyExists = existingReservation.renter != address(0);
        if (keyExists && existingReservation.status != CANCELLED) revert NotAvailable();

        s.calendars[_tokenId].insert(_start, _end);
        
        // Direct assignment instead of struct initialization
        existingReservation.labId = _tokenId;
        existingReservation.renter = msg.sender;
        existingReservation.price = 0;
        existingReservation.start = _start;
        existingReservation.end = _end;
        existingReservation.status = PENDING;
        
        emit ReservationRequested(msg.sender, _tokenId, _start, _end, reservationKey);
    }


    /// @notice Confirms a reservation request for the given reservation key
    /// @dev Changes the status of the reservation from pending to booked
    /// @param _reservationKey The unique key identifying the reservation to be confirmed
    /// @dev The reservation must be in a pending state, enforced by the `reservationPending` modifier
    /// @dev Emits a `ReservationConfirmed` event upon successful confirmation
    function confirmReservationRequest(bytes32 _reservationKey) external virtual reservationPending(_reservationKey) {
        Reservation storage reservation = _s().reservations[_reservationKey];
        reservation.status = BOOKED;           
        emit ReservationConfirmed(_reservationKey, reservation.labId);          
    }

    /// @notice Denies a reservation request associated with the given reservation key.
    /// @dev Cancels the reservation and emits a `ReservationRequestDenied` event.
    /// @param _reservationKey The unique key identifying the reservation request to be denied.
    /// @dev The reservation must be in a pending state, enforced by the `reservationPending` modifier.
    function denyReservationRequest(bytes32 _reservationKey) external virtual reservationPending(_reservationKey) {
        uint256 tokenId = _s().reservations[_reservationKey].labId;
        _cancelReservation(_reservationKey);
        emit ReservationRequestDenied(_reservationKey, tokenId);
    }


    /// @notice Cancels a reservation request associated with the given reservation key.
    /// @dev This function can only be called by the renter who created the reservation request.
    ///      The reservation must exist and its status must be `PENDING` to be canceled.
    /// @param _reservationKey The unique key identifying the reservation to be canceled.
    /// @dev The reservation must exist (`renter` address is not zero).
    /// @dev The caller must be the renter who created the reservation.
    /// @dev The reservation status must be `PENDING`.
    /// @dev Emits a `ReservationRequestCanceled` event upon successful cancellation.
    function cancelReservationRequest(bytes32 _reservationKey) external virtual {
        Reservation storage reservation = _s().reservations[_reservationKey];
        
        // Combined checks
        if (reservation.renter == address(0)) revert ReservationNotFound();
        if (reservation.renter != msg.sender) revert OnlyRenter();
        if (reservation.status != PENDING) revert ReservationNotPending();

        uint256 tokenId = reservation.labId;
        _cancelReservation(_reservationKey);
        emit ReservationRequestCanceled(_reservationKey, tokenId);
    }

    /// @notice Cancels a booking associated with the given reservation key.
    /// @dev This function allows either the renter or the lab provider to cancel a booking.
    ///      The reservation must exist and its status must be `BOOKED`.
    /// @param _reservationKey The unique key identifying the reservation to be canceled.
    /// @dev The reservation must exist and its status must be `BOOKED`.
    /// @dev The caller must be either the renter or the lab provider.
    /// @dev BookingCanceled Emitted when a booking is successfully canceled.
   function cancelBooking(bytes32 _reservationKey) external virtual {
        Reservation storage reservation = _s().reservations[_reservationKey];
        
        // Combined validation
        if (reservation.renter == address(0) || reservation.status != BOOKED) revert InvalidBooking();

        address renter = reservation.renter;
        uint256 tokenId = reservation.labId;
        address labProvider = IERC721(address(this)).ownerOf(tokenId);
        
        if (renter != msg.sender && labProvider != msg.sender) revert Unauthorized();

        _cancelReservation(_reservationKey);
        emit BookingCanceled(_reservationKey, tokenId);
    }
    
    /// @notice Retrieves the address of the renter associated with a specific reservation key.
    /// @param _reservationKey The unique identifier for the reservation.
    /// @return The address of the renter linked to the reservation.
    /// @dev Reverts with "Not found" if no renter is associated with the given reservation key.
    function userOfReservation(bytes32 _reservationKey) external view returns (address) {
        address renter = _s().reservations[_reservationKey].renter;
        if (renter == address(0)) revert ReservationNotFound();
        return renter;
    }

    /// @notice Retrieves the details of a reservation using a reservation key.
    /// @param _reservationKey The unique identifier for the reservation.
    /// @return A `Reservation` struct containing the details of the reservation.
    /// @dev Reverts with "Not found" if the reservation does not exist (i.e., the renter address is zero).
    function getReservation(bytes32 _reservationKey) external view returns (Reservation memory) {
        Reservation memory reservation = _s().reservations[_reservationKey];
        if (reservation.renter == address(0)) revert ReservationNotFound();
        return reservation;
    }

    /// @param _reservationKey The unique identifier for the reservation.
    /// @param _user The address of the user to check for an active booking.
    /// @return bool Returns true if the user has an active booking, otherwise false.
    function hasActiveBooking(bytes32 _reservationKey, address _user) external view virtual returns (bool) {
        Reservation memory reservation = _s().reservations[_reservationKey];
        uint32 time = uint32(block.timestamp);
        
        return (reservation.renter == _user && 
                reservation.status == BOOKED && 
                reservation.start <= time && 
                reservation.end >= time);
    }

    /// @notice Checks if a specific time range is available for a given token ID.
    /// @dev The function verifies that the start time is less than the end time and that the start time is in the future.
    ///      It then checks if the specified time range overlaps with any existing reservations in the token's calendar.
    /// @param _tokenId The ID of the token to check availability for.
    /// @param _start The start timestamp of the time range to check.
    /// @param _end The end timestamp of the time range to check.
    /// @return bool Returns true if the time range is available, false otherwise.
    function checkAvailable(uint256 _tokenId, uint256 _start, uint256 _end) public view virtual exists(_tokenId) returns (bool) {
        // Early return pattern
        if (_start >= _end || _start <= block.timestamp) return false;
        return _s().calendars[_tokenId].overlaps(_start, _end);
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
    function getNextAvailableSlot(uint256 _tokenId, uint32 _afterTime) 
        external view virtual exists(_tokenId) returns (uint32 nextSlotStart, uint32 blockedUntil) 
    {
        Tree storage calendar = _s().calendars[_tokenId];
        
        // If no reservations at all, everything is available
        if (calendar.root == 0) {
            return (_afterTime, 0);
        }
        
        // Find first reservation at or after _afterTime using binary search
        // This is O(log n) thanks to the Red-Black tree structure
        uint cursor = calendar.root;
        uint candidate = 0;
        
        while (cursor != 0) {
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
        return (uint32(candidate), calendar.nodes[candidate].end);
    }

    /// @notice Retrieves all booked time slots for a given token (lab)
    /// @dev Performs an in-order traversal of the interval tree to collect all reservations.
    ///      Returns arrays of start and end times in chronological order.
    ///      Time complexity: O(n) where n is the number of reservations
    ///      WARNING: For labs with many reservations, this may exceed RPC gas limits in view calls.
    ///      Recommended: Use pagination or limit results in frontend.
    /// @param _tokenId The ID of the token (lab) to get booked slots for
    /// @return starts Array of start timestamps for all reservations
    /// @return ends Array of end timestamps for all reservations
    /// @custom:example If lab has reservations [1000-2000] and [3000-4000], returns ([1000, 3000], [2000, 4000])
    /// @custom:gas-warning May exceed RPC limits if lab has >100 reservations. Use with pagination.
    function getBookedSlots(uint256 _tokenId) 
        external view virtual exists(_tokenId) returns (uint32[] memory starts, uint32[] memory ends) 
    {
        Tree storage calendar = _s().calendars[_tokenId];
        
        // If no reservations, return empty arrays
        if (calendar.root == 0) {
            return (new uint32[](0), new uint32[](0));
        }
        
        // First, count total nodes to allocate arrays
        uint256 count = _countNodes(calendar, calendar.root);
        
        starts = new uint32[](count);
        ends = new uint32[](count);
        
        // Perform in-order traversal to collect all slots
        _collectSlots(calendar, calendar.root, starts, ends, 0);
        
        return (starts, ends);
    }

    /// @dev Helper function to count nodes in the tree via recursion
    /// @param calendar The interval tree storage
    /// @param cursor Current node being examined
    /// @return count Total number of nodes in subtree
    function _countNodes(Tree storage calendar, uint cursor) private view returns (uint256 count) {
        if (cursor == 0) return 0;
        
        return 1 + 
               _countNodes(calendar, calendar.nodes[cursor].left) + 
               _countNodes(calendar, calendar.nodes[cursor].right);
    }

    /// @dev Helper function to collect slots via in-order traversal
    /// @param calendar The interval tree storage
    /// @param cursor Current node being examined
    /// @param starts Array to store start times
    /// @param ends Array to store end times
    /// @param index Current index in output arrays
    /// @return nextIndex Updated index after processing this subtree
    function _collectSlots(
        Tree storage calendar, 
        uint cursor, 
        uint32[] memory starts, 
        uint32[] memory ends,
        uint256 index
    ) private view returns (uint256 nextIndex) {
        if (cursor == 0) return index;
        
        // In-order: left subtree -> current node -> right subtree
        // This naturally orders reservations chronologically
        index = _collectSlots(calendar, calendar.nodes[cursor].left, starts, ends, index);
        
        starts[index] = uint32(cursor);
        ends[index] = calendar.nodes[cursor].end;
        index++;
        
        index = _collectSlots(calendar, calendar.nodes[cursor].right, starts, ends, index);
        
        return index;
    }

    /// @notice Get comprehensive statistics about a lab's reservations
    /// @dev Single tree traversal - more efficient than multiple separate queries.
    ///      Time complexity: O(n) where n is the number of reservations
    /// @param _tokenId The ID of the token (lab) to get statistics for
    /// @return count Total number of reservations
    /// @return firstStart Start time of the earliest reservation (0 if none)
    /// @return lastEnd End time of the latest reservation (0 if none)
    /// @return totalDuration Sum of all reservation durations in seconds
    /// @custom:example For a lab with 3 reservations: [1000-2000], [3000-4000], [5000-6000]
    ///                  Returns: count=3, firstStart=1000, lastEnd=6000, totalDuration=3000
    /// @custom:use-case Dashboard analytics, revenue calculations, occupancy metrics
    function getReservationStats(uint256 _tokenId) 
        external view virtual exists(_tokenId) 
        returns (uint32 count, uint32 firstStart, uint32 lastEnd, uint64 totalDuration) 
    {
        Tree storage calendar = _s().calendars[_tokenId];
        
        // If no reservations, return zeros
        if (calendar.root == 0) {
            return (0, 0, 0, 0);
        }
        
        // Use library functions to get first and last efficiently
        firstStart = uint32(calendar.first());
        lastEnd = calendar.nodes[calendar.last()].end;
        
        // Traverse tree to count and sum durations
        (count, totalDuration) = _calculateStats(calendar, calendar.root);
        
        return (count, firstStart, lastEnd, totalDuration);
    }

    /// @dev Helper to recursively calculate count and total duration
    /// @param calendar The interval tree storage
    /// @param cursor Current node being examined
    /// @return nodeCount Number of nodes in subtree
    /// @return duration Total duration of all reservations in subtree
    function _calculateStats(Tree storage calendar, uint cursor) 
        private view returns (uint32 nodeCount, uint64 duration) 
    {
        if (cursor == 0) return (0, 0);
        
        // Recursively process left and right subtrees
        (uint32 leftCount, uint64 leftDuration) = _calculateStats(calendar, calendar.nodes[cursor].left);
        (uint32 rightCount, uint64 rightDuration) = _calculateStats(calendar, calendar.nodes[cursor].right);
        
        // Current node duration
        uint32 nodeDuration = calendar.nodes[cursor].end - uint32(cursor);
        
        // Sum everything
        nodeCount = 1 + leftCount + rightCount;
        duration = nodeDuration + leftDuration + rightDuration;
        
        return (nodeCount, duration);
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
    function findReservationAt(uint256 _tokenId, uint32 _timestamp) 
        external view virtual exists(_tokenId) returns (uint32 start, uint32 end) 
    {
        Tree storage calendar = _s().calendars[_tokenId];
        
        // If no reservations at all
        if (calendar.root == 0) {
            return (0, 0);
        }
        
        // Binary search for the reservation
        uint cursor = calendar.root;
        
        while (cursor != 0) {
            uint32 nodeStart = uint32(cursor);
            uint32 nodeEnd = calendar.nodes[cursor].end;
            
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
    /// @param _tokenId The ID of the token (lab) to search
    /// @param _rangeStart Start of the search range (Unix timestamp)
    /// @param _rangeEnd End of the search range (Unix timestamp)
    /// @param _minDuration Minimum duration in seconds for a slot to be included
    /// @return slotStarts Array of available slot start times
    /// @return slotEnds Array of available slot end times
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
        
        // Get all bookings first (already sorted chronologically)
        (uint32[] memory bookStarts, uint32[] memory bookEnds) = this.getBookedSlots(_tokenId);
        
        // Find gaps - worst case: n+1 gaps (before first, between each, after last)
        uint32[] memory tempStarts = new uint32[](bookStarts.length + 1);
        uint32[] memory tempEnds = new uint32[](bookStarts.length + 1);
        uint32 gapCount = 0;
        
        uint32 searchStart = _rangeStart;
        
        for (uint i = 0; i < bookStarts.length; i++) {
            // Skip bookings that end before our range
            if (bookEnds[i] <= _rangeStart) continue;
            
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
        for (uint i = 0; i < gapCount; i++) {
            slotStarts[i] = tempStarts[i];
            slotEnds[i] = tempEnds[i];
        }
        
        return (slotStarts, slotEnds);
    }

    /// @notice Fast check if lab has any active booking at the current time
    /// @dev O(1) if empty, O(log n) binary search otherwise.
    ///      Uses current block.timestamp to check if lab is currently in use.
    /// @param _tokenId The ID of the token (lab) to check
    /// @return bool True if lab is currently booked, false if available
    /// @custom:example At timestamp 1500: reservation [1000-2000] exists → returns true
    ///                  At timestamp 500: reservation [1000-2000] exists → returns false
    /// @custom:use-case Real-time availability checks, access control gates, status indicators
    function isLabBusy(uint256 _tokenId) external view virtual exists(_tokenId) returns (bool) {
        Tree storage calendar = _s().calendars[_tokenId];
        
        // Fast O(1) check: if no reservations at all
        if (calendar.root == 0) {
            return false;
        }
        
        // Binary search for current time - O(log n)
        uint32 now = uint32(block.timestamp);
        (uint32 start, ) = this.findReservationAt(_tokenId, now);
        
        return start != 0; // If we found a reservation, lab is busy
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
    function getNextExpiration(uint256 _tokenId) external view virtual exists(_tokenId) returns (uint32) {
        Tree storage calendar = _s().calendars[_tokenId];
        
        // If no reservations at all
        if (calendar.root == 0) {
            return 0;
        }
        
        uint32 now = uint32(block.timestamp);
        
        // First check if we're currently in a reservation
        (uint32 currentStart, uint32 currentEnd) = this.findReservationAt(_tokenId, now);
        if (currentStart != 0) {
            return currentEnd; // Return end of current reservation
        }
        
        // Not currently booked, find next future reservation
        (uint32 nextStart, uint32 nextEnd) = this.getNextAvailableSlot(_tokenId, now);
        
        // If nextStart == now and blockedUntil is set, that means there's a blocking reservation
        if (nextEnd > 0) {
            return nextEnd; // Return end of next reservation
        }
        
        return 0; // No future reservations
    }

    /// @dev Cancels a reservation identified by the given reservation key.
    ///      Updates the reservation status to CANCELLED and removes the reservation
    ///      from the associated lab's calendar.
    /// @param _reservationKey The unique key identifying the reservation to be cancelled.
    function _cancelReservation(bytes32 _reservationKey) internal virtual {
        Reservation storage reservation = _s().reservations[_reservationKey];
        reservation.status = CANCELLED;
        _s().calendars[reservation.labId].remove(reservation.start);
    }

    /// @notice Generates a unique key for token reservation based on token ID and time
    /// @dev Combines token ID and time using keccak256 hash
    /// @param _tokenId The ID of the token being reserved
    /// @param _time The timestamp for the reservation
    /// @return bytes32 A unique hash representing the reservation
    function _getReservationKey(uint256 _tokenId, uint32 _time) internal pure returns (bytes32) {  
        return keccak256(abi.encodePacked(_tokenId, _time));
    }

    /// @notice Calculates required stake for a provider based on listed labs count
    /// @dev Formula: BASE_STAKE + max(0, listedLabs - FREE_LABS_COUNT) * STAKE_PER_ADDITIONAL_LAB
    ///      - First 10 labs: 800 tokens (included in base)
    ///      - Each additional lab: +200 tokens
    /// @dev This function is public to allow access from non-inheriting facets
    /// @param provider The address of the provider
    /// @param listedLabsCount The number of labs that will be listed
    /// @return uint256 The required stake amount
    function calculateRequiredStake(address provider, uint256 listedLabsCount) public view returns (uint256) {
        AppStorage storage s = _s();
        
        // If provider never received initial tokens, no stake required
        if (!s.providerStakes[provider].receivedInitialTokens) {
            return 0;
        }
        
        // Base stake covers first 10 labs
        if (listedLabsCount <= LibAppStorage.FREE_LABS_COUNT) {
            return LibAppStorage.BASE_STAKE;
        }
        
        // Additional stake for labs beyond the free count
        uint256 additionalLabs = listedLabsCount - LibAppStorage.FREE_LABS_COUNT;
        return LibAppStorage.BASE_STAKE + (additionalLabs * LibAppStorage.STAKE_PER_ADDITIONAL_LAB);
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