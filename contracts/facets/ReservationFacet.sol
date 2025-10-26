// SPDX-License-Identifier: GPL-3.0-or-later
pragma solidity ^0.8.23;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {IERC721} from "@openzeppelin/contracts/token/ERC721/IERC721.sol";
import {IERC721Enumerable} from "@openzeppelin/contracts/token/ERC721/extensions/IERC721Enumerable.sol";
import {ReentrancyGuard} from "@openzeppelin/contracts/security/ReentrancyGuard.sol";
import "../abstracts/ReservableTokenEnumerable.sol";
import "./ProviderFacet.sol";

using SafeERC20 for IERC20;

/// @dev Interface for StakingFacet to update reservation timestamps
interface IStakingFacet {
    function updateLastReservation(address provider) external;
}

/// @dev Interface for InstitutionalTreasuryFacet to spend from treasury
interface IInstitutionalTreasuryFacet {
    function checkInstitutionalTreasuryAvailability(address provider, string calldata puc, uint256 amount) external view;
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
contract ReservationFacet is ReservableTokenEnumerable, ReentrancyGuard {
    using LibAccessControlEnumerable for AppStorage;
    using RivalIntervalTreeLibrary for Tree;
    using EnumerableSet for EnumerableSet.Bytes32Set;
    
    /// @notice Thrown when a user tries to make a purchase with insufficient funds
    /// @param user Address of the user attempting the purchase 
    /// @param funds Amount of funds the user has available
    /// @param price Required price for the purchase
    error InsuficientsFunds(address user, uint256 funds, uint256 price);

    /// @notice Emitted when a provider successfully collects funds from completed reservations
    /// @param provider The address of the lab provider
    /// @param amount Total amount of tokens collected
    /// @param reservationsProcessed Number of reservations that were processed
    event FundsCollected(address indexed provider, uint256 amount, uint256 reservationsProcessed);

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
        
        // Check user hasn't exceeded reservation limit (including PENDING)
        if (s.activeReservationCountByTokenAndUser[_labId][msg.sender] >= MAX_RESERVATIONS_PER_LAB_USER) {
            revert MaxReservationsReached();
        }
        
        if (_start >= _end || _start <= block.timestamp + RESERVATION_MARGIN) 
            revert("Invalid time range");
      
        uint96 price = s.labs[_labId].price;
        address tokenAddr = s.labTokenAddress;

        // Verify user has sufficient balance and allowance (but don't transfer yet)
        uint256 balance = IERC20(tokenAddr).balanceOf(msg.sender);
        if (balance < price) revert InsuficientsFunds(msg.sender, balance, price);
        
        uint256 allowance = IERC20(tokenAddr).allowance(msg.sender, address(this));
        if (allowance < price) revert("Insufficient allowance");
        
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
        
        // Direct struct initialization - includes labProvider for safety
        s.reservations[reservationKey] = Reservation({
            labId: _labId,
            renter: msg.sender,
            labProvider: labOwner,
            price: price,
            start: _start,
            end: _end,
            status: PENDING,
            puc: "" // Empty for wallet reservations
        });
        
        // Add to tracking sets
        s.reservationKeys.add(reservationKey);
        s.renters[msg.sender].add(reservationKey);
        
        // Increment active reservation count (includes PENDING to prevent DoS)
        s.activeReservationCountByTokenAndUser[_labId][msg.sender]++;
        
        // Add to per-token-user index
        s.reservationKeysByTokenAndUser[_labId][msg.sender].add(reservationKey);

        // Payment will be collected when reservation is confirmed (lazy payment)
        
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
        
        require(s.institutionalBackends[institutionalProvider] != address(0), "No authorized backend");
        require(msg.sender == s.institutionalBackends[institutionalProvider], "Caller must be authorized backend");
        
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
        
        // Generate tracking key for institutional user (same as used in confirmation)
        address userTrackingKey = address(uint160(uint256(keccak256(abi.encodePacked(institutionalProvider, puc)))));
        
        // Check user hasn't exceeded reservation limit (including PENDING)
        if (s.activeReservationCountByTokenAndUser[_labId][userTrackingKey] >= MAX_RESERVATIONS_PER_LAB_USER) {
            revert MaxReservationsReached();
        }
        
        // Check availability
        if (s.reservationKeys.contains(reservationKey) && 
            s.reservations[reservationKey].status != CANCELLED)
            revert("Not available");

        // Verify institutional treasury has sufficient balance and user hasn't exceeded limit
        // (but don't spend yet - payment will be collected when reservation is confirmed)
        IInstitutionalTreasuryFacet(address(this)).checkInstitutionalTreasuryAvailability(
            institutionalProvider, 
            puc, 
            price
        );

        // Insert and create reservation
        s.calendars[_labId].insert(_start, _end);
        s.reservationCountByToken[_labId]++;
        s.reservationKeysByToken[_labId].add(reservationKey);
        
        // Create reservation with renter as the institutional provider (for accounting)
        // The actual user is tracked via puc field and InstitutionalUserSpent event
        // labProvider is saved for safety (in case lab is deleted/transferred)
        s.reservations[reservationKey] = Reservation({
            labId: _labId,
            renter: institutionalProvider, // Provider pays on behalf of institutional user
            labProvider: labOwner,
            price: price,
            start: _start,
            end: _end,
            status: PENDING,
            puc: puc // Store PUC to identify institutional reservations
        });
        
        s.reservationKeys.add(reservationKey);
        s.renters[institutionalProvider].add(reservationKey);
        
        // Increment active reservation count (includes PENDING to prevent DoS)
        s.activeReservationCountByTokenAndUser[_labId][userTrackingKey]++;
        
        // Add to per-token-user index
        s.reservationKeysByTokenAndUser[_labId][userTrackingKey].add(reservationKey);
        
        emit ReservationRequested(institutionalProvider, _labId, _start, _end, reservationKey);
    }

