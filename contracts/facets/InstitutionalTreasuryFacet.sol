// SPDX-License-Identifier: GPL-3.0-or-later
pragma solidity ^0.8.23;

import {LibAppStorage, AppStorage, INSTITUTION_ROLE, InstitutionalUserSpending} from "../libraries/LibAppStorage.sol";
import {EnumerableSet} from "@openzeppelin/contracts/utils/structs/EnumerableSet.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {ReentrancyGuard} from "@openzeppelin/contracts/security/ReentrancyGuard.sol";
import "../external/LabERC20.sol";

using SafeERC20 for IERC20;

/// @title InstitutionalTreasuryFacet Contract
/// @author Luis de la Torre Cubillo
/// @author Juan Luis Ramos Villalón
/// @notice Allows institutions to assign and manage token balances for institutional users (SAML2 schacPersonalUniqueCode)
/// @dev Uses LabERC20 token for deposits and spending. Implements backend authorization pattern for institutional users.
contract InstitutionalTreasuryFacet is ReentrancyGuard {
    using EnumerableSet for EnumerableSet.AddressSet;
    
    /// @notice Emitted when an institution authorizes a backend address
    event BackendAuthorized(address indexed institution, address indexed backend);
    
    /// @notice Emitted when an institution revokes backend authorization
    event BackendRevoked(address indexed institution, address indexed backend);
    
    /// @notice Emitted when tokens are deposited to institutional treasury
    event InstitutionalTreasuryDeposit(address indexed institution, uint256 indexed amount, uint256 newBalance);
    
    /// @notice Emitted when tokens are withdrawn from institutional treasury
    event InstitutionalTreasuryWithdrawal(address indexed institution, uint256 indexed amount, uint256 newBalance);
    
    /// @notice Emitted when institutional user spending limit is updated
    event InstitutionalUserLimitUpdated(address indexed institution, uint256 newLimit);
    
    /// @notice Emitted when institutional spending period is updated
    event InstitutionalSpendingPeriodUpdated(address indexed institution, uint256 newPeriod);
    
    /// @notice Emitted when an institution manually resets their period anchor
    event InstitutionalSpendingPeriodReset(address indexed institution, uint256 newPeriodStart);
    
    /// @notice Emitted when an institutional user spends tokens
    /// @dev The puc parameter is indexed as keccak256 hash for efficient filtering
    event InstitutionalUserSpent(address indexed institution, string indexed puc, uint256 amount, uint256 totalSpent, uint256 periodStart);
    
    /// @dev Modifier to check if caller is authorized (backend or internal Diamond call)
    /// @param institution The institution address
    /// @custom:security Allows two types of callers:
    ///   1. The authorized backend (for external calls from backend)
    ///   2. The Diamond contract itself (for internal calls from other facets like WalletReservationFacet or InstitutionalReservationFacet)
    modifier onlyAuthorizedBackendOrInternal(address institution) {
        AppStorage storage s = LibAppStorage.diamondStorage();
        
        // Allow internal Diamond calls without requiring a backend
        // Check msg.sender first to avoid reverting on backend check for internal calls
        if (msg.sender != address(this)) {
            require(s.institutionalBackends[institution] != address(0), "No authorized backend");
            require(
                msg.sender == s.institutionalBackends[institution],
                "Not authorized: must be backend"
            );
        }
        _;
    }

    modifier onlyInstitutionCaller() {
        _requireInstitution(msg.sender);
        _;
    }
    
    /// @notice Get the current spending period for an institution (returns default if not set)
    /// @param institution The institution address
    /// @return The spending period duration in seconds
    function _getSpendingPeriod(address institution) internal view returns (uint256) {
        AppStorage storage s = LibAppStorage.diamondStorage();
        uint256 period = s.institutionalSpendingPeriod[institution];
        return period == 0 ? LibAppStorage.DEFAULT_SPENDING_PERIOD : period;
    }

    function _calculatePeriodStart(uint256 timestamp, uint256 periodDuration, uint256 anchor) internal pure returns (uint256) {
        if (anchor == 0) {
            return (timestamp / periodDuration) * periodDuration;
        }

        if (anchor > timestamp) {
            anchor = timestamp;
        }

        return anchor + ((timestamp - anchor) / periodDuration) * periodDuration;
    }

    function _currentPeriodStart(address institution, uint256 periodDuration) internal view returns (uint256) {
        AppStorage storage s = LibAppStorage.diamondStorage();
        return _calculatePeriodStart(block.timestamp, periodDuration, s.institutionalSpendingPeriodAnchor[institution]);
    }

    /// @notice Returns the per-user spending limit, falling back to default when unset
    function _getSpendingLimit(address institution) internal view returns (uint256) {
        AppStorage storage s = LibAppStorage.diamondStorage();
        uint256 limit = s.institutionalUserLimit[institution];
        return limit == 0 ? LibAppStorage.DEFAULT_INSTITUTIONAL_USER_LIMIT : limit;
    }

    function _requireDefaultAdmin(address account) internal view {
        AppStorage storage s = LibAppStorage.diamondStorage();
        require(s.roleMembers[s.DEFAULT_ADMIN_ROLE].contains(account), "Only default admin");
    }

    function _requireInstitution(address account) internal view {
        AppStorage storage s = LibAppStorage.diamondStorage();
        require(s.roleMembers[INSTITUTION_ROLE].contains(account), "Unknown institution");
    }
    
    /// @notice Check if we're in a new spending period and reset if needed
    /// @param institution The institution address
    /// @param puc The user's schacPersonalUniqueCode
    /// @return currentPeriodStart The start timestamp of the current period
    function _checkAndResetPeriod(address institution, string calldata puc) internal returns (uint256 currentPeriodStart) {
        AppStorage storage s = LibAppStorage.diamondStorage();
        uint256 periodDuration = _getSpendingPeriod(institution);
        InstitutionalUserSpending storage spending = s.institutionalUserSpending[institution][puc];
        uint256 anchor = s.institutionalSpendingPeriodAnchor[institution];
        
        // Calculate current period start based on period duration or custom anchor
        currentPeriodStart = _calculatePeriodStart(block.timestamp, periodDuration, anchor);
        
        // If period has changed, reset spending
        if (spending.periodStart != currentPeriodStart) {
            spending.amount = 0;
            spending.periodStart = currentPeriodStart;
        }
        
        return currentPeriodStart;
    }
    
    /// @notice Authorize a backend address to spend from institutional treasury
    /// @param backend The backend address to authorize
    function authorizeBackend(address backend) external onlyInstitutionCaller {
        AppStorage storage s = LibAppStorage.diamondStorage();
        require(backend != address(0), "Invalid backend address");

        address previousBackend = s.institutionalBackends[msg.sender];
        if (previousBackend != address(0) && previousBackend != backend) {
            emit BackendRevoked(msg.sender, previousBackend);
        }

        s.institutionalBackends[msg.sender] = backend;
        emit BackendAuthorized(msg.sender, backend);
    }
    
    /// @notice Revoke backend authorization
    function revokeBackend() external onlyInstitutionCaller {
        AppStorage storage s = LibAppStorage.diamondStorage();
        address previousBackend = s.institutionalBackends[msg.sender];
        require(previousBackend != address(0), "No backend to revoke");
        delete s.institutionalBackends[msg.sender];
        emit BackendRevoked(msg.sender, previousBackend);
    }

    /// @notice Emergency admin path to reset or assign institutional backend
    /// @param institution The institution whose backend is being updated
    /// @param newBackend Optional new backend address (set to address(0) to just clear)
    function adminResetBackend(address institution, address newBackend) external {
        _requireDefaultAdmin(msg.sender);
        _requireInstitution(institution);

        AppStorage storage s = LibAppStorage.diamondStorage();
        address previousBackend = s.institutionalBackends[institution];

        if (previousBackend != address(0)) {
            delete s.institutionalBackends[institution];
            emit BackendRevoked(institution, previousBackend);
        }

        if (newBackend != address(0)) {
            s.institutionalBackends[institution] = newBackend;
            emit BackendAuthorized(institution, newBackend);
        }
    }
    /// @notice Deposit tokens to the institution's institutional treasury (global)
    /// @dev Institution must approve tokens before calling this function
    /// @param amount Amount of tokens to deposit
    /// @custom:security nonReentrant modifier protects against reentrancy attacks
    function depositToInstitutionalTreasury(uint256 amount) external nonReentrant onlyInstitutionCaller {
        AppStorage storage s = LibAppStorage.diamondStorage();
        require(amount > 0, "Amount must be > 0");
        
        // Transfer tokens from institution to Diamond contract using SafeERC20
        IERC20(s.labTokenAddress).safeTransferFrom(msg.sender, address(this), amount);
        
        s.institutionalTreasury[msg.sender] += amount;
        emit InstitutionalTreasuryDeposit(msg.sender, amount, s.institutionalTreasury[msg.sender]);
    }

    /// @notice Withdraw tokens from the institution's institutional treasury
    /// @dev Allows institution to retrieve unspent funds from their treasury
    /// @param amount Amount of tokens to withdraw
    /// @custom:security nonReentrant modifier protects against reentrancy attacks
    function withdrawFromInstitutionalTreasury(uint256 amount) external nonReentrant onlyInstitutionCaller {
        AppStorage storage s = LibAppStorage.diamondStorage();
        require(amount > 0, "Amount must be > 0");
        require(s.institutionalTreasury[msg.sender] >= amount, "Insufficient treasury balance");
        
        s.institutionalTreasury[msg.sender] -= amount;
        
        // Transfer tokens back to institution using SafeERC20
        IERC20(s.labTokenAddress).safeTransfer(msg.sender, amount);
        
        emit InstitutionalTreasuryWithdrawal(msg.sender, amount, s.institutionalTreasury[msg.sender]);
    }

    /// @notice Set the spending limit per institutional user (global for institution)
    /// @param limit The maximum amount a user can spend per period
    function setInstitutionalUserLimit(uint256 limit) external onlyInstitutionCaller {
        AppStorage storage s = LibAppStorage.diamondStorage();
        require(limit > 0, "Limit must be > 0");
        s.institutionalUserLimit[msg.sender] = limit;
        emit InstitutionalUserLimitUpdated(msg.sender, limit);
    }
    
    /// @notice Set the spending period duration for institutional users
    /// @param periodDuration The duration of the spending period in seconds (e.g., 30 days = 2592000)
    /// @dev Common values: 1 day = 86400, 7 days = 604800, 30 days = 2592000, 1 year = 31536000
    function setInstitutionalSpendingPeriod(uint256 periodDuration) external onlyInstitutionCaller {
        AppStorage storage s = LibAppStorage.diamondStorage();
        require(periodDuration > 0, "Period must be > 0");
        require(periodDuration <= 365 days, "Period too long");
        s.institutionalSpendingPeriod[msg.sender] = periodDuration;
        emit InstitutionalSpendingPeriodUpdated(msg.sender, periodDuration);
    }

    /// @notice Restart the spending period counting window from now without changing its duration
    /// @dev Sets an institution-specific anchor so that the current period starts at the timestamp of this call
    function resetInstitutionalSpendingPeriod() external onlyInstitutionCaller {
        AppStorage storage s = LibAppStorage.diamondStorage();
        uint256 newPeriodStart = block.timestamp;
        s.institutionalSpendingPeriodAnchor[msg.sender] = newPeriodStart;
        emit InstitutionalSpendingPeriodReset(msg.sender, newPeriodStart);
    }

    /// @notice Checks if the institutional treasury has sufficient balance and user hasn't exceeded spending limit
    /// @dev View function that verifies availability without modifying state
    ///      Used in lazy payment pattern to verify before creating reservation request
    /// @param institution The institution who owns the treasury
    /// @param puc The schacPersonalUniqueCode of the user
    /// @param amount Amount to check
    /// @custom:throws Reverts if backend not authorized, treasury insufficient, or user exceeds limit
    function checkInstitutionalTreasuryAvailability(address institution, string calldata puc, uint256 amount) 
        external 
        view
    {
        AppStorage storage s = LibAppStorage.diamondStorage();
        _requireInstitution(institution);
        
        if (msg.sender != address(this)) {
            require(s.institutionalBackends[institution] != address(0), "No authorized backend");
            require(msg.sender == s.institutionalBackends[institution], "Not authorized: must be backend");
        }
        
        // Allow zero-price reservations (free labs)
        if (amount == 0) return;
        
        require(s.institutionalTreasury[institution] >= amount, "Insufficient treasury balance");
        
        // Calculate current period
        uint256 periodDuration = _getSpendingPeriod(institution);
        InstitutionalUserSpending storage spending = s.institutionalUserSpending[institution][puc];
        uint256 currentPeriodStart = _currentPeriodStart(institution, periodDuration);
        
        // Check if we're in a new period (spending would be reset to 0)
        uint256 currentSpending = 0;
        if (spending.periodStart == currentPeriodStart && spending.periodStart != 0) {
            currentSpending = spending.amount;
        }
        
        uint256 newSpent = currentSpending + amount;
        require(newSpent <= _getSpendingLimit(institution), "User spending limit exceeded for period");
    }

    /// @notice Spend tokens from the institution's institutional treasury as an institutional user
    /// @dev Only callable by the institution's authorized backend
    ///      This function marks the spending for accounting purposes with automatic period reset.
    ///      The actual token transfer must be coordinated with WalletReservationFacet, InstitutionalReservationFacet or other payment mechanisms.
    ///      Tokens remain in Diamond contract until explicitly transferred by another facet.
    ///      Spending resets automatically when a new period begins.
    /// @param institution The institution who owns the treasury
    /// @param puc The schacPersonalUniqueCode of the user
    /// @param amount Amount to spend (mark as spent for this user in current period)
    function spendFromInstitutionalTreasury(address institution, string calldata puc, uint256 amount) 
        external 
        onlyAuthorizedBackendOrInternal(institution) 
    {
        AppStorage storage s = LibAppStorage.diamondStorage();
        _requireInstitution(institution);
        
        // Allow zero-price reservations (free labs) - skip all accounting for free reservations
        if (amount == 0) return;
        
        require(s.institutionalTreasury[institution] >= amount, "Insufficient treasury balance");
        
        // Check period and reset if needed
        uint256 periodStart = _checkAndResetPeriod(institution, puc);
        
        // Get current spending in this period
        InstitutionalUserSpending storage spending = s.institutionalUserSpending[institution][puc];
        uint256 newSpent = spending.amount + amount;
        
        require(newSpent <= _getSpendingLimit(institution), "User spending limit exceeded for period");
        
        s.institutionalTreasury[institution] -= amount;
        spending.amount = newSpent;
        
        // Track total historical spending (never reset, used for refunds)
        spending.totalHistoricalSpent += amount;
        
        emit InstitutionalUserSpent(institution, puc, amount, newSpent, periodStart);
    }

    /// @notice Refund tokens back to the institution's institutional treasury (e.g., when canceling a reservation)
    /// @dev Only WalletReservationFacet or InstitutionalReservationFacet can call this via cancelBooking/cancelInstitutionalBooking
    ///      This reverses a previous spend, incrementing treasury and decrementing user's spent amount
    ///      Allows refunds from past periods
    /// @param institution The institution who owns the treasury
    /// @param puc The schacPersonalUniqueCode of the user
    /// @param amount Amount to refund
    function refundToInstitutionalTreasury(address institution, string calldata puc, uint256 amount) 
        external 
    {
        // Prevent compromised backends from calling this function arbitrarily
        require(msg.sender == address(this), "Only internal Diamond calls");
        
        AppStorage storage s = LibAppStorage.diamondStorage();
        _requireInstitution(institution);
        
        // Allow zero-price refunds (free labs) - nothing to refund
        if (amount == 0) return;
        
        InstitutionalUserSpending storage spending = s.institutionalUserSpending[institution][puc];
        
        // Use totalHistoricalSpent for validation (never reset across periods)
        // This allows refunds for bookings made in previous periods
        require(spending.totalHistoricalSpent >= amount, "Refund exceeds total spent amount");
        
        s.institutionalTreasury[institution] += amount;
        
        // Always decrement totalHistoricalSpent (tracks all-time spending)
        spending.totalHistoricalSpent -= amount;
        
        // Check if we're in the same period as when the spend was tracked
        // Only decrement current period amount if refund doesn't exceed it
        // (prevents underflow when refunding old-period bookings after rollover)
        if (spending.amount >= amount) {
            spending.amount -= amount;
        }
        
        // Get current period for event logging
        uint256 periodDuration = _getSpendingPeriod(institution);
        uint256 currentPeriodStart = _currentPeriodStart(institution, periodDuration);
        
        emit InstitutionalUserSpent(institution, puc, 0, spending.amount, currentPeriodStart); // Emit with 0 to indicate refund
    }

    /// @notice Get institution's institutional treasury balance
    function getInstitutionalTreasuryBalance(address institution) external view returns (uint256) {
        AppStorage storage s = LibAppStorage.diamondStorage();
        return s.institutionalTreasury[institution];
    }

    /// @notice Get institutional user's spent amount in current period
    /// @param institution The institution who owns the treasury
    /// @param puc The user's schacPersonalUniqueCode
    /// @return The amount spent in the current period
    function getInstitutionalUserSpent(address institution, string calldata puc) external view returns (uint256) {
        AppStorage storage s = LibAppStorage.diamondStorage();
        uint256 periodDuration = _getSpendingPeriod(institution);
        uint256 currentPeriodStart = _currentPeriodStart(institution, periodDuration);
        
        InstitutionalUserSpending storage spending = s.institutionalUserSpending[institution][puc];
        
        // If stored period doesn't match current period, spending is 0 (would be reset on next write)
        if (spending.periodStart != currentPeriodStart) {
            return 0;
        }
        
        return spending.amount;
    }
    
    /// @notice Get institutional user's spending data (amount and period start)
    /// @param institution The institution who owns the treasury
    /// @param puc The user's schacPersonalUniqueCode
    /// @return amount The amount spent in the current period
    /// @return periodStart The start timestamp of the current period
    function getInstitutionalUserSpendingData(address institution, string calldata puc) external view returns (uint256 amount, uint256 periodStart) {
        AppStorage storage s = LibAppStorage.diamondStorage();
        uint256 periodDuration = _getSpendingPeriod(institution);
        uint256 currentPeriodStart = _currentPeriodStart(institution, periodDuration);
        
        InstitutionalUserSpending storage spending = s.institutionalUserSpending[institution][puc];
        
        // If stored period doesn't match current period, spending is 0 (would be reset on next write)
        if (spending.periodStart != currentPeriodStart) {
            return (0, currentPeriodStart);
        }
        
        return (spending.amount, spending.periodStart);
    }

    /// @notice Get institutional user spending limit
    function getInstitutionalUserLimit(address institution) external view returns (uint256) {
        return _getSpendingLimit(institution);
    }
    
    /// @notice Get the spending period duration for an institution
    /// @param institution The institution address
    /// @return The spending period duration in seconds (default: 30 days if not set)
    function getInstitutionalSpendingPeriod(address institution) external view returns (uint256) {
        return _getSpendingPeriod(institution);
    }
    
    /// @notice Get the authorized backend for an institution
    /// @param institution The institution address
    /// @return The authorized backend address (or address(0) if none)
    function getAuthorizedBackend(address institution) external view returns (address) {
        AppStorage storage s = LibAppStorage.diamondStorage();
        return s.institutionalBackends[institution];
    }
    
    /// @notice Get remaining spending allowance for an institutional user in current period
    /// @param institution The institution who owns the treasury
    /// @param puc The schacPersonalUniqueCode of the user
    /// @return The remaining amount the user can spend in the current period
    function getInstitutionalUserRemainingAllowance(address institution, string calldata puc) external view returns (uint256) {
        AppStorage storage s = LibAppStorage.diamondStorage();
        uint256 limit = _getSpendingLimit(institution);
        uint256 periodDuration = _getSpendingPeriod(institution);
        uint256 currentPeriodStart = _currentPeriodStart(institution, periodDuration);
        
        InstitutionalUserSpending storage spending = s.institutionalUserSpending[institution][puc];
        
        // If stored period doesn't match current period, full limit is available
        if (spending.periodStart != currentPeriodStart) {
            return limit;
        }
        
        uint256 spent = spending.amount;
        return limit > spent ? limit - spent : 0;
    }

    /// @notice Get comprehensive financial statistics for an institutional user
    /// @dev Provides all financial metrics needed for user dashboard in a single call
    /// @param institution The institution who owns the treasury
    /// @param puc The schacPersonalUniqueCode of the institutional user
    /// @return currentPeriodSpent Amount spent in the current period
    /// @return totalHistoricalSpent Total amount ever spent (across all periods)
    /// @return spendingLimit Maximum allowed spending per period
    /// @return remainingAllowance Amount remaining in current period
    /// @return periodStart Start timestamp of the current period
    /// @return periodEnd End timestamp of the current period (periodStart + duration)
    /// @return periodDuration Duration of each spending period in seconds
    function getInstitutionalUserFinancialStats(
        address institution,
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
        spendingLimit = _getSpendingLimit(institution);
        periodDuration = _getSpendingPeriod(institution);
        
        // Calculate current period boundaries
        periodStart = _currentPeriodStart(institution, periodDuration);
        periodEnd = periodStart + periodDuration;
        
        // Get user spending data
        InstitutionalUserSpending storage spending = s.institutionalUserSpending[institution][puc];
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
