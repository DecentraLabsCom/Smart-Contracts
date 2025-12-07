// SPDX-License-Identifier: GPL-3.0-or-later
pragma solidity ^0.8.23;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {IERC721} from "@openzeppelin/contracts/token/ERC721/IERC721.sol";
import {EnumerableSet} from "@openzeppelin/contracts/utils/structs/EnumerableSet.sol";
import {ReentrancyGuard} from "@openzeppelin/contracts/security/ReentrancyGuard.sol";
import {BaseReservationFacet, IStakingFacet, IInstitutionalTreasuryFacet} from "./ReservationFacet.sol";
import {RivalIntervalTreeLibrary, Tree} from "../libraries/RivalIntervalTreeLibrary.sol";
import {AppStorage, Reservation} from "../libraries/LibAppStorage.sol";
import {ActionIntentPayload} from "../libraries/IntentTypes.sol";
import {LibIntent} from "../libraries/LibIntent.sol";
import {ReservableToken} from "../abstracts/ReservableToken.sol";

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
    using EnumerableSet for EnumerableSet.Bytes32Set;
    using RivalIntervalTreeLibrary for Tree;

    error InsufficientFunds(address user, uint256 funds, uint256 price);
    uint256 internal constant PENDING_REQUEST_TTL = 1 hours;

    /// @notice Event emitted when a lab intent is processed (mirrors LabFacet)
    event LabIntentProcessed(bytes32 indexed requestId, uint256 labId, string action, address provider, bool success, string reason);

    /// @notice Emitted when default admin recovers stale payouts for a lab
    event OrphanedLabPayoutRecovered(uint256 indexed labId, address indexed recipient, uint256 providerPayout, uint256 reservationsProcessed);

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
        reservationPending(_reservationKey)
    {
        // Only lab provider (owner or authorized backend) can confirm
        _requireLabProviderOrBackend(_reservationKey);
        _confirmReservationRequest(_reservationKey);
    }

    function denyReservationRequest(bytes32 _reservationKey)
        external
        override
        reservationPending(_reservationKey)
    {
        // Only lab provider (owner or authorized backend) can deny
        _requireLabProviderOrBackend(_reservationKey);
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

    /// @notice Collects funds via intent (institutional flow) while keeping direct call available
    function requestFundsWithIntent(
        bytes32 requestId,
        uint256 _labId,
        uint256 maxBatch
    )
        external
        isLabProvider
        nonReentrant
    {
        if (maxBatch == 0 || maxBatch > 100) revert("Invalid batch size");

        ActionIntentPayload memory payload = ActionIntentPayload({
            executor: msg.sender,
            schacHomeOrganization: "",
            puc: "",
            assertionHash: bytes32(0),
            labId: _labId,
            reservationKey: bytes32(0),
            uri: "",
            price: 0,
            // forge-lint: disable-next-line(unsafe-typecast)
            maxBatch: uint96(maxBatch),
            auth: "",
            accessURI: "",
            accessKey: "",
            tokenURI: ""
        });

        bytes32 payloadHash = LibIntent.hashActionPayload(payload);
        LibIntent.consumeIntent(requestId, LibIntent.ACTION_REQUEST_FUNDS, payloadHash, msg.sender);

        _requestFunds(_labId, maxBatch);
        emit LabIntentProcessed(requestId, _labId, "REQUEST_FUNDS", msg.sender, true, "");
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
    // Access control helpers
    // ---------------------------------------------------------------------

    /// @dev Verifies that caller is the lab owner or authorized backend for institutional labs
    function _requireLabProviderOrBackend(bytes32 _reservationKey) internal view {
        AppStorage storage s = _s();
        Reservation storage reservation = s.reservations[_reservationKey];
        address labOwner = IERC721(address(this)).ownerOf(reservation.labId);
        address authorizedBackend = s.institutionalBackends[labOwner];
        
        require(
            msg.sender == labOwner || (authorizedBackend != address(0) && msg.sender == authorizedBackend),
            "Only lab provider or authorized backend"
        );
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
    
        // Verify user has sufficient balance and allowance (but don't transfer yet)
        uint256 balance = IERC20(s.labTokenAddress).balanceOf(msg.sender);
        if (balance < price) revert InsufficientFunds(msg.sender, balance, price);
        
        if (IERC20(s.labTokenAddress).allowance(msg.sender, address(this)) < price) revert("Insufficient allowance");
        
        bytes32 reservationKey = _getReservationKey(_labId, _start);
        
        // Check availability: block reuse if an active reservation already exists for this slot
        Reservation storage existing = s.reservations[reservationKey];
        if (existing.renter != address(0) && existing.status != CANCELLED && existing.status != COLLECTED) {
            bool isStalePending = existing.status == PENDING
                && (existing.requestPeriodStart == 0 || block.timestamp >= existing.requestPeriodStart + PENDING_REQUEST_TTL);
            if (isStalePending) {
                _cancelReservation(reservationKey);
            } else {
                revert("Not available");
            }
        }

        // Add to enumerable set (maintains count internally)
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
            puc: "", // Empty for wallet reservations
            requestPeriodStart: uint64(block.timestamp), // track creation to expire stale PENDING
            requestPeriodDuration: 0,
            payerInstitution: address(0),
            collectorInstitution: s.institutionalBackends[labOwner] != address(0) ? labOwner : address(0),
            providerShare: 0,
            projectTreasuryShare: 0,
            subsidiesShare: 0,
            governanceShare: 0
        });
        
        // Add to tracking sets
        s.totalReservationsCount++;
        s.renters[msg.sender].add(reservationKey);
        
        // Increment active reservation count (includes PENDING to prevent DoS)
        s.activeReservationCountByTokenAndUser[_labId][msg.sender]++;
        
        // Add to per-token-user index
        s.reservationKeysByTokenAndUser[_labId][msg.sender].add(reservationKey);

        // Maintain recent buffers (token and user)
        _recordRecent(s, _labId, msg.sender, reservationKey, _start);
    
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

        // Attempt to collect payment from user with graceful failure handling
        (bool success, bytes memory data) = s.labTokenAddress.call(
            abi.encodeWithSelector(IERC20.transferFrom.selector, reservation.renter, address(this), uint256(reservation.price))
        );

        if (!success || (data.length != 0 && !abi.decode(data, (bool)))) {
            _cancelReservation(_reservationKey);
            emit ReservationRequestDenied(_reservationKey, reservation.labId);
            return;
        }

        _setReservationSplit(reservation);
        // Payment successful ? insert into calendar (blocks the slot)
        // This prevents phantom slots from denied PENDING requests
        s.calendars[reservation.labId].insert(reservation.start, reservation.end);
        
        // Update status to CONFIRMED (payment received, slot blocked)
        reservation.status = CONFIRMED;
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
        uint96 price = reservation.price;
        uint256 labId = reservation.labId;
        string memory puc = reservation.puc;
        bool isInstitutional = bytes(puc).length > 0;
        uint96 providerFee;
        uint96 treasuryFee;
        uint96 governanceFee;
        uint96 refundAmount = price;
        
        if (price > 0) {
            (providerFee, treasuryFee, governanceFee, refundAmount) = _computeCancellationFee(price);
        }
        
        // Check current owner to allow new owners to manage reservations after transfer
        address currentOwner = IERC721(address(this)).ownerOf(labId);
        if (renter != msg.sender && currentOwner != msg.sender) revert("Unauthorized");
    
        _cancelReservation(_reservationKey);

        if (price > 0) {
            _applyCancellationFees(s, labId, providerFee, treasuryFee, governanceFee);
        }
        
        // Refund based on reservation type
        if (isInstitutional && reservation.payerInstitution != address(0)) {
            // Refund to institutional treasury (payer institution), not to provider's wallet
            IInstitutionalTreasuryFacet(address(this)).refundToInstitutionalTreasury(
                reservation.payerInstitution,
                puc,
                refundAmount
            );
        } else {
            // Refund to wallet
            IERC20(s.labTokenAddress).safeTransfer(renter, refundAmount);
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

        uint256 providerPayout = s.pendingProviderPayout[_labId];
        if (providerPayout == 0 && processed == 0) revert("No completed reservations");

        if (providerPayout > 0) {
            IERC20(s.labTokenAddress).safeTransfer(labOwner, providerPayout);
            s.pendingProviderPayout[_labId] = 0;
        }

        if (processed > 0) {
            IStakingFacet(address(this)).updateLastReservation(labOwner);
        }

        emit FundsCollected(labOwner, _labId, providerPayout, processed);
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
        
        walletPayout = s.pendingProviderPayout[_labId];
        institutionalPayout = 0;
        institutionalCollectorCount = 0;
        
        totalPayout = walletPayout;
    }

    /// @notice One-time initializer to set revenue recipient wallets (15% treasury, 10% subsidies, 5% governance)
    /// @dev Can only be called once by default admin. Addresses are immutable afterwards.
    function initializeRevenueRecipients(
        address projectTreasury,
        address subsidies,
        address governance
    ) external defaultAdminRole {
        AppStorage storage s = _s();
        require(s.projectTreasuryWallet == address(0), "Revenue recipients already set");
        require(projectTreasury != address(0) && subsidies != address(0) && governance != address(0), "Invalid address");

        s.projectTreasuryWallet = projectTreasury;
        s.subsidiesWallet = subsidies;
        s.governanceWallet = governance;
    }

    /// @notice Withdraw accumulated project treasury share
    function withdrawProjectTreasury() external {
        AppStorage storage s = _s();
        require(msg.sender == s.projectTreasuryWallet, "Not treasury wallet");
        uint256 amount = s.pendingProjectTreasury;
        require(amount > 0, "No funds");
        s.pendingProjectTreasury = 0;
        IERC20(s.labTokenAddress).safeTransfer(msg.sender, amount);
    }

    /// @notice Withdraw accumulated subsidies share
    function withdrawSubsidies() external {
        AppStorage storage s = _s();
        require(msg.sender == s.subsidiesWallet, "Not subsidies wallet");
        uint256 amount = s.pendingSubsidies;
        require(amount > 0, "No funds");
        s.pendingSubsidies = 0;
        IERC20(s.labTokenAddress).safeTransfer(msg.sender, amount);
    }

    /// @notice Withdraw accumulated governance incentives share
    function withdrawGovernance() external {
        AppStorage storage s = _s();
        require(msg.sender == s.governanceWallet, "Not governance wallet");
        uint256 amount = s.pendingGovernance;
        require(amount > 0, "No funds");
        s.pendingGovernance = 0;
        IERC20(s.labTokenAddress).safeTransfer(msg.sender, amount);
    }

    /// @notice Admin path to recover stale lab payouts when the provider is inactive or lost access
    /// @dev Processes only reservations whose end time passed the timelock and withdraws matured provider bucket
    /// @param _labId Lab whose payouts should be recovered
    /// @param maxBatch Maximum reservations to process in this call (1-100)
    /// @param recipient Address that will receive the provider share once unlocked
    function adminRecoverOrphanedPayouts(
        uint256 _labId,
        uint256 maxBatch,
        address recipient
    )
        external
        defaultAdminRole
        nonReentrant
    {
        if (recipient == address(0)) revert("Invalid recipient");
        if (maxBatch == 0 || maxBatch > 100) revert("Invalid batch size");

        AppStorage storage s = _s();
        uint256 processed;
        uint256 cutoffTime = block.timestamp - ORPHAN_PAYOUT_DELAY;

        // Only finalize reservations that ended before cutoffTime
        while (processed < maxBatch) {
            bytes32 key = _popEligiblePayoutCandidate(s, _labId, cutoffTime);
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

        uint256 providerPayout = s.pendingProviderPayout[_labId];
        bool payoutUnlocked = providerPayout > 0
            && s.pendingProviderLastUpdated[_labId] > 0
            && block.timestamp >= s.pendingProviderLastUpdated[_labId] + ORPHAN_PAYOUT_DELAY;

        if (payoutUnlocked) {
            s.pendingProviderPayout[_labId] = 0;
            IERC20(s.labTokenAddress).safeTransfer(recipient, providerPayout);
        } else {
            providerPayout = 0;
        }

        if (providerPayout == 0 && processed == 0) revert("Nothing to recover");

        emit OrphanedLabPayoutRecovered(_labId, recipient, providerPayout, processed);
    }

    // Institutional-only hooks required by BaseReservationFacet but unused here
    function _institutionalReservationRequest(
        address,
        string calldata,
        uint256,
        uint32,
        uint32
    ) internal pure override { revert("Institutional reservation only"); }

    function _confirmInstitutionalReservationRequest(address, bytes32) internal pure override { revert("Institutional reservation only"); }

    function _denyInstitutionalReservationRequest(address, string calldata, bytes32) internal pure override { revert("Institutional reservation only"); }

    function _cancelInstitutionalReservationRequest(address, string calldata, bytes32) internal pure override { revert("Institutional reservation only"); }

    function _cancelInstitutionalBooking(address, bytes32) internal pure override { revert("Institutional reservation only"); }

    function _releaseInstitutionalExpiredReservations(
        address,
        string calldata,
        uint256,
        uint256
    ) internal pure override returns (uint256) { revert("Institutional reservation only"); }

    function _getInstitutionalUserReservationCount(address, string calldata) internal pure override returns (uint256) { return 0; }

    function _getInstitutionalUserReservationByIndex(
        address,
        string calldata,
        uint256
    ) internal pure override returns (bytes32) { return bytes32(0); }

    function _hasInstitutionalUserActiveBooking(
        address,
        string calldata,
        uint256
    ) internal pure override returns (bool) { return false; }

    function _getInstitutionalUserActiveReservationKey(
        address,
        string calldata,
        uint256
    ) internal pure override returns (bytes32) { return bytes32(0); }
}
