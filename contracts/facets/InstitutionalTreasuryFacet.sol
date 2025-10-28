// SPDX-License-Identifier: GPL-3.0-or-later
pragma solidity ^0.8.23;

import {LibAppStorage, AppStorage} from "../libraries/LibAppStorage.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {ReentrancyGuard} from "@openzeppelin/contracts/security/ReentrancyGuard.sol";
import "../external/LabERC20.sol";

using SafeERC20 for IERC20;

/// @title InstitutionalTreasuryFacet Contract
/// @author Luis de la Torre Cubillo
/// @author Juan Luis Ramos Villalón
/// @notice Allows providers to assign and manage token balances for institutional users (SAML2 schacPersonalUniqueCode)
/// @dev Uses LabERC20 token for deposits and spending. Implements backend authorization pattern for institutional users.
contract InstitutionalTreasuryFacet is ReentrancyGuard {
    
    /// @notice Emitted when a provider authorizes a backend address
    event BackendAuthorized(address indexed provider, address indexed backend);
    
    /// @notice Emitted when a provider revokes backend authorization
    event BackendRevoked(address indexed provider, address indexed backend);
    
    /// @notice Emitted when tokens are deposited to institutional treasury
    event InstitutionalTreasuryDeposit(address indexed provider, uint256 indexed amount, uint256 newBalance);
    
    /// @notice Emitted when tokens are withdrawn from institutional treasury
    event InstitutionalTreasuryWithdrawal(address indexed provider, uint256 indexed amount, uint256 newBalance);
    
    /// @notice Emitted when institutional user spending limit is updated
    event InstitutionalUserLimitUpdated(address indexed provider, uint256 newLimit);
    
    /// @notice Emitted when institutional spending period is updated
    event InstitutionalSpendingPeriodUpdated(address indexed provider, uint256 newPeriod);
    
    /// @notice Emitted when an institutional user spends tokens
    /// @dev The puc parameter is indexed as keccak256 hash for efficient filtering
    event InstitutionalUserSpent(address indexed provider, string indexed puc, uint256 amount, uint256 totalSpent, uint256 periodStart);
    
    /// @dev Modifier to check if caller is authorized (backend or internal Diamond call)
    /// @param provider The provider address
    /// @custom:security Allows two types of callers:
    ///   1. The authorized backend (for external calls from backend)
    ///   2. The Diamond contract itself (for internal calls from other facets like WalletReservationFacet or InstitutionalReservationFacet)
    modifier onlyAuthorizedBackendOrInternal(address provider) {
        AppStorage storage s = LibAppStorage.diamondStorage();
        
        // Allow internal Diamond calls without requiring a backend
        // Check msg.sender first to avoid reverting on backend check for internal calls
        if (msg.sender != address(this)) {
            require(s.institutionalBackends[provider] != address(0), "No authorized backend");
            require(
                msg.sender == s.institutionalBackends[provider],
                "Not authorized: must be backend"
            );
        }
        _;
    }
    
    /// @notice Get the current spending period for a provider (returns default if not set)
    /// @param provider The provider address
    /// @return The spending period duration in seconds
    function _getSpendingPeriod(address provider) internal view returns (uint256) {
        AppStorage storage s = LibAppStorage.diamondStorage();
        uint256 period = s.institutionalSpendingPeriod[provider];
        return period == 0 ? LibAppStorage.DEFAULT_SPENDING_PERIOD : period;
    }

    /// @notice Returns the per-user spending limit, falling back to default when unset
    function _getSpendingLimit(address provider) internal view returns (uint256) {
        AppStorage storage s = LibAppStorage.diamondStorage();
        uint256 limit = s.institutionalUserLimit[provider];
        return limit == 0 ? LibAppStorage.DEFAULT_INSTITUTIONAL_USER_LIMIT : limit;
    }
    
    /// @notice Check if we're in a new spending period and reset if needed
    /// @param provider The provider address
    /// @param puc The user's schacPersonalUniqueCode
    /// @return currentPeriodStart The start timestamp of the current period
    function _checkAndResetPeriod(address provider, string calldata puc) internal returns (uint256 currentPeriodStart) {
        AppStorage storage s = LibAppStorage.diamondStorage();
        uint256 periodDuration = _getSpendingPeriod(provider);
        uint256 now_ = block.timestamp;
        
        InstitutionalUserSpending storage spending = s.institutionalUserSpending[provider][puc];
        
        // Calculate current period start based on period duration
        currentPeriodStart = (now_ / periodDuration) * periodDuration;
        
        // If period has changed, reset spending
        if (spending.periodStart != currentPeriodStart) {
            spending.amount = 0;
            spending.periodStart = currentPeriodStart;
        }
        
        return currentPeriodStart;
    }
    
    /// @notice Authorize a backend address to spend from institutional treasury
    /// @param backend The backend address to authorize
    function authorizeBackend(address backend) external {
        AppStorage storage s = LibAppStorage.diamondStorage();
        require(backend != address(0), "Invalid backend address");
        s.institutionalBackends[msg.sender] = backend;
        emit BackendAuthorized(msg.sender, backend);
    }
    
    /// @notice Revoke backend authorization
    function revokeBackend() external {
        AppStorage storage s = LibAppStorage.diamondStorage();
        address previousBackend = s.institutionalBackends[msg.sender];
        require(previousBackend != address(0), "No backend to revoke");
        delete s.institutionalBackends[msg.sender];
        emit BackendRevoked(msg.sender, previousBackend);
    }
    /// @notice Deposit tokens to the provider's institutional treasury (global)
    /// @dev Provider must approve tokens before calling this function
    /// @param amount Amount of tokens to deposit
    /// @custom:security nonReentrant modifier protects against reentrancy attacks
    function depositToInstitutionalTreasury(uint256 amount) external nonReentrant {
        AppStorage storage s = LibAppStorage.diamondStorage();
        require(amount > 0, "Amount must be > 0");
        
        // Transfer tokens from provider to Diamond contract using SafeERC20
        IERC20(s.labTokenAddress).safeTransferFrom(msg.sender, address(this), amount);
        
        s.institutionalTreasury[msg.sender] += amount;
        emit InstitutionalTreasuryDeposit(msg.sender, amount, s.institutionalTreasury[msg.sender]);
    }

    /// @notice Withdraw tokens from the provider's institutional treasury
    /// @dev Allows provider to retrieve unspent funds from their treasury
    /// @param amount Amount of tokens to withdraw
    /// @custom:security nonReentrant modifier protects against reentrancy attacks
    function withdrawFromInstitutionalTreasury(uint256 amount) external nonReentrant {
        AppStorage storage s = LibAppStorage.diamondStorage();
        require(amount > 0, "Amount must be > 0");
        require(s.institutionalTreasury[msg.sender] >= amount, "Insufficient treasury balance");
        
        s.institutionalTreasury[msg.sender] -= amount;
        
        // Transfer tokens back to provider using SafeERC20
        IERC20(s.labTokenAddress).safeTransfer(msg.sender, amount);
        
        emit InstitutionalTreasuryWithdrawal(msg.sender, amount, s.institutionalTreasury[msg.sender]);
    }

    /// @notice Set the spending limit per institutional user (global for provider)
    /// @param limit The maximum amount a user can spend per period
    function setInstitutionalUserLimit(uint256 limit) external {
        AppStorage storage s = LibAppStorage.diamondStorage();
        require(limit > 0, "Limit must be > 0");
        s.institutionalUserLimit[msg.sender] = limit;
        emit InstitutionalUserLimitUpdated(msg.sender, limit);
    }
    
    /// @notice Set the spending period duration for institutional users
    /// @param periodDuration The duration of the spending period in seconds (e.g., 30 days = 2592000)
    /// @dev Common values: 1 day = 86400, 7 days = 604800, 30 days = 2592000, 1 year = 31536000
    function setInstitutionalSpendingPeriod(uint256 periodDuration) external {
        AppStorage storage s = LibAppStorage.diamondStorage();
        require(periodDuration > 0, "Period must be > 0");
        require(periodDuration <= 365 days, "Period too long");
        s.institutionalSpendingPeriod[msg.sender] = periodDuration;
        emit InstitutionalSpendingPeriodUpdated(msg.sender, periodDuration);
    }

    /// @notice Checks if the institutional treasury has sufficient balance and user hasn't exceeded spending limit
    /// @dev View function that verifies availability without modifying state
    ///      Used in lazy payment pattern to verify before creating reservation request
    /// @param provider The provider who owns the treasury
    /// @param puc The schacPersonalUniqueCode of the user
    /// @param amount Amount to check
    /// @custom:throws Reverts if backend not authorized, treasury insufficient, or user exceeds limit
    function checkInstitutionalTreasuryAvailability(address provider, string calldata puc, uint256 amount) 
        external 
        view
    {
        AppStorage storage s = LibAppStorage.diamondStorage();
        
        if (msg.sender != address(this)) {
            require(s.institutionalBackends[provider] != address(0), "No authorized backend");
            require(msg.sender == s.institutionalBackends[provider], "Not authorized: must be backend");
        }
        
        // Allow zero-price reservations (free labs)
        if (amount == 0) return;
        
        require(s.institutionalTreasury[provider] >= amount, "Insufficient treasury balance");
        
        // Calculate current period
        uint256 periodDuration = s.institutionalSpendingPeriod[provider];
        if (periodDuration == 0) {
            periodDuration = LibAppStorage.DEFAULT_SPENDING_PERIOD;
        }
        
        InstitutionalUserSpending storage spending = s.institutionalUserSpending[provider][puc];
        uint256 currentPeriodStart = (block.timestamp / periodDuration) * periodDuration;
        
        // Check if we're in a new period (spending would be reset to 0)
        uint256 currentSpending = 0;
        if (spending.periodStart == currentPeriodStart && spending.periodStart != 0) {
            currentSpending = spending.amount;
        }
        
        uint256 newSpent = currentSpending + amount;
        require(newSpent <= _getSpendingLimit(provider), "User spending limit exceeded for period");
    }

    /// @notice Spend tokens from the provider's institutional treasury as an institutional user
    /// @dev Only callable by the provider's authorized backend
    ///      This function marks the spending for accounting purposes with automatic period reset.
    ///      The actual token transfer must be coordinated with WalletReservationFacet, InstitutionalReservationFacet or other payment mechanisms.
    ///      Tokens remain in Diamond contract until explicitly transferred by another facet.
    ///      Spending resets automatically when a new period begins.
    /// @param provider The provider who owns the treasury
    /// @param puc The schacPersonalUniqueCode of the user
    /// @param amount Amount to spend (mark as spent for this user in current period)
    function spendFromInstitutionalTreasury(address provider, string calldata puc, uint256 amount) 
        external 
        onlyAuthorizedBackendOrInternal(provider) 
    {
        AppStorage storage s = LibAppStorage.diamondStorage();
        
        // Allow zero-price reservations (free labs) - skip all accounting for free reservations
        if (amount == 0) return;
        
        require(s.institutionalTreasury[provider] >= amount, "Insufficient treasury balance");
        
        // Check period and reset if needed
        uint256 periodStart = _checkAndResetPeriod(provider, puc);
        
        // Get current spending in this period
        InstitutionalUserSpending storage spending = s.institutionalUserSpending[provider][puc];
        uint256 newSpent = spending.amount + amount;
        
        require(newSpent <= _getSpendingLimit(provider), "User spending limit exceeded for period");
        
        s.institutionalTreasury[provider] -= amount;
        spending.amount = newSpent;
        
        // Track total historical spending (never reset, used for refunds)
        spending.totalHistoricalSpent += amount;
        
        emit InstitutionalUserSpent(provider, puc, amount, newSpent, periodStart);
    }

    /// @notice Refund tokens back to the provider's institutional treasury (e.g., when canceling a reservation)
    /// @dev Only WalletReservationFacet or InstitutionalReservationFacet can call this via cancelBooking/cancelInstitutionalBooking
    ///      This reverses a previous spend, incrementing treasury and decrementing user's spent amount
    ///      Allows refunds from past periods
    /// @param provider The provider who owns the treasury
    /// @param puc The schacPersonalUniqueCode of the user
    /// @param amount Amount to refund
    function refundToInstitutionalTreasury(address provider, string calldata puc, uint256 amount) 
        external 
    {
        // Prevent compromised backends from calling this function arbitrarily
        require(msg.sender == address(this), "Only internal Diamond calls");
        
        AppStorage storage s = LibAppStorage.diamondStorage();
        
        // Allow zero-price refunds (free labs) - nothing to refund
        if (amount == 0) return;
        
        InstitutionalUserSpending storage spending = s.institutionalUserSpending[provider][puc];
        
        // Use totalHistoricalSpent for validation (never reset across periods)
        // This allows refunds for bookings made in previous periods
        require(spending.totalHistoricalSpent >= amount, "Refund exceeds total spent amount");
        
        s.institutionalTreasury[provider] += amount;
        
        // Always decrement totalHistoricalSpent (tracks all-time spending)
        spending.totalHistoricalSpent -= amount;
        
        // Check if we're in the same period as when the spend was tracked
        // Only decrement current period amount if refund doesn't exceed it
        // (prevents underflow when refunding old-period bookings after rollover)
        if (spending.amount >= amount) {
            spending.amount -= amount;
        }
        
        // Get current period for event logging
        uint256 periodDuration = _getSpendingPeriod(provider);
        uint256 currentPeriodStart = (block.timestamp / periodDuration) * periodDuration;
        
        emit InstitutionalUserSpent(provider, puc, 0, spending.amount, currentPeriodStart); // Emit with 0 to indicate refund
    }

    /// @notice Get provider's institutional treasury balance
    function getInstitutionalTreasuryBalance(address provider) external view returns (uint256) {
        AppStorage storage s = LibAppStorage.diamondStorage();
        return s.institutionalTreasury[provider];
    }

    /// @notice Get institutional user's spent amount in current period
    /// @param provider The provider who owns the treasury
    /// @param puc The user's schacPersonalUniqueCode
    /// @return The amount spent in the current period
    function getInstitutionalUserSpent(address provider, string calldata puc) external view returns (uint256) {
        AppStorage storage s = LibAppStorage.diamondStorage();
        uint256 periodDuration = _getSpendingPeriod(provider);
        uint256 currentPeriodStart = (block.timestamp / periodDuration) * periodDuration;
        
        InstitutionalUserSpending storage spending = s.institutionalUserSpending[provider][puc];
        
        // If stored period doesn't match current period, spending is 0 (would be reset on next write)
        if (spending.periodStart != currentPeriodStart) {
            return 0;
        }
        
        return spending.amount;
    }
    
    /// @notice Get institutional user's spending data (amount and period start)
    /// @param provider The provider who owns the treasury
    /// @param puc The user's schacPersonalUniqueCode
    /// @return amount The amount spent in the current period
    /// @return periodStart The start timestamp of the current period
    function getInstitutionalUserSpendingData(address provider, string calldata puc) external view returns (uint256 amount, uint256 periodStart) {
        AppStorage storage s = LibAppStorage.diamondStorage();
        uint256 periodDuration = _getSpendingPeriod(provider);
        uint256 currentPeriodStart = (block.timestamp / periodDuration) * periodDuration;
        
        InstitutionalUserSpending storage spending = s.institutionalUserSpending[provider][puc];
        
        // If stored period doesn't match current period, spending is 0 (would be reset on next write)
        if (spending.periodStart != currentPeriodStart) {
            return (0, currentPeriodStart);
        }
        
        return (spending.amount, spending.periodStart);
    }

    /// @notice Get institutional user spending limit
    function getInstitutionalUserLimit(address provider) external view returns (uint256) {
        AppStorage storage s = LibAppStorage.diamondStorage();
        return _getSpendingLimit(provider);
    }
    
    /// @notice Get the spending period duration for a provider
    /// @param provider The provider address
    /// @return The spending period duration in seconds (default: 30 days if not set)
    function getInstitutionalSpendingPeriod(address provider) external view returns (uint256) {
        return _getSpendingPeriod(provider);
    }
    
    /// @notice Get the authorized backend for a provider
    /// @param provider The provider address
    /// @return The authorized backend address (or address(0) if none)
    function getAuthorizedBackend(address provider) external view returns (address) {
        AppStorage storage s = LibAppStorage.diamondStorage();
        return s.institutionalBackends[provider];
    }
    
    /// @notice Get remaining spending allowance for an institutional user in current period
    /// @param provider The provider who owns the treasury
    /// @param puc The schacPersonalUniqueCode of the user
    /// @return The remaining amount the user can spend in the current period
    function getInstitutionalUserRemainingAllowance(address provider, string calldata puc) external view returns (uint256) {
        AppStorage storage s = LibAppStorage.diamondStorage();
        uint256 limit = _getSpendingLimit(provider);
        uint256 periodDuration = _getSpendingPeriod(provider);
        uint256 currentPeriodStart = (block.timestamp / periodDuration) * periodDuration;
        
        InstitutionalUserSpending storage spending = s.institutionalUserSpending[provider][puc];
        
        // If stored period doesn't match current period, full limit is available
        if (spending.periodStart != currentPeriodStart) {
            return limit;
        }
        
        uint256 spent = spending.amount;
        return limit > spent ? limit - spent : 0;
    }

    /// @notice Get comprehensive financial statistics for an institutional user
    /// @dev Provides all financial metrics needed for user dashboard in a single call
    /// @param provider The provider who owns the treasury
    /// @param puc The schacPersonalUniqueCode of the institutional user
    /// @return currentPeriodSpent Amount spent in the current period
    /// @return totalHistoricalSpent Total amount ever spent (across all periods)
    /// @return spendingLimit Maximum allowed spending per period
    /// @return remainingAllowance Amount remaining in current period
    /// @return periodStart Start timestamp of the current period
    /// @return periodEnd End timestamp of the current period (periodStart + duration)
    /// @return periodDuration Duration of each spending period in seconds
    function getInstitutionalUserFinancialStats(
        address provider,
        string calldata puc
    ) external view returns (
        uint256 currentPeriodSpent,
        uint256 totalHistoricalSpent,
        uint256 spendingLimit,
        uint256 remainingAllowance,
        uint256 periodStart,
        uint256 periodEnd,
        uint256 periodDuration
    ) {
        AppStorage storage s = LibAppStorage.diamondStorage();
        
        // Get spending limit and period duration
        spendingLimit = _getSpendingLimit(provider);
        periodDuration = _getSpendingPeriod(provider);
        
        // Calculate current period boundaries
        periodStart = (block.timestamp / periodDuration) * periodDuration;
        periodEnd = periodStart + periodDuration;
        
        // Get user spending data
        InstitutionalUserSpending storage spending = s.institutionalUserSpending[provider][puc];
        totalHistoricalSpent = spending.totalHistoricalSpent;
        
        // If stored period matches current period, use stored spending
        // Otherwise, spending is 0 (new period)
        if (spending.periodStart == periodStart) {
            currentPeriodSpent = spending.amount;
        } else {
            currentPeriodSpent = 0;
        }
        
        // Calculate remaining allowance
        remainingAllowance = spendingLimit > currentPeriodSpent 
            ? spendingLimit - currentPeriodSpent 
            : 0;
        
        return (
            currentPeriodSpent,
            totalHistoricalSpent,
            spendingLimit,
            remainingAllowance,
            periodStart,
            periodEnd,
            periodDuration
        );
    }
}