    /// @notice Confirms a pending reservation request for a lab
    /// @dev Can only be called by an admin when the reservation is in PENDING status
    ///      Uses lazy payment pattern: attempts to collect payment at confirmation time
    ///      If payment fails (insufficient funds/allowance), automatically denies the request
    /// @param _reservationKey The unique identifier of the reservation to confirm
    /// @custom:requires The reservation must exist and be in PENDING status
    /// @custom:requires Caller must have admin role
    /// @custom:emits ReservationConfirmed when reservation is successfully confirmed and paid
    /// @custom:emits ReservationRequestDenied when payment fails (insufficient funds)
    /// @custom:modifies Updates reservation status to BOOKED or cancels if payment fails
    /// @custom:modifies Adds reservation to lab provider's reservation list (on success)
    function confirmReservationRequest(bytes32 _reservationKey) external defaultAdminRole reservationPending(_reservationKey) override {
        AppStorage storage s = _s();
        Reservation storage reservation = s.reservations[_reservationKey];
        // NOTE: Max reservation check was already done in reservationRequest()
        // Counter was incremented there, so no need to check or increment again
        
        // Get CURRENT owner at confirmation time, not the stale value from request
        // This ensures the correct provider's stake is locked if NFT was transferred after request
        address labProvider = IERC721(address(this)).ownerOf(reservation.labId);
        
        // Update stored labProvider in case of NFT transfer between request and confirmation
        reservation.labProvider = labProvider;

        // Attempt to collect payment from user using SafeERC20
        // safeTransferFrom will revert if transfer fails or returns false
        try IERC20(s.labTokenAddress).safeTransferFrom(
            reservation.renter,
            address(this),
            reservation.price
        ) {
            // Payment successful → confirm reservation
            reservation.status = BOOKED;
            s.reservationsProvider[labProvider].add(_reservationKey);
            s.reservationsByLabId[reservation.labId].add(_reservationKey);
            
            // Update lastReservation timestamp ONLY on confirmation (after payment)
            // This prevents spam attacks where unpaid requests lock provider's stake
            IStakingFacet(address(this)).updateLastReservation(labProvider);
            
            // Update index: only store the earliest reservation
            bytes32 currentIndexKey = s.activeReservationByTokenAndUser[reservation.labId][reservation.renter];
            
            if (currentIndexKey == bytes32(0)) {
                // First reservation for this (token, user)
                s.activeReservationByTokenAndUser[reservation.labId][reservation.renter] = _reservationKey;
            } else {
                // Update index if new reservation starts earlier
                Reservation memory currentReservation = s.reservations[currentIndexKey];
                if (reservation.start < currentReservation.start) {
                    s.activeReservationByTokenAndUser[reservation.labId][reservation.renter] = _reservationKey;
                }
            }
            
            emit ReservationConfirmed(_reservationKey, reservation.labId);
        } catch {
            // transferFrom reverted (insufficient funds/allowance/failed transfer) → deny reservation
            _cancelReservation(_reservationKey);
            emit ReservationRequestDenied(_reservationKey, reservation.labId);
        }
    }

