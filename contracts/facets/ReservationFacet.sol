// SPDX-License-Identifier: GPL-2.0-or-later
pragma solidity ^0.8.23;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import "../abstracts/ReservableTokenEnumerable.sol";
import "./ProviderFacet.sol";

/// @title ReservationFacet - A contract for managing lab reservations and bookings
/// @author
/// - Juan Luis Ramos Villalón
/// - Luis de la Torre Cubillo
/// @notice This contract is part of a diamond architecture and is responsible for managing lab reservations.
/// @dev Implements ReservableTokenEnumerable and manages lab reservations using interval trees.
///      Throughout the contract, `labId` and `tokenId` are used interchangeably and refer to the same identifier.
///      This convention is followed for compatibility with the ERC721 standard, assuming that each lab is represented by a ERC721 token,
///      and to maintain homogeneity across overridden functions from OpenZeppelin's implementation.
/// @notice This contract provides functionality for:
/// - Managing lab reservations with booking requests and confirmations
/// - Handling payments and refunds with ERC20 tokens
/// - Managing reservation statuses (pending, booked, cancelled, collected)
/// - Access control for lab providers and administrators
contract ReservationFacet is ReservableTokenEnumerable {
    using LibAccessControlEnumerable for AppStorage;
    using RivalIntervalTreeLibrary for Tree;
    using EnumerableSet for EnumerableSet.Bytes32Set;
    
    /// @notice Thrown when a user tries to make a purchase with insufficient funds
    /// @param user Address of the user attempting the purchase 
    /// @param funds Amount of funds the user has available
    /// @param price Required price for the purchase
    error InsuficientsFunds(address user, uint256 funds, uint256 price);

    /// @dev Modifier to restrict access to functions that can only be executed by accounts
    ///      with the `DEFAULT_ADMIN_ROLE`. Ensures that the caller of the function has the
    ///      required role before proceeding with the execution of the function.
    /// @notice Reverts if the caller does not have the `DEFAULT_ADMIN_ROLE`.
    modifier defaultAdminRole() {
        if (!ProviderFacet(address(this)).hasRole(_s().DEFAULT_ADMIN_ROLE, msg.sender)) 
            revert("Only default admin");
        _;
    }

    /// @notice Modifier that restricts function access to only lab providers
    /// @dev Checks if the message sender is registered as a lab provider in the system
    /// @custom:throws "Only LabProvider" if the sender is not a registered lab provider
    modifier isLabProvider() {
        if (!_s()._isLabProvider(msg.sender)) revert("Only LabProvider");
        _;
    }

    /// @notice Allows a user to request a booking for a lab.
    /// @dev Creates a new reservation request if the time slot is available
    /// @param _labId The ID of the lab to reserve
    /// @param _start The start timestamp of the reservation
    /// @param _end The end timestamp of the reservation
    /// @custom:throws InsuficientsFunds if user has insufficient token balance
    /// @custom:throws Error if time range is invalid or slot not available
    /// @custom:emits ReservationRequested when reservation is created
    /// @custom:requirements 
    /// - Lab must exist (checked by exists modifier)
    /// - Start time must be in the future
    /// - End time must be after start time
    /// - User must have sufficient token balance
    /// - Time slot must be available
    function reservationRequest(uint256 _labId, uint32 _start, uint32 _end) external exists(_labId) override { 
        if (_start >= _end || _start <= block.timestamp + RESERVATION_MARGIN) 
            revert("Invalid time range");
      
        AppStorage storage s = _s();
        uint96 price = s.labs[_labId].price;
        address tokenAddr = s.labTokenAddress;

        uint256 balance = IERC20(tokenAddr).balanceOf(msg.sender);
        if (balance < price) revert InsuficientsFunds(msg.sender, balance, price);
        
        bytes32 reservationKey = _getReservationKey(_labId, _start);
        
        // Check availability in one condition
        if (s.reservationKeys.contains(reservationKey) && 
            s.reservations[reservationKey].status != CANCELLED)
            revert("Not available");

        // Insert and create reservation
        s.calendars[_labId].insert(_start, _end);
        
        // Direct struct initialization
        s.reservations[reservationKey] = Reservation({
            labId: _labId,
            renter: msg.sender,
            price: price,
            start: _start,
            end: _end,
            status: PENDING
        });
        
        // Add to tracking sets
        s.reservationKeys.add(reservationKey);
        s.renters[msg.sender].add(reservationKey);

        IERC20(tokenAddr).transferFrom(msg.sender, address(this), price);        
        emit ReservationRequested(msg.sender, _labId, _start, _end, reservationKey);
    }

    /// @notice Confirms a pending reservation request for a lab
    /// @dev Can only be called by an admin when the reservation is in PENDING status
    /// @param _reservationKey The unique identifier of the reservation to confirm
    /// @custom:requires The reservation must exist and be in PENDING status
    /// @custom:requires Caller must have admin role
    /// @custom:emits ReservationConfirmed when reservation is successfully confirmed
    /// @custom:modifies Updates reservation status to BOOKED
    /// @custom:modifies Adds reservation to lab provider's reservation list
    function confirmReservationRequest(bytes32 _reservationKey) external defaultAdminRole reservationPending(_reservationKey) override {
        Reservation storage reservation = _s().reservations[_reservationKey];
        address labProvider = IERC721(address(this)).ownerOf(reservation.labId);

        reservation.status = BOOKED;   
        _s().reservationsProvider[labProvider].add(_reservationKey);
        
        emit ReservationConfirmed(_reservationKey);
    }

    /// @notice Denies a pending reservation request and refunds the payment
    /// @dev Only callable by admin when reservation is in pending state
    /// @param _reservationKey The unique identifier of the reservation to deny
    /// @custom:requires The caller must have admin role
    /// @custom:requires The reservation must be in pending state
    /// @custom:emits ReservationRequestDenied when the reservation is denied
    /// @custom:transfers Refunds the reservation price back to the renter
    function denyReservationRequest(bytes32 _reservationKey) external defaultAdminRole reservationPending(_reservationKey) override {
        Reservation storage reservation = _s().reservations[_reservationKey];
       
        IERC20(_s().labTokenAddress).transferFrom(address(this), reservation.renter, reservation.price);
        _cancelReservation(_reservationKey);
        emit ReservationRequestDenied(_reservationKey);
    }

    /// @notice Allows a user to cancel their pending reservation request
    /// @dev The function transfers back the reserved tokens to the renter
    /// @param _reservationKey The unique identifier of the reservation to cancel
    /// @custom:throws "Not found" if the reservation doesn't exist
    /// @custom:throws "Only the renter" if caller is not the reservation owner
    /// @custom:throws "Not pending" if reservation status is not PENDING
    /// @custom:emits ReservationRequestCanceled when successfully cancelled
    function cancelReservationRequest(bytes32 _reservationKey) external override {
        Reservation storage reservation = _s().reservations[_reservationKey];
        if (reservation.renter == address(0)) revert("Not found");
        if (reservation.renter != msg.sender) revert("Only the renter");
        if (reservation.status != PENDING) revert("Not pending");

        _cancelReservation(_reservationKey);
        IERC20(_s().labTokenAddress).transfer(reservation.renter, reservation.price);
        emit ReservationRequestCanceled(_reservationKey);
    }  

    /// @notice Cancels an existing booking reservation
    /// @dev Can be called by either the renter or the lab provider
    /// @param _reservationKey The unique identifier of the reservation to cancel
    /// @custom:throws If reservation is invalid or caller is not authorized
    /// @custom:emits BookingCanceled event
    /// @custom:security Requires the reservation to be in BOOKED status
    /// @custom:refund Transfers the reservation price back to the renter
    function cancelBooking(bytes32 _reservationKey) external override {
        Reservation storage reservation = _s().reservations[_reservationKey];
        if (reservation.renter == address(0) || reservation.status != BOOKED) 
            revert("Invalid");

        address renter = reservation.renter;
        uint256 price = reservation.price;
        address labProvider = IERC721(address(this)).ownerOf(reservation.labId);
        
        if (renter != msg.sender && labProvider != msg.sender) revert("Unauthorized");

        // Cancel the booking
        _s().reservationsProvider[labProvider].remove(_reservationKey);
        _cancelReservation(_reservationKey);
        
        IERC20(_s().labTokenAddress).transferFrom(address(this), renter, price);
        emit BookingCanceled(_reservationKey);
    }

    /// @notice Retrieves all reservations stored in the contract
    /// @dev Iterates through all reservation keys and returns an array of Reservation structs
    /// @return An array containing all Reservation structs in storage
    function getAllReservations() external view returns (Reservation[] memory) {
        AppStorage storage s = _s();
        uint256 len = s.reservationKeys.length();
        Reservation[] memory allReservations = new Reservation[](len);
        
        for (uint256 i; i < len;) {
            allReservations[i] = s.reservations[s.reservationKeys.at(i)];
            unchecked { ++i; }
        }
        return allReservations;
    }

    /// @notice Allows lab providers to claim funds from used or expired reservations
    /// @dev Only lab providers can call this function. It processes reservations that are:
    ///      1. Not yet started (future reservations)
    ///      2. In BOOKED status
    /// After processing, the reservation status changes to COLLECTED
    /// @custom:modifier isLabProvider - Restricts access to registered lab providers
    /// @dev Transfers the total amount of tokens from all eligible reservations to the provider
    /// @custom:revert If there are no eligible reservations to collect funds from
    /// @custom:revert If the ERC20 transfer fails
    function requestFunds() external isLabProvider {
        uint256 totalAmount;
        EnumerableSet.Bytes32Set storage reservationKeys = _s().reservationsProvider[msg.sender];
        uint256 len = reservationKeys.length();

        for (uint256 i; i < len;) {
            bytes32 key = reservationKeys.at(i);
            Reservation storage reservation = _s().reservations[key];

            if (reservation.end < block.timestamp && reservation.status == BOOKED) {
                totalAmount += reservation.price;    
                reservation.status = COLLECTED;  
                reservationKeys.remove(key);
                --len; // Adjust length after removal
            } else {
                unchecked { ++i; }
            }
        }

        if (totalAmount == 0) revert("No funds");
        IERC20(_s().labTokenAddress).transferFrom(address(this), msg.sender, totalAmount);
    }

    /// @notice Returns the address of the $LAB ERC20 token contract
    /// @dev Gets the $LAB token address from the storage
    /// @return address The $LAB token contract address
    function getLabTokenAddress() external view returns (address) {
        return _s().labTokenAddress;
    }

    /// @notice Returns the current balance of Lab tokens held by this contract
    /// @dev Uses IERC20 interface to check the balance of the contract's own address
    /// @return uint256 The amount of Lab tokens held by the contract
    function getSafeBalance() external view returns (uint256) { 
        return IERC20(_s().labTokenAddress).balanceOf(address(this));
    }
}
