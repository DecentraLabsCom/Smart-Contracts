// SPDX-License-Identifier: GPL-2.0-or-later
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

    /// @notice Emitted when a reservation is requested for a token.
    /// @param renter The address of the user requesting the reservation.
    /// @param tokenId The ID of the token being reserved.
    /// @param start The start timestamp of the reservation period.
    /// @param end The end timestamp of the reservation period.
    /// @param reservationKey A unique key identifying the reservation.
    event ReservationRequested(address renter, uint256 tokenId, uint256 start, uint256 end, bytes32 reservationKey);
    
    /// @notice Emitted when a reservation is successfully confirmed.
    /// @param reservationKey The unique identifier for the confirmed reservation.
    event ReservationConfirmed(bytes32 reservationKey);

    /// @notice Emitted when a reservation request is denied.
    /// @param reservationKey The unique key identifying the reservation that was denied.
    event ReservationRequestDenied(bytes32 reservationKey);
    
    /// @notice Emitted when a reservation request is canceled.
    /// @param reservationKey The unique identifier of the reservation that was canceled.
    event ReservationRequestCanceled(bytes32 reservationKey);
    
    /// @notice Emitted when a booking associated with a specific reservation key is canceled.
    /// @param reservationKey The unique identifier for the reservation that was canceled.
    event BookingCanceled(bytes32 reservationKey);

    /// @notice Represents the various statuses a reservable token can have.
    /// @dev The statuses include:
    /// - PENDING: The reservation is pending and not yet confirmed.
    /// - BOOKED: The reservation has been confirmed and then booked.
    /// - USED: The reservation has been utilized.
    /// - COLLECTED: The amoint paid for the reservation has been collected or redeemed.
    /// - CANCELLED: The reservation has been cancelled.
    enum Status { PENDING, BOOKED, USED, COLLECTED, CANCELLED}
    
    /// @notice Fixed margin time applied to the token reservation process
    /// @dev A constant value of 0 indicating no margin is applied during reservation
    uint32 constant RESERVATION_MARGIN = 0; 


    /// @dev Modifier to check if a token with the given ID exists.
    /// @param _tokenId The ID of the token to check.
    /// @notice Reverts if the token does not exist (i.e., its owner is the zero address).
    modifier exists(uint256 _tokenId) {
        require(IERC721(address(this)).ownerOf(_tokenId) != address(0), "Token doesn't exist");
        _;
    }
    
    /// @dev Modifier to check if the caller is the owner of a specific token.
    /// @param _tokenId The ID of the token to check.
    /// @notice Reverts if the caller is not the owner of the token.
    modifier onlyTokenOwner(uint256 _tokenId) {
        require(IERC721(address(this)).ownerOf(_tokenId) == msg.sender, "Only token owner");
        _;
    }

    /// @dev Modifier to ensure that a reservation exists and is in a pending state.
    /// @param _reservationKey The unique key identifying the reservation.
    /// @notice Reverts if the reservation does not exist or if its status is not pending.
    modifier reservationPending(bytes32 _reservationKey) {
        Reservation storage reservation = _s().reservations[_reservationKey];
        require(reservation.renter != address(0), "Reservation not found");
        require(reservation.status == uint8(Status.PENDING), "Reservation not pending");
        _;
    }

    /// @notice Marks a token as listed by updating its status so it's possible to reserve.
    /// @dev This function can only be called by the owner of the token.
    /// @param _tokenId The unique identifier of the token to be listed.
    function listToken(uint256 _tokenId) external onlyTokenOwner(_tokenId) {
        _s().tokenStatus[_tokenId] = true;
    }

    /// @notice Unlists a token, marking it as unavailable for reservation or other operations.
    /// @dev This function updates the token's status to `false` in the storage mapping.
    /// @param _tokenId The unique identifier of the token to be unlisted.
    /// @dev Caller must be the owner of the token.
    function unlistToken(uint256 _tokenId) external onlyTokenOwner(_tokenId) {
        _s().tokenStatus[_tokenId] = false;
    }

    /// @notice Checks if a token with the given ID is listed.
    /// @param _tokenId The ID of the token to check.
    /// @return A boolean value indicating whether the token is listed.
    /// @dev The function requires the token to exist, enforced by the `exists` modifier.
    function isTokenListed(uint256 _tokenId) external view exists(_tokenId) returns (bool) {
        return _s().tokenStatus[_tokenId];
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
   
        require(_start < _end && _start > block.timestamp + RESERVATION_MARGIN, "Invalid time range");

        bytes32 reservationKey = _getReservationKey(_tokenId, _start);
  
        bool keyExists = s.reservations[reservationKey].renter != address(0);
        bool isCancelled = keyExists && Status(s.reservations[reservationKey].status) == Status.CANCELLED;
        require(!keyExists || isCancelled, "Not available");

        s.calendars[_tokenId].insert(_start, _end);
        
        // Create reservation with direct struct initialization
        s.reservations[reservationKey] = Reservation({
            labId: _tokenId,
            renter: msg.sender,
            price: 0,
            start: _start,
            end: _end,
            status: uint8(Status.PENDING)
        });
        
        emit ReservationRequested(msg.sender, _tokenId, _start, _end, reservationKey);
    }

   
    /// @notice Confirms a reservation request for the given reservation key
    /// @dev Changes the status of the reservation from pending to booked
    /// @param _reservationKey The unique key identifying the reservation to be confirmed
    /// @dev The reservation must be in a pending state, enforced by the `reservationPending` modifier
    /// @dev TODO: Implementation needed to verify caller is token owner or authorized user
    /// @dev Emits a `ReservationConfirmed` event upon successful confirmation
    function confimReservationRequest(bytes32 _reservationKey) external virtual reservationPending(_reservationKey)  {
    // Book the reservation
        _s().reservations[_reservationKey].status = uint8(Status.BOOKED);           
        emit ReservationConfirmed(_reservationKey);          
     }

    /// @notice Denies a reservation request associated with the given reservation key.
    /// @dev Cancels the reservation and emits a `ReservationRequestDenied` event.
    /// @param _reservationKey The unique key identifying the reservation request to be denied.
    /// @dev TODO: Implementation needed to verify caller is token owner or authorized user
    /// @dev The reservation must be in a pending state, enforced by the `reservationPending` modifier.
    function denyReservationRequest(bytes32 _reservationKey) external virtual reservationPending(_reservationKey){    
        _cancelReservation(_reservationKey);
        emit ReservationRequestDenied(_reservationKey);
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
        require (reservation.renter != address(0), "Not found");
        require(reservation.renter == msg.sender, "Only the renter");
        require(Status(reservation.status) == Status.PENDING, "Not pending");

        _cancelReservation(_reservationKey);
    
        emit ReservationRequestCanceled(_reservationKey);
     }  

    /// @notice Cancels a booking associated with the given reservation key.
    /// @dev This function allows either the renter or the lab provider to cancel a booking.
    ///      The reservation must exist and its status must be `BOOKED`.
    /// @param _reservationKey The unique key identifying the reservation to be canceled.
    /// @dev The reservation must exist and its status must be `BOOKED`.
    /// @dev The caller must be either the renter or the lab provider.
    /// @dev BookingCanceled Emitted when a booking is successfully canceled.
    function cancelBooking(bytes32 _reservationKey) external virtual  {

        Reservation storage reservation = _s().reservations[_reservationKey];
        require (reservation.renter != address(0) && Status(reservation.status) == Status.BOOKED, "Invalid");

        address renter = reservation.renter;

        address labProvider = IERC721(address(this)).ownerOf(reservation.labId);  //Assuming EIP-2535 compliant contract 
        
        require(renter == msg.sender || labProvider == msg.sender, "Unauthorized");

        // Cancel the booking
        _cancelReservation(_reservationKey);

       emit BookingCanceled(_reservationKey);
     }


    /// @notice Retrieves the address of the renter associated with a specific reservation key.
    /// @param _reservationKey The unique identifier for the reservation.
    /// @return The address of the renter linked to the reservation.
    /// @dev Reverts with "Not found" if no renter is associated with the given reservation key.
    function userOfReservation(bytes32 _reservationKey) external view returns (address) {
        address renter = _s().reservations[_reservationKey].renter;
        require(renter != address(0), "Not found");
        return renter;
    }

    /// @notice Retrieves the details of a reservation using a reservation key.
    /// @param _reservationKey The unique identifier for the reservation.
    /// @return A `Reservation` struct containing the details of the reservation.
    /// @dev Reverts with "Not found" if the reservation does not exist (i.e., the renter address is zero).
    function getReservation(bytes32 _reservationKey) external view returns (Reservation memory) {
        Reservation memory reservation = _s().reservations[_reservationKey];
        require(reservation.renter != address(0), "Not found");
        return reservation;
    }

    /// @notice Checks if a user has an active booking for a given reservation key.
    /// @param _reservationKey The unique identifier for the reservation.
    /// @param _user The address of the user to check for an active booking.
    /// @return bool Returns true if the user has an active booking, otherwise false.
    function hasActiveBooking(bytes32 _reservationKey, address _user) external view virtual returns (bool) {
        Reservation memory reservation = _s().reservations[_reservationKey];
        uint32 time = uint32(block.timestamp);
        
        return (reservation.renter == _user && 
                reservation.status == uint8(Status.BOOKED) && 
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
        if (_start >= _end || _start <= block.timestamp) {
            return false;
        }     
        return _s().calendars[_tokenId].overlaps(_start, _end);
    }

    /// @dev Cancels a reservation identified by the given reservation key.
    ///      Updates the reservation status to CANCELLED and removes the reservation
    ///      from the associated lab's calendar.
    /// @param _reservationKey The unique key identifying the reservation to be cancelled.
    function _cancelReservation(bytes32 _reservationKey) internal virtual {
        Reservation storage reservation = _s().reservations[_reservationKey];
        reservation.status = uint8(Status.CANCELLED);
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

    /// @dev Internal pure function to retrieve the application storage structure.
    ///      This function provides access to the `AppStorage` instance by calling
    ///      the `diamondStorage` function from the `LibAppStorage` library.
    ///      Assuming EIP-2535 compliant contract 
    /// @return s The storage instance of type `AppStorage`.
    function _s() internal pure returns (AppStorage storage s) {
        return LibAppStorage.diamondStorage();
    }
}