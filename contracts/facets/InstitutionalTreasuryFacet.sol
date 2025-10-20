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
    
    /// @notice Emitted when institutional user spending limit is updated
    event InstitutionalUserLimitUpdated(address indexed provider, uint256 newLimit);
    
    /// @notice Emitted when an institutional user spends tokens
    event InstitutionalUserSpent(address indexed provider, string puc, uint256 amount, uint256 totalSpent);
    
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

    /// @notice Set the spending limit per institutional user (global for provider)
    /// @param limit The maximum amount a user can spend
    function setInstitutionalUserLimit(uint256 limit) external {
        AppStorage storage s = LibAppStorage.diamondStorage();
        require(limit > 0, "Limit must be > 0");
        s.institutionalUserLimit[msg.sender] = limit;
        emit InstitutionalUserLimitUpdated(msg.sender, limit);
    }

    /// @notice Spend tokens from the provider's institutional treasury as an institutional user
    /// @dev Only callable by the provider's authorized backend
    /// @param provider The provider who owns the treasury
    /// @param puc The schacPersonalUniqueCode of the user
    /// @param amount Amount to spend
    function spendFromInstitutionalTreasury(address provider, string calldata puc, uint256 amount) 
        external 
        onlyAuthorizedBackend(provider) 
    {
        AppStorage storage s = LibAppStorage.diamondStorage();
        require(amount > 0, "Amount must be > 0");
        require(s.institutionalTreasury[provider] >= amount, "Insufficient treasury balance");
        
        uint256 newSpent = s.institutionalUserSpent[provider][puc] + amount;
        require(newSpent <= s.institutionalUserLimit[provider], "User spending limit exceeded");
        
        s.institutionalTreasury[provider] -= amount;
        s.institutionalUserSpent[provider][puc] = newSpent;
        
        emit InstitutionalUserSpent(provider, puc, amount, newSpent);
        
        // Optionally: transfer tokens to destination, burn, or mark as spent
    }

    /// @notice Get provider's institutional treasury balance
    function getInstitutionalTreasuryBalance(address provider) external view returns (uint256) {
        AppStorage storage s = LibAppStorage.diamondStorage();
        return s.institutionalTreasury[provider];
    }

    /// @notice Get institutional user's spent amount
    function getInstitutionalUserSpent(address provider, string calldata puc) external view returns (uint256) {
        AppStorage storage s = LibAppStorage.diamondStorage();
        return s.institutionalUserSpent[provider][puc];
    }

    /// @notice Get institutional user spending limit
    function getInstitutionalUserLimit(address provider) external view returns (uint256) {
        AppStorage storage s = LibAppStorage.diamondStorage();
        return s.institutionalUserLimit[provider];
    }
    
    /// @notice Get the authorized backend for a provider
    /// @param provider The provider address
    /// @return The authorized backend address (or address(0) if none)
    function getAuthorizedBackend(address provider) external view returns (address) {
        AppStorage storage s = LibAppStorage.diamondStorage();
        return s.institutionalBackends[provider];
    }
    
    /// @notice Get remaining spending allowance for an institutional user
    /// @param provider The provider who owns the treasury
    /// @param puc The schacPersonalUniqueCode of the user
    /// @return The remaining amount the user can spend
    function getInstitutionalUserRemainingAllowance(address provider, string calldata puc) external view returns (uint256) {
        AppStorage storage s = LibAppStorage.diamondStorage();
        uint256 limit = s.institutionalUserLimit[provider];
        uint256 spent = s.institutionalUserSpent[provider][puc];
        return limit > spent ? limit - spent : 0;
    }
}