    /// @notice Confirms a pending institutional reservation request
    /// @dev Can only be called by an admin when the reservation is in PENDING status
    ///      Uses lazy payment pattern: attempts to charge the institutional treasury at confirmation time
    ///      If treasury charge fails (insufficient balance or user limit exceeded), automatically denies
    /// @param institutionalProvider The provider who owns the institutional treasury
    /// @param _reservationKey The unique identifier of the reservation to confirm
    /// @custom:requires The reservation must exist and be in PENDING status
    /// @custom:requires Caller must have admin role
    /// @custom:emits ReservationConfirmed when reservation is successfully confirmed and treasury charged
    /// @custom:emits ReservationRequestDenied when treasury charge fails
    function confirmInstitutionalReservationRequest(
        address institutionalProvider,
        bytes32 _reservationKey
    ) external defaultAdminRole reservationPending(_reservationKey) {
        AppStorage storage s = _s();
        Reservation storage reservation = s.reservations[_reservationKey];
        if (reservation.renter != institutionalProvider) revert("Not institutional");
        
        // Validate this is an institutional reservation
        if (bytes(reservation.puc).length == 0) revert("Not institutional reservation");
        
        // Generate unique address for (provider, puc) pair to track individual user limits
        // Use stored PUC to ensure consistency
        address userTrackingKey = address(uint160(uint256(keccak256(abi.encodePacked(institutionalProvider, reservation.puc)))));
        
        
        // Get CURRENT owner at confirmation time, not the stale value from request
        // This ensures the correct provider's stake is locked if NFT was transferred after request
        address labProvider = IERC721(address(this)).ownerOf(reservation.labId);
        
        // Update stored labProvider in case of NFT transfer between request and confirmation
        reservation.labProvider = labProvider;

        // Attempt to charge institutional treasury (use stored puc for consistency)
        try IInstitutionalTreasuryFacet(address(this)).spendFromInstitutionalTreasury(
            institutionalProvider,
            reservation.puc,
            reservation.price
        ) {
            // Treasury charge successful → confirm reservation
            reservation.status = BOOKED;   
            s.reservationsProvider[labProvider].add(_reservationKey);
            s.reservationsByLabId[reservation.labId].add(_reservationKey);
            
            // Update lastReservation timestamp ONLY on confirmation (after payment)
            // This prevents spam attacks where unpaid requests lock provider's stake
            IStakingFacet(address(this)).updateLastReservation(labProvider);
            
            // Update index: only store the earliest reservation (use userTrackingKey for institutional users)
            bytes32 currentIndexKey = s.activeReservationByTokenAndUser[reservation.labId][userTrackingKey];
            
            if (currentIndexKey == bytes32(0)) {
                // First reservation for this (token, user)
                s.activeReservationByTokenAndUser[reservation.labId][userTrackingKey] = _reservationKey;
            } else {
                // Update index if new reservation starts earlier
                Reservation memory currentReservation = s.reservations[currentIndexKey];
                if (reservation.start < currentReservation.start) {
                    s.activeReservationByTokenAndUser[reservation.labId][userTrackingKey] = _reservationKey;
                }
            }
            
            emit ReservationConfirmed(_reservationKey, reservation.labId);
        } catch {
            // Treasury charge failed (insufficient funds or limit exceeded) → deny reservation
            _cancelReservation(_reservationKey);
            emit ReservationRequestDenied(_reservationKey, reservation.labId);
        }
    }

