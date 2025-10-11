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
    /// @param _tokenId The unique identifier of the token to be listed.
    function listToken(uint256 _tokenId) external onlyTokenOwner(_tokenId) {
        _s().tokenStatus[_tokenId] = true;
        emit LabListed(_tokenId, msg.sender);
    }

    /// @notice Unlists a token, marking it as unavailable for reservation or other operations.
    /// @dev This function updates the token's status to `false` in the storage mapping.
    /// @param _tokenId The unique identifier of the token to be unlisted.
    /// @dev Caller must be the owner of the token.
    function unlistToken(uint256 _tokenId) external onlyTokenOwner(_tokenId) {
        _s().tokenStatus[_tokenId] = false;
        emit LabUnlisted(_tokenId, msg.sender);
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
    /// @dev TODO: Implementation needed to verify caller is token owner or authorized user
    /// @dev Emits a `ReservationConfirmed` event upon successful confirmation
    function confirmReservationRequest(bytes32 _reservationKey) external virtual reservationPending(_reservationKey) {
        Reservation storage reservation = _s().reservations[_reservationKey];
        reservation.status = BOOKED;           
        emit ReservationConfirmed(_reservationKey, reservation.labId);          
    }

    /// @notice Denies a reservation request associated with the given reservation key.
    /// @dev Cancels the reservation and emits a `ReservationRequestDenied` event.
    /// @param _reservationKey The unique key identifying the reservation request to be denied.
    /// @dev TODO: Implementation needed to verify caller is token owner or authorized user
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

    /// @dev Internal pure function to retrieve the application storage structure.
    ///      This function provides access to the `AppStorage` instance by calling
    ///      the `diamondStorage` function from the `LibAppStorage` library.
    ///      Assuming EIP-2535 compliant contract 
    /// @return s The storage instance of type `AppStorage`.
    function _s() internal pure returns (AppStorage storage s) {
        return LibAppStorage.diamondStorage();
    }
}