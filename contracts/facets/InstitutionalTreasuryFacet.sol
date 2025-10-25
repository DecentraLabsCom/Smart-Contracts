// SPDX-License-Identifier: GPL-3.0-or-later
pragma solidity ^0.8.23;

import {LibAppStorage, AppStorage} from "../libraries/LibAppStorage.sol";
import "../external/LabERC20.sol";

/// @title InstitutionalTreasuryFacet Contract
/// @author Luis de la Torre Cubillo
/// @author Juan Luis Ramos Villalón
/// @notice Allows providers to assign and manage token balances for institutional users (SAML2 schacPersonalUniqueCode)
/// @dev Uses LabERC20 token for deposits and spending. Implements backend authorization pattern for institutional users.
contract InstitutionalTreasuryFacet {
    
    /// @notice Emitted when a provider authorizes a backend address
    event BackendAuthorized(address indexed provider, address indexed backend);
    
    /// @notice Emitted when a provider revokes backend authorization
    event BackendRevoked(address indexed provider, address indexed backend);
    
    /// @notice Emitted when tokens are deposited to institutional treasury
    event InstitutionalTreasuryDeposit(address indexed provider, uint256 amount, uint256 newBalance);
    
    /// @notice Emitted when tokens are withdrawn from institutional treasury
    event InstitutionalTreasuryWithdrawal(address indexed provider, uint256 amount, uint256 newBalance);
    
    /// @notice Emitted when institutional user spending limit is updated
    event InstitutionalUserLimitUpdated(address indexed provider, uint256 newLimit);
    
    /// @notice Emitted when institutional spending period is updated
    event InstitutionalSpendingPeriodUpdated(address indexed provider, uint256 newPeriod);
    
    /// @notice Emitted when an institutional user spends tokens
    event InstitutionalUserSpent(address indexed provider, string puc, uint256 amount, uint256 totalSpent, uint256 periodStart);
    
    /// @dev Modifier to check if caller is the authorized backend for a provider
    modifier onlyAuthorizedBackend(address provider) {
        AppStorage storage s = LibAppStorage.diamondStorage();
        require(s.institutionalBackends[provider] != address(0), "No authorized backend");
        require(msg.sender == s.institutionalBackends[provider], "Not authorized backend");
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
    
    /// @dev Modifier to check if caller is the authorized backend for a provider
    modifier onlyAuthorizedBackend(address provider) {
        AppStorage storage s = LibAppStorage.diamondStorage();
        require(s.institutionalBackends[provider] != address(0), "No authorized backend");
        require(msg.sender == s.institutionalBackends[provider], "Not authorized backend");
        _;
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
    function depositToInstitutionalTreasury(uint256 amount) external {
        AppStorage storage s = LibAppStorage.diamondStorage();
        require(amount > 0, "Amount must be > 0");
        
        // Transfer tokens from provider to Diamond contract
        LabERC20(s.labTokenAddress).transferFrom(msg.sender, address(this), amount);
        
        s.institutionalTreasury[msg.sender] += amount;
        emit InstitutionalTreasuryDeposit(msg.sender, amount, s.institutionalTreasury[msg.sender]);
    }

    /// @notice Withdraw tokens from the provider's institutional treasury
    /// @dev Allows provider to retrieve unspent funds from their treasury
    /// @param amount Amount of tokens to withdraw
    function withdrawFromInstitutionalTreasury(uint256 amount) external {
        AppStorage storage s = LibAppStorage.diamondStorage();
        require(amount > 0, "Amount must be > 0");
        require(s.institutionalTreasury[msg.sender] >= amount, "Insufficient treasury balance");
        
        s.institutionalTreasury[msg.sender] -= amount;
        
        // Transfer tokens back to provider
        LabERC20(s.labTokenAddress).transfer(msg.sender, amount);
        
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
        onlyAuthorizedBackend(provider)
    {
        AppStorage storage s = LibAppStorage.diamondStorage();
        require(amount > 0, "Amount must be > 0");
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
        require(newSpent <= s.institutionalUserLimit[provider], "User spending limit exceeded for period");
    }

    /// @notice Spend tokens from the provider's institutional treasury as an institutional user
    /// @dev Only callable by the provider's authorized backend
    ///      This function marks the spending for accounting purposes with automatic period reset.
    ///      The actual token transfer must be coordinated with ReservationFacet or other payment mechanisms.
    ///      Tokens remain in Diamond contract until explicitly transferred by another facet.
    ///      Spending resets automatically when a new period begins.
    /// @param provider The provider who owns the treasury
    /// @param puc The schacPersonalUniqueCode of the user
    /// @param amount Amount to spend (mark as spent for this user in current period)
    function spendFromInstitutionalTreasury(address provider, string calldata puc, uint256 amount) 
        external 
        onlyAuthorizedBackend(provider) 
    {
        AppStorage storage s = LibAppStorage.diamondStorage();
        require(amount > 0, "Amount must be > 0");
        require(s.institutionalTreasury[provider] >= amount, "Insufficient treasury balance");
        
        // Check period and reset if needed
        uint256 periodStart = _checkAndResetPeriod(provider, puc);
        
        // Get current spending in this period
        InstitutionalUserSpending storage spending = s.institutionalUserSpending[provider][puc];
        uint256 newSpent = spending.amount + amount;
        
        require(newSpent <= s.institutionalUserLimit[provider], "User spending limit exceeded for period");
        
        s.institutionalTreasury[provider] -= amount;
        spending.amount = newSpent;
        
        emit InstitutionalUserSpent(provider, puc, amount, newSpent, periodStart);
    }

    /// @notice Refund tokens back to the provider's institutional treasury (e.g., when canceling a reservation)
    /// @dev Only callable by the provider's authorized backend or Diamond facets
    ///      This reverses a previous spend, incrementing treasury and decrementing user's spent amount
    ///      Period is checked to ensure we're refunding in the correct period
    /// @param provider The provider who owns the treasury
    /// @param puc The schacPersonalUniqueCode of the user
    /// @param amount Amount to refund
    function refundToInstitutionalTreasury(address provider, string calldata puc, uint256 amount) 
        external 
        onlyAuthorizedBackend(provider) 
    {
        AppStorage storage s = LibAppStorage.diamondStorage();
        require(amount > 0, "Amount must be > 0");
        
        // Check period and reset if needed
        uint256 periodStart = _checkAndResetPeriod(provider, puc);
        
        InstitutionalUserSpending storage spending = s.institutionalUserSpending[provider][puc];
        require(spending.amount >= amount, "Refund exceeds spent amount in current period");
        
        s.institutionalTreasury[provider] += amount;
        spending.amount -= amount;
        
        emit InstitutionalUserSpent(provider, puc, 0, spending.amount, periodStart); // Emit with 0 to indicate refund
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
        return s.institutionalUserLimit[provider];
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
        uint256 limit = s.institutionalUserLimit[provider];
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
}