    /// @notice Denies a pending reservation request
    /// @dev Only callable by admin when reservation is in pending state
    ///      With lazy payment pattern, no refund needed since payment wasn't collected yet
    /// @param _reservationKey The unique identifier of the reservation to deny
    /// @custom:requires The caller must have admin role
    /// @custom:requires The reservation must be in pending state
    /// @custom:emits ReservationRequestDenied when the reservation is denied
    function denyReservationRequest(bytes32 _reservationKey) external defaultAdminRole reservationPending(_reservationKey) override {
        Reservation storage reservation = _s().reservations[_reservationKey];
       
        // No refund needed - payment was never collected (lazy payment pattern)
        _cancelReservation(_reservationKey);
        emit ReservationRequestDenied(_reservationKey, reservation.labId);
    }

    /// @notice Allows admin to deny an institutional user's pending reservation request
    /// @dev With lazy payment pattern, no refund needed since treasury wasn't charged yet
    /// @param institutionalProvider The provider who owns the institutional treasury
    /// @param puc The schacPersonalUniqueCode of the institutional user
    /// @param _reservationKey The unique identifier of the reservation to deny
    /// @custom:requires The caller must have admin role
    /// @custom:requires The reservation must be in pending state
    /// @custom:emits ReservationRequestDenied when the reservation is denied
    function denyInstitutionalReservationRequest(
        address institutionalProvider,
        string calldata puc,
        bytes32 _reservationKey
    ) external defaultAdminRole {
        Reservation storage reservation = _s().reservations[_reservationKey];
        if (reservation.status != PENDING) revert("Not pending");
        if (reservation.renter != institutionalProvider) revert("Not institutional");
        
        _cancelReservation(_reservationKey);
        
        // No refund needed - treasury was never charged (lazy payment pattern)
        // The spending was only verified, not executed
        
        emit ReservationRequestDenied(_reservationKey, reservation.labId);
    }

