// SPDX-License-Identifier: GPL-3.0-or-later
pragma solidity ^0.8.23;

import {EnumerableSet} from "@openzeppelin/contracts/utils/structs/EnumerableSet.sol";
import {IERC721} from "@openzeppelin/contracts/token/ERC721/IERC721.sol";
import {ReservableToken} from "./ReservableToken.sol";
import {RecentReservationBuffer, UpcomingReservationBuffer, PastReservationBuffer, Reservation, AppStorage} from "../libraries/LibAppStorage.sol";
import {RivalIntervalTreeLibrary, Tree} from "../libraries/RivalIntervalTreeLibrary.sol";

/// @title ReservableTokenEnumerable
/// @author
/// - Juan Luis Ramos Villalón
/// - Luis de la Torre Cubillo
/// @dev Abstract contract by design (prevents direct deployment in Diamond pattern)
/// @notice Provides complete wallet reservation implementation with enumerable functionality
///
/// @dev This contract fully implements all abstract functions from ReservableToken but is marked
///      as abstract to enforce inheritance-only usage. It should never be deployed directly,
///      only inherited by facets like WalletReservationFacet.
abstract contract ReservableTokenEnumerable is ReservableToken {
    using RivalIntervalTreeLibrary for Tree;
    using EnumerableSet for EnumerableSet.Bytes32Set;

    /// @dev Custom errors to replace require strings for better gas efficiency and clarity.
    /// @dev These errors are used to revert transactions with specific error messages.     
    error IndexOutOfBounds();
    error InvalidAddress();
    error InvalidReservation();
    error MaxReservationsReached();
    
    /// @dev Maximum number of active future reservations per user per lab
    uint8 constant MAX_RESERVATIONS_PER_LAB_USER = 10;
    uint8 internal constant TOKEN_BUFFER_CAP = 40;
    uint8 internal constant USER_BUFFER_CAP = 20;

    /// @notice Allows a user to request a reservation for a specific token during a time period
    /// @dev Creates a new reservation request and adds it to tracking sets
    /// @param _tokenId The ID of the token to be reserved
    /// @param _start The start timestamp of the reservation period
    /// @param _end The end timestamp of the reservation period
    /// @custom:throws If the lab is not listed for reservations
    /// @custom:throws If the time range is invalid (start >= end or start <= current time)
    /// @custom:throws If the token is already reserved for the given period
    /// @custom:throws If the token doesn't exist (via exists modifier)
    /// @custom:event ReservationRequested when a reservation is successfully requested
    function reservationRequest(uint256 _tokenId, uint32 _start, uint32 _end) external virtual override exists(_tokenId) {
        AppStorage storage s = _s();
        
        // Check if lab is listed for reservations
        if (!s.tokenStatus[_tokenId]) revert("Lab not listed for reservations");
        
        if (_start >= _end || _start <= block.timestamp) 
            revert InvalidTimeRange();
        
        bytes32 reservationKey = _getReservationKey(_tokenId, _start);
        
        // Optimized availability check
        Reservation storage existing = s.reservations[reservationKey];
        if (existing.renter != address(0) && existing.status != CANCELLED && existing.status != COLLECTED) {
            revert NotAvailable();
        }

        s.calendars[_tokenId].insert(_start, _end);
        
        // Use EnumerableSet which maintains count internally
        s.reservationKeysByToken[_tokenId].add(reservationKey);
        
        // Get lab owner at reservation time for security and consistency
        address labOwner = IERC721(address(this)).ownerOf(_tokenId);
        
        // Direct assignment to existing storage slot
        Reservation storage newReservation = s.reservations[reservationKey];
        newReservation.labId = _tokenId;
        newReservation.renter = msg.sender;
        newReservation.labProvider = labOwner;
        newReservation.price = 0;
        newReservation.start = _start;
        newReservation.end = _end;
        newReservation.status = PENDING;
        
        // Batch set operations
        s.totalReservationsCount++;
        s.renters[msg.sender].add(reservationKey);
        
        emit ReservationRequested(msg.sender, _tokenId, _start, _end, reservationKey);
    }

    /// @notice Confirms a pending reservation request for a lab
    /// @dev Changes the status of a reservation from PENDING to CONFIRMED and associates it with the lab provider
    /// @param _reservationKey The unique identifier of the reservation to confirm
    /// @custom:event ReservationConfirmed Emitted when the reservation is successfully confirmed
    /// @custom:requirements Reservation must be in PENDING status (checked by reservationPending modifier)
    function confirmReservationRequest(bytes32 _reservationKey) external reservationPending(_reservationKey) virtual override {
        AppStorage storage s = _s();
        Reservation storage reservation = s.reservations[_reservationKey];
        
        // Check if user has reached maximum reservations for this lab
        if (s.activeReservationCountByTokenAndUser[reservation.labId][reservation.renter] >= MAX_RESERVATIONS_PER_LAB_USER) {
            revert MaxReservationsReached();
        }
        
        reservation.status = CONFIRMED;
        
        // Increment active reservation count for this (token, user)
        s.activeReservationCountByTokenAndUser[reservation.labId][reservation.renter]++;
        
        // Add to per-token-user index for efficient queries
        s.reservationKeysByTokenAndUser[reservation.labId][reservation.renter].add(_reservationKey);
        
        // Update active reservation index: only store the earliest (closest in time) reservation
        bytes32 currentIndexKey = s.activeReservationByTokenAndUser[reservation.labId][reservation.renter];
        
        if (currentIndexKey == bytes32(0)) {
            // No existing index entry → this is the first reservation
            s.activeReservationByTokenAndUser[reservation.labId][reservation.renter] = _reservationKey;
        } else {
            // Already have an indexed reservation → only update if new one starts earlier
            Reservation memory currentReservation = s.reservations[currentIndexKey];
            if (reservation.start < currentReservation.start) {
                s.activeReservationByTokenAndUser[reservation.labId][reservation.renter] = _reservationKey;
            }
        }
        
        emit ReservationConfirmed(_reservationKey, reservation.labId);
    }

    /// @notice Cancels an existing booking reservation
    /// @dev Can only be called by the renter or the lab provider
    /// @param _reservationKey The unique identifier of the reservation to cancel
    /// @custom:throws If the reservation is invalid or caller is not authorized
    /// @custom:emits BookingCanceled event with the reservation key
    function cancelBooking(bytes32 _reservationKey) external virtual override {
        AppStorage storage s = _s();
        Reservation storage reservation = s.reservations[_reservationKey];
        
        // Combined validation - check for CONFIRMED or IN_USE
        if (reservation.renter == address(0) || 
            (reservation.status != CONFIRMED && reservation.status != IN_USE)) {
            revert InvalidReservation();
        }

        address renter = reservation.renter;
        uint256 tokenId = reservation.labId;
        address labProvider = IERC721(address(this)).ownerOf(tokenId);
        
        if (renter != msg.sender && labProvider != msg.sender) revert Unauthorized();

        _cancelReservation(_reservationKey);

        emit BookingCanceled(_reservationKey, tokenId);
    }

    /// @notice Returns the total number of existing reservations across all labs
    /// @dev This is a global counter metric. There is no global enumerator to iterate all reservations.
    ///      To enumerate reservations, use per-token or per-user getters instead.
    /// @return The total count of reservations as a uint256
    function totalReservations() external view returns (uint256) {
        return _s().totalReservationsCount;
    }

    /// @notice Get the number of reservations for a specific user
    /// @dev Retrieves the length of the reservation array for the given user address
    /// @param _user The address of the user to check reservations for
    /// @return The number of active reservations for the user
    /// @custom:throws "Invalid address" if the provided address is zero
    function reservationsOf(address _user) external view returns (uint256) {
        if (_user == address(0)) revert InvalidAddress();
        return _s().renters[_user].length();
    }

    /// @notice Retrieves the reservation key at a specific index for a given user
    /// @dev Returns the reservation key from an EnumerableSet. Order is NOT guaranteed to be stable
    ///      across mutations (add/remove). Use for snapshot iteration only, not for persistent pagination.
    /// @param _user The address of the user whose reservation key is being queried
    /// @param _index The index position in the user's reservation set (0-based)
    /// @return bytes32 The reservation key at the specified index
    /// @custom:warning Order may change between calls if set is modified
    /// @custom:revert If the index is greater than or equal to the length of the user's reservation set
    function reservationKeyOfUserByIndex(address _user, uint256 _index) external view returns (bytes32) {
        AppStorage storage s = _s();
        if (_index >= s.renters[_user].length()) revert IndexOutOfBounds();
        return s.renters[_user].at(_index);
    }

    /// @notice Gets the total number of reservations for a specific token
    /// @dev Requires the token to exist (checked by exists modifier)
    /// @param _tokenId The ID of the token to query reservations for
    /// @return The total number of reservations for the specified token
    function getReservationsOfToken(uint256 _tokenId) public view virtual exists(_tokenId) returns (uint) {
        return _s().reservationKeysByToken[_tokenId].length();
    }

    /// @notice Retrieves a specific reservation key for a token by its index
    /// @dev Returns from EnumerableSet. Order is NOT guaranteed to be stable across mutations.
    ///      Use for snapshot iteration only, not for persistent pagination.
    /// @param _tokenId The ID of the token to query
    /// @param _index The index position of the reservation to retrieve (0-based)
    /// @return bytes32 The reservation key at the specified index
    /// @custom:warning Order may change between calls if set is modified
    /// @custom:throws If token doesn't exist or if index is out of bounds
    function getReservationOfTokenByIndex(uint256 _tokenId, uint256 _index) external view exists(_tokenId) returns (bytes32) {
        AppStorage storage s = _s();
        if (_index >= s.reservationKeysByToken[_tokenId].length()) revert IndexOutOfBounds();
        return s.reservationKeysByToken[_tokenId].at(_index);
    }

    /// @notice Paginated access to reservation keys of a token
    /// @dev Iterates over EnumerableSet which has NO guaranteed order. Order may shift when elements
    ///      are added/removed. Suitable for snapshot iteration within a single view call, NOT for
    ///      stateful cursor-based pagination across multiple transactions.
    /// @param _tokenId The ID of the token to query
    /// @param offset Starting index (0-based)
    /// @param limit Maximum number of keys to return (1-100)
    /// @return keys Array of reservation keys for the requested page
    /// @return total Total number of reservations for this token
    /// @custom:warning Order may change between calls if set is modified
    function getReservationsOfTokenPaginated(
        uint256 _tokenId,
        uint256 offset,
        uint256 limit
    ) external view exists(_tokenId) returns (bytes32[] memory keys, uint256 total) {
        AppStorage storage s = _s();
        total = s.reservationKeysByToken[_tokenId].length();
        require(limit > 0 && limit <= 100, "Invalid limit");
        if (offset >= total) {
            return (new bytes32[](0), total);
        }
        uint256 end = offset + limit;
        if (end > total) end = total;
        uint256 size = end - offset;
        keys = new bytes32[](size);
        for (uint256 i; i < size; i++) {
            keys[i] = s.reservationKeysByToken[_tokenId].at(offset + i);
        }
    }

    /// @notice Returns the most recent past reservation keys for a token ordered by end time (desc)
    /// @dev Uses fixed-size buffer maintained on cancellation/collection; maxScan kept for ABI compatibility
    function getRecentReservationsOfToken(
        uint256 _tokenId,
        uint256 maxCount,
        uint256 maxScan
    ) external view exists(_tokenId) returns (bytes32[] memory keys) {
        maxScan; // kept for ABI compatibility
        AppStorage storage s = _s();
        PastReservationBuffer storage buf = s.pastReservationsByToken[_tokenId];
        if (buf.size == 0 || maxCount == 0) {
            return new bytes32[](0);
        }
        uint256 size = buf.size;
        if (size > TOKEN_BUFFER_CAP) size = TOKEN_BUFFER_CAP;
        uint256 take = size < maxCount ? size : maxCount;
        keys = new bytes32[](take);
        for (uint256 i; i < take; i++) {
            keys[i] = buf.keys[i];
        }
    }

    /// @notice Returns upcoming (current/future) reservation keys for a token ordered by start time (asc)
    /// @dev Filters out expired/cancelled entries from the fixed-size buffer; capped at 40 entries for token-level
    function getUpcomingReservationsOfToken(
        uint256 _tokenId,
        uint256 maxCount
    ) external view exists(_tokenId) returns (bytes32[] memory keys) {
        AppStorage storage s = _s();
        UpcomingReservationBuffer storage buf = s.upcomingReservationsByToken[_tokenId];
        if (buf.size == 0 || maxCount == 0) {
            return new bytes32[](0);
        }
        uint256 size = buf.size;
        if (size > TOKEN_BUFFER_CAP) size = TOKEN_BUFFER_CAP;
        uint256 take = size < maxCount ? size : maxCount;
        bytes32[] memory tmp = new bytes32[](take);
        uint256 found;
        uint32 currentTime = uint32(block.timestamp);
        for (uint256 i; i < size && found < maxCount; i++) {
            bytes32 key = buf.keys[i];
            Reservation storage r = s.reservations[key];
            if (r.end < currentTime || r.status == CANCELLED) {
                continue;
            }
            tmp[found] = key;
            found++;
        }
        if (found == take) {
            return tmp;
        }
        keys = new bytes32[](found);
        for (uint256 j; j < found; j++) {
            keys[j] = tmp[j];
        }
    }

    /// @notice Paginated access to reservation keys for a token/user pair
    /// @dev Iterates over EnumerableSet which has NO guaranteed order. Order may shift when elements
    ///      are added/removed. Suitable for snapshot iteration within a single view call.
    /// @param _tokenId The ID of the token to query
    /// @param _user The address of the user
    /// @param offset Starting index (0-based)
    /// @param limit Maximum number of keys to return (1-100)
    /// @return keys Array of reservation keys for the requested page
    /// @return total Total number of reservations for this token/user pair
    /// @custom:warning Order may change between calls if set is modified
    function getReservationsOfTokenByUserPaginated(
        uint256 _tokenId,
        address _user,
        uint256 offset,
        uint256 limit
    ) external view exists(_tokenId) returns (bytes32[] memory keys, uint256 total) {
        AppStorage storage s = _s();
        EnumerableSet.Bytes32Set storage set = s.reservationKeysByTokenAndUser[_tokenId][_user];
        total = set.length();
        require(limit > 0 && limit <= 100, "Invalid limit");
        if (offset >= total) {
            return (new bytes32[](0), total);
        }
        uint256 end = offset + limit;
        if (end > total) end = total;
        uint256 size = end - offset;
        keys = new bytes32[](size);
        for (uint256 i; i < size; i++) {
            keys[i] = set.at(offset + i);
        }
    }

    /// @notice Recent past reservations for a token/user ordered by end time (desc), with scan cap
    function getRecentReservationsOfTokenByUser(
        uint256 _tokenId,
        address _user,
        uint256 maxCount,
        uint256 maxScan
    ) external view exists(_tokenId) returns (bytes32[] memory keys) {
        maxScan; // kept for ABI compatibility
        AppStorage storage s = _s();
        PastReservationBuffer storage buf = s.pastReservationsByTokenAndUser[_tokenId][_user];
        if (buf.size == 0 || maxCount == 0) {
            return new bytes32[](0);
        }
        uint256 size = buf.size;
        if (size > USER_BUFFER_CAP) size = USER_BUFFER_CAP;
        uint256 take = size < maxCount ? size : maxCount;
        keys = new bytes32[](take);
        for (uint256 i; i < take; i++) {
            keys[i] = buf.keys[i];
        }
    }

    /// @notice Upcoming (current/future) reservations for a token/user ordered by start time (asc)
    /// @dev Filters out expired/cancelled entries from the fixed-size buffer; capped at 20 entries for user-level
    function getUpcomingReservationsOfTokenByUser(
        uint256 _tokenId,
        address _user,
        uint256 maxCount
    ) external view exists(_tokenId) returns (bytes32[] memory keys) {
        AppStorage storage s = _s();
        UpcomingReservationBuffer storage buf = s.upcomingReservationsByTokenAndUser[_tokenId][_user];
        if (buf.size == 0 || maxCount == 0) {
            return new bytes32[](0);
        }
        uint256 size = buf.size;
        if (size > USER_BUFFER_CAP) size = USER_BUFFER_CAP;
        uint256 take = size < maxCount ? size : maxCount;
        bytes32[] memory tmp = new bytes32[](take);
        uint256 found;
        uint32 currentTime = uint32(block.timestamp);
        for (uint256 i; i < size && found < maxCount; i++) {
            bytes32 key = buf.keys[i];
            Reservation storage r = s.reservations[key];
            if (r.end < currentTime || r.status == CANCELLED) {
                continue;
            }
            tmp[found] = key;
            found++;
        }
        if (found == take) {
            return tmp;
        }
        keys = new bytes32[](found);
        for (uint256 j; j < found; j++) {
            keys[j] = tmp[j];
        }
    }

    function _recordRecent(
        AppStorage storage s,
        uint256 labId,
        address userTrackingKey,
        bytes32 reservationKey,
        uint32 startTime
    ) internal {
        _insertRecent(s.recentReservationsByToken[labId], reservationKey, startTime, TOKEN_BUFFER_CAP);
        _insertRecent(s.recentReservationsByTokenAndUser[labId][userTrackingKey], reservationKey, startTime, USER_BUFFER_CAP);
        _insertUpcoming(s.upcomingReservationsByToken[labId], reservationKey, startTime, TOKEN_BUFFER_CAP);
        _insertUpcoming(s.upcomingReservationsByTokenAndUser[labId][userTrackingKey], reservationKey, startTime, USER_BUFFER_CAP);
    }

    function _recordPast(
        AppStorage storage s,
        uint256 labId,
        address userTrackingKey,
        bytes32 reservationKey,
        uint32 endTime
    ) internal {
        _insertPast(s.pastReservationsByToken[labId], reservationKey, endTime, TOKEN_BUFFER_CAP);
        _insertPast(s.pastReservationsByTokenAndUser[labId][userTrackingKey], reservationKey, endTime, USER_BUFFER_CAP);
    }

    function _insertRecent(
        RecentReservationBuffer storage buf,
        bytes32 key,
        uint32 startTime,
        uint8 cap
    ) internal {
        uint8 size = buf.size;
        if (size > cap) {
            size = cap;
            buf.size = cap;
        }
        // If buffer full and new entry is older than or equal to last, ignore
        if (size == cap && startTime <= buf.starts[size - 1]) {
            return;
        }
        // Find insertion position (desc by start)
        uint8 pos = size;
        while (pos > 0 && startTime > buf.starts[pos - 1]) {
            pos--;
        }
        // Shift to make room, capping at cap
        uint8 upper = size < cap ? size : cap - 1;
        for (uint8 i = upper; i > pos; i--) {
            buf.keys[i] = buf.keys[i - 1];
            buf.starts[i] = buf.starts[i - 1];
        }
        buf.keys[pos] = key;
        buf.starts[pos] = startTime;
        if (size < cap) {
            buf.size = size + 1;
        }
    }

    function _insertUpcoming(
        UpcomingReservationBuffer storage buf,
        bytes32 key,
        uint32 startTime,
        uint8 cap
    ) internal {
        uint8 size = buf.size;
        if (size > cap) {
            size = cap;
            buf.size = cap;
        }
        // If buffer full and new entry is later than or equal to the last, ignore (keep earliest cap)
        if (size == cap && startTime >= buf.starts[size - 1]) {
            return;
        }
        // Find insertion position (asc by start)
        uint8 pos = size;
        while (pos > 0 && startTime < buf.starts[pos - 1]) {
            pos--;
        }
        // Shift to make room, capping at cap
        uint8 upper = size < cap ? size : cap - 1;
        for (uint8 i = upper; i > pos; i--) {
            buf.keys[i] = buf.keys[i - 1];
            buf.starts[i] = buf.starts[i - 1];
        }
        buf.keys[pos] = key;
        buf.starts[pos] = startTime;
        if (size < cap) {
            buf.size = size + 1;
        }
    }

    function _insertPast(
        PastReservationBuffer storage buf,
        bytes32 key,
        uint32 endTime,
        uint8 cap
    ) internal {
        uint8 size = buf.size;
        if (size > cap) {
            size = cap;
            buf.size = cap;
        }
        // If buffer full and new entry is older than or equal to the last, ignore (keep most recent cap)
        if (size == cap && endTime <= buf.ends[size - 1]) {
            return;
        }
        // Find insertion position (desc by end)
        uint8 pos = size;
        while (pos > 0 && endTime > buf.ends[pos - 1]) {
            pos--;
        }
        // Shift to make room, capping at cap
        uint8 upper = size < cap ? size : cap - 1;
        for (uint8 i = upper; i > pos; i--) {
            buf.keys[i] = buf.keys[i - 1];
            buf.ends[i] = buf.ends[i - 1];
        }
        buf.keys[pos] = key;
        buf.ends[pos] = endTime;
        if (size < cap) {
            buf.size = size + 1;
        }
    }

    /// @notice Checks if a user has an active booking for a specific token
    /// @dev A booking is considered active if it's in CONFIRMED or IN_USE status and current time is within [start, end]
    ///      Uses lazy cleanup: if the indexed reservation has expired, searches for the next active one
    ///      Optimized scan: only iterates through reservations for this specific (token, user) pair
    /// @param _tokenId The ID of the token to check
    /// @param _user The address of the user to check
    /// @return bool True if the user has an active booking for the token, false otherwise
    function hasActiveBookingByToken(uint256 _tokenId, address _user) external view virtual exists(_tokenId) returns (bool) {
        AppStorage storage s = _s();
        bytes32 reservationKey = s.activeReservationByTokenAndUser[_tokenId][_user];
        
        // If no index entry, no active booking
        if (reservationKey == bytes32(0)) return false;
        
        // Verify the reservation is still valid and active
        Reservation memory reservation = s.reservations[reservationKey];
        uint32 time = uint32(block.timestamp);
        
        // Fast path: indexed reservation is currently active
        // Check for CONFIRMED or IN_USE (both are active paid reservations)
        if ((reservation.status == CONFIRMED || reservation.status == IN_USE) && 
            reservation.start <= time && 
            reservation.end >= time) {
            return true;
        }
        
        // Slow path: index is stale (reservation ended, cancelled, or not started yet)
        // Scan only reservations for this specific (token, user) pair (max 10 iterations)
        return _hasActiveBookingByScan(_tokenId, _user, time);
    }
    
    /// @dev Internal helper to scan for active bookings when index is stale
    ///      Uses the per-token-user index for efficient scanning (max 10 iterations)
    /// @param _tokenId The ID of the token to check
    /// @param _user The address of the user to check
    /// @param time Current timestamp
    /// @return bool True if an active booking exists
    function _hasActiveBookingByScan(uint256 _tokenId, address _user, uint32 time) internal view returns (bool) {
        AppStorage storage s = _s();
        EnumerableSet.Bytes32Set storage tokenUserReservations = s.reservationKeysByTokenAndUser[_tokenId][_user];
        
        for (uint i = 0; i < tokenUserReservations.length(); i++) {
            bytes32 key = tokenUserReservations.at(i);
            Reservation memory res = s.reservations[key];
            
            // Check for CONFIRMED or IN_USE (both are active paid reservations)
            if ((res.status == CONFIRMED || res.status == IN_USE) && 
                res.start <= time && 
                res.end >= time) {
                return true;
            }
        }
        
        return false;
    }

    /// @notice Get the active reservation key for a user on a specific token
    /// @dev Returns the reservation key if the user has an active booking, otherwise returns bytes32(0)
    ///      Uses lazy cleanup: if the indexed reservation has expired, searches for the next active one
    ///      Optimized scan: only iterates through reservations for this specific (token, user) pair
    /// @param _tokenId The lab token ID
    /// @param _user The user's address
    /// @return reservationKey The active reservation key, or bytes32(0) if no active reservation exists
    function getActiveReservationKeyForUser(uint256 _tokenId, address _user) external view virtual exists(_tokenId) returns (bytes32) {
        if (_user == address(0)) revert InvalidAddress();
        
        AppStorage storage s = _s();
        bytes32 reservationKey = s.activeReservationByTokenAndUser[_tokenId][_user];
        
        // If no index entry, return bytes32(0)
        if (reservationKey == bytes32(0)) return bytes32(0);
        
        // Verify the reservation is still valid and active
        Reservation memory reservation = s.reservations[reservationKey];
        uint32 time = uint32(block.timestamp);
        
        // Fast path: indexed reservation is currently active
        // Check for CONFIRMED or IN_USE (both are active paid reservations)
        if ((reservation.status == CONFIRMED || reservation.status == IN_USE) && 
            reservation.start <= time && 
            reservation.end >= time) {
            return reservationKey;
        }
        
        // Slow path: index is stale, scan for active booking (max 10 iterations)
        return _getActiveReservationKeyByScan(_tokenId, _user, time);
    }
    
    /// @dev Internal helper to scan for active reservation key when index is stale
    ///      Uses the per-token-user index for efficient scanning (max 10 iterations)
    /// @param _tokenId The ID of the token to check
    /// @param _user The address of the user to check
    /// @param time Current timestamp
    /// @return bytes32 The active reservation key, or bytes32(0) if none found
    function _getActiveReservationKeyByScan(uint256 _tokenId, address _user, uint32 time) internal view returns (bytes32) {
        AppStorage storage s = _s();
        EnumerableSet.Bytes32Set storage tokenUserReservations = s.reservationKeysByTokenAndUser[_tokenId][_user];
        
        for (uint i = 0; i < tokenUserReservations.length(); i++) {
            bytes32 key = tokenUserReservations.at(i);
            Reservation memory res = s.reservations[key];
            
            // Check for CONFIRMED or IN_USE (both are active paid reservations)
            if ((res.status == CONFIRMED || res.status == IN_USE) && 
                res.start <= time && 
                res.end >= time) {
                return key;
            }
        }
        
        return bytes32(0);
    }

    /// @dev Cancels an existing reservation by removing it from the renter's list and then
    ///      calling the parent implementation to complete the cancellation process.
    ///      Also updates the active reservation index if the cancelled reservation was the indexed one.
    /// @param _reservationKey The unique identifier of the reservation to be canceled
    /// @notice This function removes the reservation from both the renter's list and through
    ///         the parent implementation
    function _cancelReservation(bytes32 _reservationKey) internal virtual override {
        AppStorage storage s = _s();
        Reservation storage reservation = s.reservations[_reservationKey];

        if (reservation.status == CONFIRMED || reservation.status == IN_USE || reservation.status == PENDING) {
            if (s.activeReservationCountByTokenAndUser[reservation.labId][reservation.renter] > 0) {
                s.activeReservationCountByTokenAndUser[reservation.labId][reservation.renter]--;
            }
            s.reservationKeysByTokenAndUser[reservation.labId][reservation.renter].remove(_reservationKey);

            if ((reservation.status == CONFIRMED || reservation.status == IN_USE) &&
                s.activeReservationByTokenAndUser[reservation.labId][reservation.renter] == _reservationKey) {
                bytes32 nextKey = _findNextEarliestReservation(reservation.labId, reservation.renter);
                s.activeReservationByTokenAndUser[reservation.labId][reservation.renter] = nextKey;
            }
        }

        s.reservationKeysByToken[reservation.labId].remove(_reservationKey);
        s.renters[reservation.renter].remove(_reservationKey);

        _recordPastOnCancel(s, reservation, _reservationKey);

        super._cancelReservation(_reservationKey);
    }

    /// @dev Hook to track past reservations on cancel; overridable for institutional tracking keys
    function _recordPastOnCancel(
        AppStorage storage s,
        Reservation storage reservation,
        bytes32 reservationKey
    ) internal virtual {
        // Use cancellation time to reflect recency for user history
        _recordPast(s, reservation.labId, reservation.renter, reservationKey, uint32(block.timestamp));
    }
    
    /// @dev Internal helper to find the next earliest active reservation for a (token, user) pair
    ///      Uses the per-token-user index for efficient scanning (max 10 iterations)
    /// @param _tokenId The ID of the token
    /// @param _user The user's address
    /// @return bytes32 The reservation key of the earliest active/future reservation, or bytes32(0) if none
    function _findNextEarliestReservation(uint256 _tokenId, address _user) internal view returns (bytes32) {
        AppStorage storage s = _s();
        EnumerableSet.Bytes32Set storage tokenUserReservations = s.reservationKeysByTokenAndUser[_tokenId][_user];
        
        bytes32 earliestKey = bytes32(0);
        uint32 earliestStart = type(uint32).max;
        
        for (uint256 i = 0; i < tokenUserReservations.length(); i++) {
            bytes32 key = tokenUserReservations.at(i);
            Reservation memory res = s.reservations[key];
            
            // Only consider CONFIRMED or IN_USE reservations that haven't ended yet
            if ((res.status == CONFIRMED || res.status == IN_USE) && 
                res.end >= block.timestamp &&
                res.start < earliestStart) {
                earliestKey = key;
                earliestStart = res.start;
            }
        }
        
        return earliestKey;
    }
}
