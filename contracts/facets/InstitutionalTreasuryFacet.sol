// SPDX-License-Identifier: GPL-3.0-or-later
pragma solidity ^0.8.23;

import {LibAppStorage, AppStorage} from "../libraries/LibAppStorage.sol";
import "../external/LabERC20.sol";

/// @title InstitutionalTreasuryFacet Contract
/// @author Luis de la Torre Cubillo
/// @author Juan Luis Ramos Villalón
/// @notice Allows providers to assign and manage token balances for institutional users (SAML2 schacPersonalUniqueCode)
/// @dev Uses LabERC20 token for deposits and spending
contract InstitutionalTreasuryFacet {
    /// @notice Deposit tokens to the provider's institutional treasury (global)
    /// @param amount Amount of tokens to deposit
    function depositToInstitutionalTreasury(uint256 amount) external {
        AppStorage storage s = LibAppStorage.diamondStorage();
        require(amount > 0, "Amount must be > 0");
        LabERC20(s.labTokenAddress).transferFrom(msg.sender, address(this), amount);
        s.institutionalTreasury[msg.sender] += amount;
    }

    /// @notice Set the spending limit per institutional user (global for provider)
    /// @param limit The maximum amount a user can spend
    function setInstitutionalUserLimit(uint256 limit) external {
        AppStorage storage s = LibAppStorage.diamondStorage();
        require(limit > 0, "Limit must be > 0");
        s.institutionalUserLimit[msg.sender] = limit;
    }

    /// @notice Spend tokens from the provider's institutional treasury as an institutional user
    /// @param provider The provider who owns the treasury
    /// @param puc The schacPersonalUniqueCode of the user
    /// @param amount Amount to spend
    function spendFromInstitutionalTreasury(address provider, string calldata puc, uint256 amount) external {
        AppStorage storage s = LibAppStorage.diamondStorage();
        require(amount > 0, "Amount must be > 0");
        require(s.institutionalTreasury[provider] >= amount, "Insufficient treasury balance");
        require(s.institutionalUserSpent[provider][puc] + amount <= s.institutionalUserLimit[provider], "User spending limit exceeded");
        s.institutionalTreasury[provider] -= amount;
        s.institutionalUserSpent[provider][puc] += amount;
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
}