    /// @notice Allows a user to cancel their pending reservation request
    /// @dev With lazy payment pattern, no refund needed since payment wasn't collected yet
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
        // No refund needed - payment was never collected (lazy payment pattern)
        emit ReservationRequestCanceled(_reservationKey, reservation.labId);
    }  

    /// @notice Cancels an existing booking reservation
    /// @dev Can be called by either the renter or the lab provider
    /// @param _reservationKey The unique identifier of the reservation to cancel
    /// @custom:throws If reservation is invalid or caller is not authorized
    /// @custom:emits BookingCanceled event
    /// @custom:security Requires the reservation to be in BOOKED status
    /// @custom:refund Transfers the reservation price back to the renter
    function cancelBooking(bytes32 _reservationKey) external override nonReentrant {
        AppStorage storage s = _s();
        Reservation storage reservation = s.reservations[_reservationKey];
        if (reservation.renter == address(0) || reservation.status != BOOKED) 
            revert("Invalid");

        address renter = reservation.renter;
        uint256 price = reservation.price;
        uint256 labId = reservation.labId;
        address cachedLabProvider = reservation.labProvider;
        string memory puc = reservation.puc;
        bool isInstitutional = bytes(puc).length > 0;
        
        // Check current owner to allow new owners to manage reservations after transfer
        address currentOwner = IERC721(address(this)).ownerOf(labId);
        if (renter != msg.sender && currentOwner != msg.sender) revert("Unauthorized");

        // Cancel the booking - use cached provider for storage cleanup
        s.reservationsProvider[cachedLabProvider].remove(_reservationKey);
        s.reservationsByLabId[labId].remove(_reservationKey);
        _cancelReservation(_reservationKey);
        
        // Refund based on reservation type
        if (isInstitutional) {
            // Refund to institutional treasury, not to provider's wallet
            IInstitutionalTreasuryFacet(address(this)).refundToInstitutionalTreasury(
                renter, // institutional provider
                puc,
                price
            );
        } else {
            // Refund to wallet
            IERC20(s.labTokenAddress).safeTransfer(renter, price);
        }
        
        emit BookingCanceled(_reservationKey, labId);
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

        _cancelReservation(_reservationKey);
        
        emit ReservationRequestCanceled(_reservationKey, reservation.labId);
    }

    /// @notice Allows authorized backend to cancel an institutional user's confirmed booking
    /// @dev Refunds the tokens back to the institutional treasury (not to provider's wallet)
    /// @param institutionalProvider The provider who owns the institutional treasury
    /// @param _reservationKey The unique identifier of the reservation to cancel
    /// @custom:throws If reservation is invalid or caller is not authorized
    /// @custom:throws "Not authorized backend" if caller is not the authorized backend for the provider
    /// @custom:emits BookingCanceled event
    /// @custom:security Requires the reservation to be in BOOKED status
    function cancelInstitutionalBooking(
        address institutionalProvider,
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
        address labProvider = reservation.labProvider;
        string memory storedPuc = reservation.puc; // Use stored PUC, not caller-supplied
        
        if (renter != institutionalProvider) revert("Not renter");

        // Cancel the booking
        s.reservationsProvider[labProvider].remove(_reservationKey);
        s.reservationsByLabId[reservation.labId].remove(_reservationKey);
        _cancelReservation(_reservationKey);
        
        // Refund to institutional treasury using STORED puc (prevents misattribution)
        // This also decrements the user's spent amount
        IInstitutionalTreasuryFacet(address(this)).refundToInstitutionalTreasury(
            institutionalProvider,
            storedPuc,
            price
        );
        
        emit BookingCanceled(_reservationKey, reservation.labId);
    }

    /// @notice Allows lab providers to claim funds from used or expired reservations in batches
    /// @dev Only lab providers can call this function. It processes reservations that are:
    ///      1. Ended (end < block.timestamp)
    ///      2. In BOOKED status
    ///      3. Lab still belongs to the caller (handles NFT transfers)
    /// After processing, the reservation status changes to COLLECTED
    /// @param maxBatch Maximum number of reservations to process in this call (max 100)
    /// @custom:modifier isLabProvider - Restricts access to registered lab providers
    /// @dev Transfers the total amount of tokens from all eligible reservations to the provider
    /// @custom:revert "Invalid batch size" if maxBatch is 0 or > 100
    /// @custom:revert "No funds" if no eligible reservations were found
    /// @custom:revert If the ERC20 transfer fails
    /// @custom:gas Optimized with batching to prevent gas limit issues
    /// @custom:security Uses dynamic ownership check to prevent old owners from claiming funds
    function requestFunds(uint256 maxBatch) external isLabProvider nonReentrant {
        if (maxBatch == 0 || maxBatch > 100) revert("Invalid batch size");
        
        AppStorage storage s = _s();
        uint256 totalAmount;
        uint256 processed;
        
        uint256 ownedLabsCount = IERC721Enumerable(address(this)).balanceOf(msg.sender);
        
        for (uint256 labIdx = 0; labIdx < ownedLabsCount && processed < maxBatch; labIdx++) {
            uint256 labId = IERC721Enumerable(address(this)).tokenOfOwnerByIndex(msg.sender, labIdx);
            
            // Access reservations by labId
            EnumerableSet.Bytes32Set storage reservationKeys = s.reservationsByLabId[labId];
            uint256 len = reservationKeys.length();
            
            // Scan only this lab's BOOKED reservations
            for (uint256 i = 0; i < len && processed < maxBatch; i++) {
                bytes32 key = reservationKeys.at(i);
                Reservation storage reservation = s.reservations[key];
                
                // Only collect completed reservations
                if (reservation.end < block.timestamp && reservation.status == BOOKED) {
                    totalAmount += reservation.price;    
                    reservation.status = COLLECTED;  
                    
                    // Remove from BOTH indices
                    reservationKeys.remove(key);
                    s.reservationsProvider[reservation.labProvider].remove(key);
                    
                    // Use correct tracking key (institutional vs wallet)
                    address trackingKey;
                    if (bytes(reservation.puc).length > 0) {
                        // Institutional reservation
                        trackingKey = address(uint160(uint256(keccak256(abi.encodePacked(reservation.renter, reservation.puc)))));
                    } else {
                        // Wallet reservation
                        trackingKey = reservation.renter;
                    }
                    
                    // Decrement counter and remove from per-token-user index
                    s.activeReservationCountByTokenAndUser[reservation.labId][trackingKey]--;
                    s.reservationKeysByTokenAndUser[reservation.labId][trackingKey].remove(key);
                    
                    // Update active reservation index if this was the indexed one
                    if (s.activeReservationByTokenAndUser[reservation.labId][trackingKey] == key) {
                        bytes32 nextKey = _findNextEarliestReservation(reservation.labId, trackingKey);
                        s.activeReservationByTokenAndUser[reservation.labId][trackingKey] = nextKey;
                    }
                    
                    --len; // Adjust length after removal
                    if (i > 0) --i; // Re-check same index (safe: no underflow at i=0)
                    // Note: When i==0, no decrement needed. The removed element at index 0 causes
                    // the element at index 1 to shift down to index 0. The loop's i++ makes i=1,
                    // correctly skipping the now-processed element. On next requestFunds() call,
                    // the loop restarts at i=0 and processes any remaining elements at that index.
                    unchecked { ++processed; }
                }
            }
        }

        // Only revert if nothing was processed at all
        if (processed == 0) revert("No completed reservations");
        
        // Update provider's last reservation timestamp (activates 30-day lock)
        // This is done after successfully completing/collecting reservations
        if (processed > 0) {
            IStakingFacet(address(this)).updateLastReservation(msg.sender);
        }
        
        // Only transfer if there are actual funds to transfer
        if (totalAmount > 0) {
            IERC20(s.labTokenAddress).safeTransfer(msg.sender, totalAmount);
        }
        
        // Emit event with collection details for observability
        emit FundsCollected(msg.sender, totalAmount, processed);
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

    /// @notice Allows users to release their quota by marking expired reservations as COLLECTED
    /// @dev This function lets renters free up their reservation slots when providers don't call requestFunds
    /// @param _labId The lab ID to clean up expired reservations for
    /// @param _user The user address (or tracking key for institutional users)
    /// @param maxBatch Maximum number of reservations to process (max 50)
    /// @return processed Number of reservations marked as COLLECTED
    /// @custom:use-case User has 10 finished reservations but provider didn't collect → user can't make new bookings
    ///                  User calls this function to free up their quota slots
    function releaseExpiredReservations(uint256 _labId, address _user, uint256 maxBatch) 
        external 
        returns (uint256 processed) 
    {
        // Prevent griefing attack where malicious actor marks reservations
        // as COLLECTED before provider calls requestFunds(), causing permanent loss of funds
        address labProvider = IERC721(address(this)).ownerOf(_labId);
        if (msg.sender != _user && msg.sender != labProvider) {
            revert("Only user or provider can release");
        }
        
        if (maxBatch == 0 || maxBatch > 50) revert("Invalid batch size");
        
        AppStorage storage s = _s();
        EnumerableSet.Bytes32Set storage userReservations = s.reservationKeysByTokenAndUser[_labId][_user];
        uint256 len = userReservations.length();
        
        for (uint256 i = 0; i < len && processed < maxBatch; i++) {
            bytes32 key = userReservations.at(i);
            Reservation storage reservation = s.reservations[key];
            
            // Only process completed reservations that are still marked as BOOKED
            if (reservation.end < block.timestamp && reservation.status == BOOKED) {
                reservation.status = COLLECTED;
                
                // Remove from all indices
                userReservations.remove(key);
                s.reservationsByLabId[_labId].remove(key);
                s.reservationsProvider[reservation.labProvider].remove(key);
                
                // Decrement active reservation counter
                s.activeReservationCountByTokenAndUser[_labId][_user]--;
                
                // Update active reservation index if this was the indexed one
                if (s.activeReservationByTokenAndUser[_labId][_user] == key) {
                    bytes32 nextKey = _findNextEarliestReservation(_labId, _user);
                    s.activeReservationByTokenAndUser[_labId][_user] = nextKey;
                }
                
                --len; // Adjust length after removal
                if (i > 0) --i; // Re-check same index (safe: no underflow at i=0)
                unchecked { ++processed; }
            }
        }
        
        return processed;
    }
}
