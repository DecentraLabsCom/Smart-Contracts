// SPDX-License-Identifier: GPL-3.0-or-later
pragma solidity ^0.8.23;

import {EnumerableSet} from "@openzeppelin/contracts/utils/structs/EnumerableSet.sol";
import {IERC721} from "@openzeppelin/contracts/token/ERC721/IERC721.sol";
import "./ReservableToken.sol";

/// @title ReservableTokenEnumerable
/// @author
/// - Juan Luis Ramos Villalón
/// - Luis de la Torre Cubillo
/// @dev Abstract contract extending ReservableToken with enumerable functionality for token reservations
/// @notice Provides enumerable capabilities for token reservations including tracking and querying
///
/// @dev This contract implements enumerable functionality for reservations including:
/// - Reservation requests and confirmations
/// - Booking cancellations 
/// - Reservation tracking and querying
/// - Token-specific reservation management
///
/// The contract uses RivalIntervalTreeLibrary for managing time intervals and
/// EnumerableSet for efficient set operations on reservation keys.
///
/// Key features:
/// - Request and confirm reservations for tokens
/// - Cancel existing bookings
/// - Query reservations by token, user or index
/// - Track active bookings
/// - Enumerate through all reservations
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
        bool keyExists = s.reservationKeys.contains(reservationKey);
        if (keyExists && s.reservations[reservationKey].status != CANCELLED) {
            revert NotAvailable();
        }

        s.calendars[_tokenId].insert(_start, _end);
        
        // Gas optimizations: O(1) operations
        s.reservationCountByToken[_tokenId]++;
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
        s.reservationKeys.add(reservationKey);
        s.renters[msg.sender].add(reservationKey);
        
        emit ReservationRequested(msg.sender, _tokenId, _start, _end, reservationKey);
    }

    /// @notice Confirms a pending reservation request for a lab
    /// @dev Changes the status of a reservation from PENDING to BOOKED and associates it with the lab provider
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
        
        reservation.status = BOOKED;
        s.reservationsProvider[reservation.labProvider].add(_reservationKey);
        
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
        
        // Combined validation
        if (reservation.renter == address(0) || reservation.status != BOOKED) {
            revert InvalidReservation();
        }

        address renter = reservation.renter;
        uint256 tokenId = reservation.labId;
        address labProvider = IERC721(address(this)).ownerOf(tokenId);
        
        if (renter != msg.sender && labProvider != msg.sender) revert Unauthorized();

        s.reservationsProvider[labProvider].remove(_reservationKey);
        _cancelReservation(_reservationKey);

        emit BookingCanceled(_reservationKey, tokenId);
    }

    /// @notice Returns the total number of existing reservations
    /// @dev Retrieves the length of the reservationKeys array from storage
    /// @return The total count of reservations as a uint256
    function totalReservations() external view returns (uint256) {
        return _s().reservationKeys.length();
    }

    /// @notice Retrieves a reservation key at a specified index from the stored reservation keys
    /// @dev Reverts if the index is out of bounds
    /// @param _index The index at which to retrieve the reservation key
    /// @return bytes32 The reservation key at the specified index
    function reservationKeyByIndex(uint256 _index) external view returns (bytes32) {
        AppStorage storage s = _s();
        if (_index >= s.reservationKeys.length()) revert IndexOutOfBounds();
        return s.reservationKeys.at(_index);
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
    /// @dev Returns the reservation key stored in the user's array of reservations at the specified index
    /// @param _user The address of the user whose reservation key is being queried
    /// @param _index The index position in the user's reservation array
    /// @return bytes32 The reservation key at the specified index
    /// @custom:revert If the index is greater than or equal to the length of the user's reservation array
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
        return _s().reservationCountByToken[_tokenId];
    }

    /// @notice Retrieves a specific reservation key for a token by its index
    /// @dev Requires the token to exist. The index must be within bounds of existing reservations
    /// @param _tokenId The ID of the token to query
    /// @param _index The index position of the reservation to retrieve
    /// @return bytes32 The reservation key at the specified index
    /// @custom:throws If token doesn't exist or if index is out of bounds
    function getReservationOfTokenByIndex(uint256 _tokenId, uint256 _index) external view exists(_tokenId) returns (bytes32) {
        AppStorage storage s = _s();
        if (_index >= s.reservationKeysByToken[_tokenId].length()) revert IndexOutOfBounds();
        return s.reservationKeysByToken[_tokenId].at(_index);
    }

    /// @notice Checks if a user has an active booking for a specific token
    /// @dev A booking is considered active if it's in BOOKED status and current time is within [start, end]
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
        if (reservation.status == BOOKED && 
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
            
            if (res.status == BOOKED && 
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
        if (reservation.status == BOOKED && 
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
            
            if (res.status == BOOKED && 
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
    function _cancelReservation(bytes32 _reservationKey) internal override {
        AppStorage storage s = _s();
        Reservation storage reservation = s.reservations[_reservationKey];
        
        // Decrement counter and remove from indices for BOOKED OR PENDING reservations
        // This handles both confirmed bookings and pending requests (prevents DoS)
        if (reservation.status == BOOKED || reservation.status == PENDING) {
            // Handle institutional vs wallet reservations differently
            // Institutional reservations use hash(provider, puc) as tracking key
            address trackingKey;
            if (bytes(reservation.puc).length > 0) {
                // Institutional reservation - use composite key
                // reservation.renter == institutionalProvider (set at request time)
                trackingKey = address(uint160(uint256(keccak256(abi.encodePacked(reservation.renter, reservation.puc)))));
            } else {
                // Wallet reservation - use renter directly
                trackingKey = reservation.renter;
            }
            
            s.activeReservationCountByTokenAndUser[reservation.labId][trackingKey]--;
            s.reservationKeysByTokenAndUser[reservation.labId][trackingKey].remove(_reservationKey);
            
            // Update earliest reservation index (only if BOOKED)
            if (reservation.status == BOOKED && 
                s.activeReservationByTokenAndUser[reservation.labId][trackingKey] == _reservationKey) {
                bytes32 nextKey = _findNextEarliestReservation(reservation.labId, trackingKey);
                s.activeReservationByTokenAndUser[reservation.labId][trackingKey] = nextKey;
            }
        }
        
        // Gas optimizations: O(1) operations
        s.reservationCountByToken[reservation.labId]--;
        s.reservationKeysByToken[reservation.labId].remove(_reservationKey);
        
        s.renters[reservation.renter].remove(_reservationKey);
        
        super._cancelReservation(_reservationKey);
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
        
        for (uint i = 0; i < tokenUserReservations.length(); i++) {
            bytes32 key = tokenUserReservations.at(i);
            Reservation memory res = s.reservations[key];
            
            // Only consider BOOKED reservations that haven't ended yet
            if (res.status == BOOKED && 
                res.end >= block.timestamp &&
                res.start < earliestStart) {
                earliestKey = key;
                earliestStart = res.start;
            }
        }
        
        return earliestKey;
    }
}