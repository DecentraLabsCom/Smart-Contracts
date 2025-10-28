// SPDX-License-Identifier: GPL-3.0-or-later
pragma solidity ^0.8.23;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {IERC721} from "@openzeppelin/contracts/token/ERC721/IERC721.sol";
import {EnumerableSet} from "@openzeppelin/contracts/utils/structs/EnumerableSet.sol";
import {ReentrancyGuard} from "@openzeppelin/contracts/security/ReentrancyGuard.sol";
import "./ReservationFacet.sol";

/// @title WalletReservationFacet
/// @author
/// - Luis de la Torre Cubillo
/// - Juan Luis Ramos Villalón
/// @dev Facet contract to manage wallet reservations
/// @notice Provides functions to handle wallet reservation requests,
/// confirmations, denials, cancellations, and expired reservation releases.
/// @dev Payout utilities (`requestFunds`, `getPendingLabPayout`) live here even for
/// institutional labs, because the ERC20 transfer logic and treasury accruals are
/// shared. Institutional providers invoke the same functions via the diamond router.

contract WalletReservationFacet is BaseReservationFacet, ReentrancyGuard {
    using SafeERC20 for IERC20;
    using EnumerableSet for EnumerableSet.AddressSet;

    error InsufficientFunds(address user, uint256 funds, uint256 price);

    function reservationRequest(uint256 _labId, uint32 _start, uint32 _end)
        external
        exists(_labId)
        override
    {
        _reservationRequest(_labId, _start, _end);
    }

    function confirmReservationRequest(bytes32 _reservationKey)
        external
        override
        defaultAdminRole
        reservationPending(_reservationKey)
    {
        _confirmReservationRequest(_reservationKey);
    }

    function denyReservationRequest(bytes32 _reservationKey)
        external
        override
        defaultAdminRole
        reservationPending(_reservationKey)
    {
        _denyReservationRequest(_reservationKey);
    }

    function cancelReservationRequest(bytes32 _reservationKey) external override {
        _cancelReservationRequest(_reservationKey);
    }

    function cancelBooking(bytes32 _reservationKey) external override nonReentrant {
        _cancelBooking(_reservationKey);
    }

    function requestFunds(uint256 _labId, uint256 maxBatch)
        external
        isLabProvider
        nonReentrant
    {
        _requestFunds(_labId, maxBatch);
    }

    function getLabTokenAddress() external view returns (address) {
        return _getLabTokenAddress();
    }

    function getSafeBalance() external view returns (uint256) {
        return _getSafeBalance();
    }

    function releaseExpiredReservations(uint256 _labId, address _user, uint256 maxBatch)
        external
        returns (uint256 processed)
    {
        if (msg.sender != _user) revert("Only user can release their quota");
        return _releaseExpiredReservations(_labId, _user, maxBatch);
    }

    // ---------------------------------------------------------------------
    // Internal overrides
    // ---------------------------------------------------------------------
    function _reservationRequest(uint256 _labId, uint32 _start, uint32 _end) internal override { 
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
        // Proactive auto-release when approaching limit to prevent blocking
        uint256 userActiveCount = s.activeReservationCountByTokenAndUser[_labId][msg.sender];
        
        // Auto-release if user is within 2 slots of limit (80% threshold)
        // This provides breathing room while avoiding unnecessary gas for casual users
        if (userActiveCount >= MAX_RESERVATIONS_PER_LAB_USER - 2) {
            bytes32 earliestKey = s.activeReservationByTokenAndUser[_labId][msg.sender];
            if (earliestKey != bytes32(0)) {
                Reservation storage earliestReservation = s.reservations[earliestKey];
                if (
                    earliestReservation.status == CONFIRMED &&
                    earliestReservation.end < block.timestamp
                ) {
                    _releaseExpiredReservationsInternal(_labId, msg.sender, MAX_RESERVATIONS_PER_LAB_USER);
                    userActiveCount = s.activeReservationCountByTokenAndUser[_labId][msg.sender]; // update after cleanup
                }
            }
        }
        
        // Check limit after auto-release attempt
        if (userActiveCount >= MAX_RESERVATIONS_PER_LAB_USER) {
            revert MaxReservationsReached();
        }
        
        if (_start >= _end || _start <= block.timestamp + RESERVATION_MARGIN) 
            revert("Invalid time range");
      
        uint96 price = s.labs[_labId].price;
        address tokenAddr = s.labTokenAddress;
    
        // Verify user has sufficient balance and allowance (but don't transfer yet)
        uint256 balance = IERC20(tokenAddr).balanceOf(msg.sender);
        if (balance < price) revert InsufficientFunds(msg.sender, balance, price);
        
        uint256 allowance = IERC20(tokenAddr).allowance(msg.sender, address(this));
        if (allowance < price) revert("Insufficient allowance");
        
        bytes32 reservationKey = _getReservationKey(_labId, _start);
        
        // Check availability: Only check if key exists with non-cancelled/non-collected status
        // Note: CANCELLED and COLLECTED keys are removed from reservationKeys set, so this check
        // primarily catches active reservations (PENDING, CONFIRMED, IN_USE, COMPLETED)
        if (s.reservationKeys.contains(reservationKey)) {
            uint8 existingStatus = s.reservations[reservationKey].status;
            // This should only trigger for PENDING, CONFIRMED, IN_USE, or COMPLETED
            // (CANCELLED and COLLECTED are already removed from the set)
            revert("Not available");
        }
        
        // Add to enumerable set (maintains count internally)
        s.reservationKeysByToken[_labId].add(reservationKey);
        
        address collectorInstitution = address(0);
        if (s.institutionalBackends[labOwner] != address(0)) {
            collectorInstitution = labOwner;
        }

        // Direct struct initialization - includes labProvider for safety
        s.reservations[reservationKey] = Reservation({
            labId: _labId,
            renter: msg.sender,
            labProvider: labOwner,
            price: price,
            start: _start,
            end: _end,
            status: PENDING,
            puc: "", // Empty for wallet reservations
            requestPeriodStart: 0, // 0 for wallet reservations (only used for institutional)
            requestPeriodDuration: 0,
            payerInstitution: address(0),
            collectorInstitution: collectorInstitution
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

    function _confirmReservationRequest(bytes32 _reservationKey) internal override {
        AppStorage storage s = _s();
        Reservation storage reservation = s.reservations[_reservationKey];
        // NOTE: Max reservation check was already done in reservationRequest()
        // Counter was incremented there, so no need to check or increment again
        
        // Get CURRENT owner at confirmation time, not the stale value from request
        // This ensures the correct provider's stake is locked if NFT was transferred after request
        address labProvider = IERC721(address(this)).ownerOf(reservation.labId);
        
        // Update stored labProvider in case of NFT transfer between request and confirmation
        reservation.labProvider = labProvider;
        reservation.collectorInstitution = s.institutionalBackends[labProvider] != address(0) ? labProvider : address(0);

        // Re-validate provider stake/listing before attempting to charge renter
        if (!_providerCanFulfill(s, labProvider, reservation.labId)) {
            _cancelReservation(_reservationKey);
            emit ReservationRequestDenied(_reservationKey, reservation.labId);
            return;
        }
    
        // Attempt to collect payment from user using SafeERC20
        // safeTransferFrom will revert if transfer fails or returns false
        try IERC20(s.labTokenAddress).safeTransferFrom(
            reservation.renter,
            address(this),
            reservation.price
        ) {
            // Payment successful ÔåÆ insert into calendar (blocks the slot)
            // This prevents phantom slots from denied PENDING requests
            s.calendars[reservation.labId].insert(reservation.start, reservation.end);
            
            // Update status to CONFIRMED (payment received, slot blocked)
            reservation.status = CONFIRMED;
            s.reservationsProvider[labProvider].add(_reservationKey);
            s.reservationsByLabId[reservation.labId].add(_reservationKey);
            _incrementActiveReservationCounters(reservation);
            _enqueuePayoutCandidate(s, reservation.labId, _reservationKey, reservation.end);
            
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
            // transferFrom reverted (insufficient funds/allowance/failed transfer) ÔåÆ deny reservation
            _cancelReservation(_reservationKey);
            emit ReservationRequestDenied(_reservationKey, reservation.labId);
        }
    }

    function _denyReservationRequest(bytes32 _reservationKey) internal override {
        Reservation storage reservation = _s().reservations[_reservationKey];
       
        // No refund needed - payment was never collected (lazy payment pattern)
        _cancelReservation(_reservationKey);
        emit ReservationRequestDenied(_reservationKey, reservation.labId);
    }

    function _cancelReservationRequest(bytes32 _reservationKey) internal override {
        Reservation storage reservation = _s().reservations[_reservationKey];
        if (reservation.renter == address(0)) revert("Not found");
        if (reservation.renter != msg.sender) revert("Only the renter");
        if (reservation.status != PENDING) revert("Not pending");
    
        _cancelReservation(_reservationKey);
        // No refund needed - payment was never collected (lazy payment pattern)
        emit ReservationRequestCanceled(_reservationKey, reservation.labId);
    }

    function _cancelBooking(bytes32 _reservationKey) internal override {
        AppStorage storage s = _s();
        Reservation storage reservation = s.reservations[_reservationKey];
        // Accept CONFIRMED or IN_USE (both are active, paid reservations)
        if (reservation.renter == address(0) || 
            (reservation.status != CONFIRMED && reservation.status != IN_USE)) 
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
        if (isInstitutional && reservation.payerInstitution != address(0)) {
            // Refund to institutional treasury (payer institution), not to provider's wallet
            IInstitutionalTreasuryFacet(address(this)).refundToInstitutionalTreasury(
                reservation.payerInstitution,
                puc,
                price
            );
        } else {
            // Refund to wallet
            IERC20(s.labTokenAddress).safeTransfer(renter, price);
        }
        
        emit BookingCanceled(_reservationKey, labId);
    }

    function _requestFunds(uint256 _labId, uint256 maxBatch) internal override {
        if (maxBatch == 0 || maxBatch > 100) revert("Invalid batch size");

        AppStorage storage s = _s();

        address labOwner = IERC721(address(this)).ownerOf(_labId);
        address backend = s.institutionalBackends[labOwner];
        if (msg.sender != labOwner && msg.sender != backend) {
            revert("Not authorized");
        }

        uint256 processed;
        uint256 currentTime = block.timestamp;

        while (processed < maxBatch) {
            bytes32 key = _popEligiblePayoutCandidate(s, _labId, currentTime);
            if (key == bytes32(0)) {
                break;
            }
            Reservation storage reservation = s.reservations[key];
            if (_finalizeReservationForPayout(s, key, reservation, _labId)) {
                unchecked {
                    ++processed;
                }
            }
        }

        uint256 walletPayout = s.pendingLabPayout[_labId];
        uint256 totalPayout = walletPayout;
        if (walletPayout > 0) {
            IERC20(s.labTokenAddress).safeTransfer(labOwner, walletPayout);
        }
        s.pendingLabPayout[_labId] = 0;

        EnumerableSet.AddressSet storage collectors = s.pendingInstitutionalCollectors[_labId];
        uint256 collectorsLength = collectors.length();
        for (uint256 i = collectorsLength; i > 0; ) {
            address collector = collectors.at(i - 1);
            uint256 amount = s.pendingInstitutionalLabPayout[_labId][collector];
            if (amount > 0) {
                s.institutionalTreasury[collector] += amount;
                totalPayout += amount;
                s.pendingInstitutionalLabPayout[_labId][collector] = 0;
            }
            collectors.remove(collector);
            unchecked {
                --i;
            }
        }

        if (totalPayout == 0 && processed == 0) revert("No completed reservations");

        if (processed > 0) {
            IStakingFacet(address(this)).updateLastReservation(labOwner);
        }

        emit FundsCollected(labOwner, _labId, totalPayout, processed);
    }

    function _getLabTokenAddress() internal view override returns (address){
        return _s().labTokenAddress;
    }

    function _getSafeBalance() internal view override returns (uint256){ 
        return IERC20(_s().labTokenAddress).balanceOf(address(this));
    }

    function _releaseExpiredReservations(uint256 _labId, address _user, uint256 maxBatch) internal override returns (uint256){
        // Only the user can release their own quota to prevent manipulation
        if (msg.sender != _user) {
            revert("Only user can release their quota");
        }
        
        if (maxBatch == 0 || maxBatch > 50) revert("Invalid batch size");
        
        // Delegate to internal function
        return _releaseExpiredReservationsInternal(_labId, _user, maxBatch);
    }

    /// @notice Returns the total pending payout amount for a lab (wallet + institutional)
    /// @dev Useful for backends/frontends to decide when to call requestFunds()
    ///      and to display total collectable funds in provider dashboard
    /// @param _labId The ID of the lab to query
    /// @return walletPayout Amount pending for direct wallet payout to lab owner
    /// @return institutionalPayout Total amount pending for institutional treasury payouts
    /// @return totalPayout Sum of wallet and institutional payouts
    /// @return institutionalCollectorCount Number of different institutional collectors
    function getPendingLabPayout(uint256 _labId) 
        external 
        view 
        returns (
            uint256 walletPayout,
            uint256 institutionalPayout,
            uint256 totalPayout,
            uint256 institutionalCollectorCount
        ) 
    {
        AppStorage storage s = _s();
        
        walletPayout = s.pendingLabPayout[_labId];
        
        EnumerableSet.AddressSet storage collectors = s.pendingInstitutionalCollectors[_labId];
        institutionalCollectorCount = collectors.length();
        
        for (uint256 i = 0; i < institutionalCollectorCount; i++) {
            address collector = collectors.at(i);
            institutionalPayout += s.pendingInstitutionalLabPayout[_labId][collector];
        }
        
        totalPayout = walletPayout + institutionalPayout;
    }
}
