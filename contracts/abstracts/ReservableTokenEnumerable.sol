// SPDX-License-Identifier: GPL-2.0-or-later
pragma solidity ^0.8.23;

import {EnumerableSet} from "@openzeppelin/contracts/utils/structs/EnumerableSet.sol";
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
///
abstract contract ReservableTokenEnumerable is ReservableToken {
    using RivalIntervalTreeLibrary for Tree;
    using EnumerableSet for EnumerableSet.Bytes32Set;

    ///@notice Node value representing an empty node in the tree
    uint private constant EMPTY = 0;

    /// @notice Allows a user to request a reservation for a specific token during a time period
    /// @dev Creates a new reservation request and adds it to tracking sets
    /// @param _tokenId The ID of the token to be reserved
    /// @param _start The start timestamp of the reservation period
    /// @param _end The end timestamp of the reservation period
    /// @custom:throws If the time range is invalid (start >= end or start <= current time)
    /// @custom:throws If the token is already reserved for the given period
    /// @custom:throws If the token doesn't exist (via exists modifier)
    /// @custom:event ReservationRequested when a reservation is successfully requested
    function reservationRequest(uint256 _tokenId, uint32 _start, uint32 _end) external virtual override exists(_tokenId) {
        // Combined validation
        require(_start < _end && _start > block.timestamp, "Invalid time range");
        
        // Store storage pointer to reduce SLOAD operations
        AppStorage storage s = _s();
        bytes32 reservationKey = _getReservationKey(_tokenId, _start);
        
        // Check availability in one condition
        require(!s.reservationKeys.contains(reservationKey) || 
                Status(s.reservations[reservationKey].status) == Status.CANCELLED, 
                "Not available");

        // Insert and create reservation
        s.calendars[_tokenId].insert(_start, _end);
        
        // Direct struct initialization
        s.reservations[reservationKey] = Reservation({
            labId: _tokenId,
            renter: msg.sender,
            price: 0,
            start: _start,
            end: _end,
            status: uint8(Status.PENDING)
        });
        
        // Add to tracking sets
        s.reservationKeys.add(reservationKey);
        s.renters[msg.sender].add(reservationKey);
        
        emit ReservationRequested(msg.sender, _tokenId, _start, _end, reservationKey);
    }

    /// @notice Confirms a pending reservation request for a lab
    /// @dev Changes the status of a reservation from PENDING to BOOKED and associates it with the lab provider
    /// @param _reservationKey The unique identifier of the reservation to confirm
    /// @custom:event ReservationConfirmed Emitted when the reservation is successfully confirmed
    /// @custom:requirements Reservation must be in PENDING status (checked by reservationPending modifier)
    function confimReservationRequest(bytes32 _reservationKey) external reservationPending(_reservationKey) virtual override {
        Reservation storage reservation = _s().reservations[_reservationKey];
      
        address labProvider = IERC721(address(this)).ownerOf(reservation.labId);

        // Book the reservation
        reservation.status = uint8(Status.BOOKED);
        _s().reservationsProvider[labProvider].add(_reservationKey);
        
        emit ReservationConfirmed(_reservationKey);     
          
    }

    /// @notice Cancels an existing booking reservation
    /// @dev Can only be called by the renter or the lab provider
    /// @param _reservationKey The unique identifier of the reservation to cancel
    /// @custom:throws If the reservation is invalid or caller is not authorized
    /// @custom:emits BookingCanceled event with the reservation key
    function cancelBooking(bytes32 _reservationKey) external virtual override {

        Reservation storage reservation = _s().reservations[_reservationKey];
        require (reservation.renter != address(0) && Status(reservation.status) == Status.BOOKED, "Invalid reservation");

        address renter = reservation.renter;
       
        address labProvider = IERC721(address(this)).ownerOf(reservation.labId);
        
        require(renter == msg.sender || labProvider == msg.sender, "Unauthorized");

        // Cancel the booking
         _s().reservationsProvider[labProvider].remove(_reservationKey);
        _cancelReservation(_reservationKey);

       emit BookingCanceled(_reservationKey);
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
        require(_index < s.reservationKeys.length(), "Index out of bounds");
        return s.reservationKeys.at(_index);
    }

    /// @notice Get the number of reservations for a specific user
    /// @dev Retrieves the length of the reservation array for the given user address
    /// @param _user The address of the user to check reservations for
    /// @return The number of active reservations for the user
    /// @custom:throws "Invalid address" if the provided address is zero
    function reservationsOf(address _user) external view returns (uint256) {
        require(_user != address(0), "Invalid address");
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
        require(_index < s.renters[_user].length(), "Index out of bounds");
        return s.renters[_user].at(_index);
    }

    /// @notice Gets the total number of reservations for a specific token
    /// @dev Requires the token to exist (checked by exists modifier)
    /// @param _tokenId The ID of the token to query reservations for
    /// @return The total number of reservations for the specified token
    function getReservationsOfToken(uint256 _tokenId) public view virtual exists(_tokenId) returns (uint) {
        return _size(_s().calendars[_tokenId]);
    }

    /// @notice Retrieves a specific reservation key for a token by its index
    /// @dev Requires the token to exist. The index must be within bounds of existing reservations
    /// @param _tokenId The ID of the token to query
    /// @param _index The index position of the reservation to retrieve
    /// @return bytes32 The reservation key at the specified index
    /// @custom:throws If token doesn't exist or if index is out of bounds
    function getReservationOfTokenByIndex(uint256 _tokenId, uint256 _index) external view exists(_tokenId) returns (bytes32) {
        uint tokenReservations = getReservationsOfToken(_tokenId);
        require(_index < tokenReservations, "Index out of bounds");
        
        AppStorage storage s = _s();
        // Get keys and access reservation
        uint[] memory keys = _getAllKeys(s.calendars[_tokenId]);
        bytes32 reservationKey = _getReservationKey(_tokenId, uint32(keys[_index]));
        return reservationKey;
    }

    /// @notice Checks if a user has an active booking for a specific token
    /// @dev A booking is considered active if it's in BOOKED status and hasn't expired
    /// @param _tokenId The ID of the token to check
    /// @param _user The address of the user to check
    /// @return bool True if the user has an active booking for the token, false otherwise
    function hasActiveBookingByToken(uint256 _tokenId, address _user) external view virtual exists(_tokenId) returns (bool) {
        AppStorage storage s = _s();
        uint32 time = uint32(block.timestamp);
        uint cursor = s.calendars[_tokenId].findParent(time);
        
        // Early return if no reservations found
        if (cursor == 0) return false;
        
        bytes32 reservationKey = _getReservationKey(_tokenId, uint32(cursor));
        if (!s.renters[_user].contains(reservationKey)) return false;
            
        Reservation memory reservation = s.reservations[reservationKey];
        return reservation.status == uint8(Status.BOOKED) && reservation.end >= time;
    }

    /// @dev Cancels an existing reservation by removing it from the renter's list and then
    ///      calling the parent implementation to complete the cancellation process.
    /// @param _reservationKey The unique identifier of the reservation to be canceled
    /// @notice This function removes the reservation from both the renter's list and through
    ///         the parent implementation
    function _cancelReservation(bytes32 _reservationKey) internal override {
        // Remove from renter's list first
        address renter = _s().reservations[_reservationKey].renter;
        _s().renters[renter].remove(_reservationKey);
        
        // Call parent implementation
        super._cancelReservation(_reservationKey);
    }

    /// @notice Gets the total number of elements in a tree data structure
    /// @dev Iterates through the tree from the first element until reaching an empty node
    /// @param _calendar The tree storage structure to count elements from
    /// @return The total number of elements in the tree
    function _size(Tree storage _calendar) internal view returns (uint256) {
        uint count = 0;
        uint cursor = _calendar.first();
        
        while (cursor != EMPTY) {
            count++;
            cursor = _calendar.next(cursor);
        }
        
        return count;
    }

    /// @notice Returns an array containing all keys in the tree in order
    /// @dev Iterates through the tree using first() and next() to collect all keys
    /// @param _calendar The tree storage to get keys from
    /// @return Array containing all keys in the tree in sequential order
    /// @custom:internal This is an internal view function
    function _getAllKeys(Tree storage _calendar) internal view returns (uint[] memory) {
        uint size = _size(_calendar);
        uint[] memory keys = new uint[](size);
        
        if (size > 0) {
            uint cursor = _calendar.first();
            for (uint i = 0; i < size; i++) {
                keys[i] = cursor;
                cursor = _calendar.next(cursor);
            }
        }
        
        return keys;
    }
}