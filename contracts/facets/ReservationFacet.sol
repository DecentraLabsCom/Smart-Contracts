// SPDX-License-Identifier: GPL-3.0-or-later
pragma solidity ^0.8.23;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {IERC721} from "@openzeppelin/contracts/token/ERC721/IERC721.sol";
import "../abstracts/ReservableTokenEnumerable.sol";
import "./ProviderFacet.sol";

/// @dev Interface for StakingFacet to update reservation timestamps
interface IStakingFacet {
    function updateLastReservation(address provider) external;
}

/// @dev Interface for InstitutionalTreasuryFacet to spend from treasury
interface IInstitutionalTreasuryFacet {
    function spendFromInstitutionalTreasury(address provider, string calldata puc, uint256 amount) external;
    function refundToInstitutionalTreasury(address provider, string calldata puc, uint256 amount) external;
}

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
    /// - Lab must be listed for reservations
    /// - Start time must be in the future
    /// - End time must be after start time
    /// - User must have sufficient token balance
    /// - Time slot must be available
    function reservationRequest(uint256 _labId, uint32 _start, uint32 _end) external exists(_labId) override { 
        AppStorage storage s = _s();
        
        // Check if lab is listed for reservations
        if (!s.tokenStatus[_labId]) revert("Lab not listed for reservations");
        
        // Check if lab owner has sufficient stake using ReservableToken's calculation
        address labOwner = IERC721(address(this)).ownerOf(_labId);
        uint256 listedLabsCount = s.providerStakes[labOwner].listedLabsCount;
        uint256 requiredStake = ReservableToken(address(this)).calculateRequiredStake(labOwner, listedLabsCount);
        if (s.providerStakes[labOwner].stakedAmount < requiredStake) {
            revert("Lab provider does not have sufficient stake");
        }
        
        if (_start >= _end || _start <= block.timestamp + RESERVATION_MARGIN) 
            revert("Invalid time range");
      
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
        
        // Gas optimizations: O(1) operations
        s.reservationCountByToken[_labId]++;
        s.reservationKeysByToken[_labId].add(reservationKey);
        
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
        
        // Update provider's last reservation timestamp (activates 30-day lock)
        // Provider is committing to provide service, so lock starts from reservation creation
        IStakingFacet(address(this)).updateLastReservation(labOwner);
        
        emit ReservationRequested(msg.sender, _labId, _start, _end, reservationKey);
    }

    /// @notice Allows an institutional user (via authorized backend) to request a booking using institutional treasury
    /// @dev Creates a new reservation request paid from the provider's institutional treasury
    ///      The backend must be authorized by the institutional provider
    /// @param institutionalProvider The provider who owns the institutional treasury
    /// @param puc The schacPersonalUniqueCode of the institutional user
    /// @param _labId The ID of the lab to reserve
    /// @param _start The start timestamp of the reservation
    /// @param _end The end timestamp of the reservation
    /// @custom:throws Error if time range is invalid, slot not available, or treasury has insufficient funds
    /// @custom:emits ReservationRequested when reservation is created
    /// @custom:requirements 
    /// - Caller must be the authorized backend for the institutional provider
    /// - Lab must exist and be listed for reservations
    /// - Institutional user must have sufficient remaining allowance
    /// - Time slot must be available
    function institutionalReservationRequest(
        address institutionalProvider,
        string calldata puc,
        uint256 _labId,
        uint32 _start,
        uint32 _end
    ) external exists(_labId) { 
        AppStorage storage s = _s();
        
        // Check if lab is listed for reservations
        if (!s.tokenStatus[_labId]) revert("Lab not listed for reservations");
        
        // Check if lab owner has sufficient stake
        address labOwner = IERC721(address(this)).ownerOf(_labId);
        uint256 listedLabsCount = s.providerStakes[labOwner].listedLabsCount;
        uint256 requiredStake = ReservableToken(address(this)).calculateRequiredStake(labOwner, listedLabsCount);
        if (s.providerStakes[labOwner].stakedAmount < requiredStake) {
            revert("Lab provider does not have sufficient stake");
        }
        
        if (_start >= _end || _start <= block.timestamp + RESERVATION_MARGIN) 
            revert("Invalid time range");
      
        uint96 price = s.labs[_labId].price;
        bytes32 reservationKey = _getReservationKey(_labId, _start);
        
        // Check availability
        if (s.reservationKeys.contains(reservationKey) && 
            s.reservations[reservationKey].status != CANCELLED)
            revert("Not available");

        // Spend from institutional treasury (this checks backend authorization and limits)
        IInstitutionalTreasuryFacet(address(this)).spendFromInstitutionalTreasury(
            institutionalProvider, 
            puc, 
            price
        );

        // Insert and create reservation
        s.calendars[_labId].insert(_start, _end);
        s.reservationCountByToken[_labId]++;
        s.reservationKeysByToken[_labId].add(reservationKey);
        
        // Create reservation with renter as the institutional provider (for accounting)
        // The actual user is tracked via the InstitutionalUserSpent event
        s.reservations[reservationKey] = Reservation({
            labId: _labId,
            renter: institutionalProvider, // Provider pays on behalf of institutional user
            price: price,
            start: _start,
            end: _end,
            status: PENDING
        });
        
        s.reservationKeys.add(reservationKey);
        s.renters[institutionalProvider].add(reservationKey);
        
        // Tokens are already in Diamond (from institutional treasury)
        // No transfer needed - just mark as allocated for this reservation
        
        // Update provider's last reservation timestamp
        IStakingFacet(address(this)).updateLastReservation(labOwner);
        
        emit ReservationRequested(institutionalProvider, _labId, _start, _end, reservationKey);
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
        
        emit ReservationConfirmed(_reservationKey, reservation.labId);
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
       
        IERC20(_s().labTokenAddress).transfer(reservation.renter, reservation.price);
        _cancelReservation(_reservationKey);
        emit ReservationRequestDenied(_reservationKey, reservation.labId);
    }

    /// @notice Allows admin to deny an institutional user's pending reservation request
    /// @dev Refunds the tokens back to the institutional treasury (not to provider's wallet)
    /// @param institutionalProvider The provider who owns the institutional treasury
    /// @param puc The schacPersonalUniqueCode of the institutional user
    /// @param _reservationKey The unique identifier of the reservation to deny
    /// @custom:requires The caller must have admin role
    /// @custom:requires The reservation must be in pending state
    /// @custom:emits ReservationRequestDenied when the reservation is denied
    /// @custom:transfers Refunds to institutional treasury and decrements user's spent amount
    function denyInstitutionalReservationRequest(
        address institutionalProvider,
        string calldata puc,
        bytes32 _reservationKey
    ) external defaultAdminRole {
        Reservation storage reservation = _s().reservations[_reservationKey];
        if (reservation.status != PENDING) revert("Not pending");
        if (reservation.renter != institutionalProvider) revert("Not institutional");

        uint256 price = reservation.price;
        
        _cancelReservation(_reservationKey);
        
        // Refund to institutional treasury (not to provider's wallet)
        // This also decrements the user's spent amount
        IInstitutionalTreasuryFacet(address(this)).refundToInstitutionalTreasury(
            institutionalProvider,
            puc,
            price
        );
        
        emit ReservationRequestDenied(_reservationKey, reservation.labId);
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
        emit ReservationRequestCanceled(_reservationKey, reservation.labId);
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
        
        IERC20(_s().labTokenAddress).transfer(renter, price);
        emit BookingCanceled(_reservationKey, reservation.labId);
    }

    /// @notice Allows authorized backend to cancel an institutional user's pending reservation request
    /// @dev Refunds the tokens back to the institutional treasury (not to provider's wallet)
    /// @param institutionalProvider The provider who owns the institutional treasury
    /// @param puc The schacPersonalUniqueCode of the institutional user
    /// @param _reservationKey The unique identifier of the reservation to cancel
    /// @custom:throws "Not found" if the reservation doesn't exist
    /// @custom:throws "Not renter" if institutional provider is not the renter
    /// @custom:throws "Not pending" if reservation status is not PENDING
    /// @custom:throws "Not authorized backend" if caller is not the authorized backend for the provider
    /// @custom:emits ReservationRequestCanceled when successfully cancelled
    function cancelInstitutionalReservationRequest(
        address institutionalProvider,
        string calldata puc,
        bytes32 _reservationKey
    ) external {
        // Verify caller is authorized backend for this provider
        // This check is redundant with refundToInstitutionalTreasury but provides better error messaging
        AppStorage storage s = _s();
        require(s.institutionalBackends[institutionalProvider] != address(0), "No authorized backend");
        require(msg.sender == s.institutionalBackends[institutionalProvider], "Not authorized backend");
        
        Reservation storage reservation = _s().reservations[_reservationKey];
        if (reservation.renter == address(0)) revert("Not found");
        if (reservation.renter != institutionalProvider) revert("Not renter");
        if (reservation.status != PENDING) revert("Not pending");

        uint256 price = reservation.price;
        
        _cancelReservation(_reservationKey);
        
        // Refund to institutional treasury (not to provider's wallet)
        // This also decrements the user's spent amount
        IInstitutionalTreasuryFacet(address(this)).refundToInstitutionalTreasury(
            institutionalProvider,
            puc,
            price
        );
        
        emit ReservationRequestCanceled(_reservationKey, reservation.labId);
    }

    /// @notice Allows authorized backend to cancel an institutional user's confirmed booking
    /// @dev Refunds the tokens back to the institutional treasury (not to provider's wallet)
    /// @param institutionalProvider The provider who owns the institutional treasury
    /// @param puc The schacPersonalUniqueCode of the institutional user
    /// @param _reservationKey The unique identifier of the reservation to cancel
    /// @custom:throws If reservation is invalid or caller is not authorized
    /// @custom:throws "Not authorized backend" if caller is not the authorized backend for the provider
    /// @custom:emits BookingCanceled event
    /// @custom:security Requires the reservation to be in BOOKED status
    function cancelInstitutionalBooking(
        address institutionalProvider,
        string calldata puc,
        bytes32 _reservationKey
    ) external {
        // Verify caller is authorized backend for this provider
        // This check is redundant with refundToInstitutionalTreasury but provides better error messaging
        AppStorage storage s = _s();
        require(s.institutionalBackends[institutionalProvider] != address(0), "No authorized backend");
        require(msg.sender == s.institutionalBackends[institutionalProvider], "Not authorized backend");
        
        Reservation storage reservation = _s().reservations[_reservationKey];
        if (reservation.renter == address(0) || reservation.status != BOOKED) 
            revert("Invalid");

        address renter = reservation.renter;
        uint256 price = reservation.price;
        address labProvider = IERC721(address(this)).ownerOf(reservation.labId);
        
        if (renter != institutionalProvider) revert("Not renter");

        // Cancel the booking
        _s().reservationsProvider[labProvider].remove(_reservationKey);
        _cancelReservation(_reservationKey);
        
        // Refund to institutional treasury (not to provider's wallet)
        // This also decrements the user's spent amount
        IInstitutionalTreasuryFacet(address(this)).refundToInstitutionalTreasury(
            institutionalProvider,
            puc,
            price
        );
        
        emit BookingCanceled(_reservationKey, reservation.labId);
    }

    /// @notice Allows lab providers to claim funds from used or expired reservations in batches
    /// @dev Only lab providers can call this function. It processes reservations that are:
    ///      1. Ended (end < block.timestamp)
    ///      2. In BOOKED status
    /// After processing, the reservation status changes to COLLECTED
    /// @param maxBatch Maximum number of reservations to process in this call (max 100)
    /// @custom:modifier isLabProvider - Restricts access to registered lab providers
    /// @dev Transfers the total amount of tokens from all eligible reservations to the provider
    /// @custom:revert "Invalid batch size" if maxBatch is 0 or > 100
    /// @custom:revert "No funds" if no eligible reservations were found
    /// @custom:revert If the ERC20 transfer fails
    /// @custom:gas Optimized with batching to prevent gas limit issues
    function requestFunds(uint256 maxBatch) external isLabProvider {
        if (maxBatch == 0 || maxBatch > 100) revert("Invalid batch size");
        
        AppStorage storage s = _s();
        uint256 totalAmount;
        uint256 processed;
        EnumerableSet.Bytes32Set storage reservationKeys = s.reservationsProvider[msg.sender];
        uint256 len = reservationKeys.length();

        for (uint256 i; i < len && processed < maxBatch;) {
            bytes32 key = reservationKeys.at(i);
            Reservation storage reservation = s.reservations[key];

            if (reservation.end < block.timestamp && reservation.status == BOOKED) {
                totalAmount += reservation.price;    
                reservation.status = COLLECTED;  
                reservationKeys.remove(key);
                
                // Clean up active reservation index for consistency
                if (s.activeReservationByTokenAndUser[reservation.labId][reservation.renter] == key) {
                    delete s.activeReservationByTokenAndUser[reservation.labId][reservation.renter];
                }
                
                --len; // Adjust length after removal
                unchecked { ++processed; }
            } else {
                unchecked { ++i; }
            }
        }

        if (totalAmount == 0) revert("No funds");
        
        // Update provider's last reservation timestamp (activates 30-day lock)
        // This is done after successfully completing/collecting reservations
        if (processed > 0) {
            IStakingFacet(address(this)).updateLastReservation(msg.sender);
        }
        
        IERC20(s.labTokenAddress).transfer(msg.sender, totalAmount);
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
