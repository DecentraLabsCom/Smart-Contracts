// SPDX-License-Identifier: GPL-2.0-or-later
pragma solidity ^0.8.23;

import "@openzeppelin/contracts-upgradeable/access/AccessControlUpgradeable.sol";
import {LibAppStorage, AppStorage, PROVIDER_ROLE} from "../libraries/LibAppStorage.sol";
import "../libraries/LibDiamond.sol";
import "../external/LabERC20.sol";

/// @title StakingFacet Contract
/// @author Luis de la Torre Cubillo
/// @author Juan Luis Ramos Villalón
/// @notice Manages provider token staking for service quality assurance
/// @dev Implements staking, slashing, and unstaking mechanisms for providers
/// @custom:security Providers must stake tokens to offer services, stakes can be slashed for misconduct
contract StakingFacet is AccessControlUpgradeable {
    
    /// @notice Minimum stake required for providers who received initial tokens (90% of 1000 = 900 tokens)
    uint256 public constant REQUIRED_STAKE = 900_000_000; // 900 tokens with 6 decimals
    
    /// @notice Lock period after last reservation (15 days)
    uint256 public constant LOCK_PERIOD = 15 days;
    
    /// @notice Emitted when a provider stakes tokens
    /// @param provider The address of the provider
    /// @param amount The amount of tokens staked
    /// @param newTotalStake The total amount staked by the provider after this operation
    event TokensStaked(
        address indexed provider, 
        uint256 amount, 
        uint256 newTotalStake
    );
    
    /// @notice Emitted when a provider unstakes tokens
    /// @param provider The address of the provider
    /// @param amount The amount of tokens unstaked
    /// @param remainingStake The remaining staked amount
    event TokensUnstaked(
        address indexed provider, 
        uint256 amount, 
        uint256 remainingStake
    );
    
    /// @notice Emitted when a provider is slashed for misconduct
    /// @param provider The address of the provider being slashed
    /// @param amount The amount of tokens slashed
    /// @param reason The reason for the slash
    /// @param remainingStake The remaining staked amount after slash
    event ProviderSlashed(
        address indexed provider, 
        uint256 amount, 
        string reason,
        uint256 remainingStake
    );
    
    /// @notice Emitted when a provider's stake is burned (e.g., when removed)
    /// @param provider The address of the provider
    /// @param amount The amount of tokens burned
    /// @param reason The reason for burning
    event StakeBurned(
        address indexed provider, 
        uint256 amount, 
        string reason
    );
    
    /// @notice Emitted when the last reservation timestamp is updated
    /// @param provider The address of the provider
    /// @param timestamp The new last reservation timestamp
    event LastReservationUpdated(
        address indexed provider, 
        uint256 timestamp
    );

    /// @dev Modifier to restrict access to functions that can only be executed by accounts
    ///      with the `DEFAULT_ADMIN_ROLE`.
    modifier defaultAdminRole() {
        require(
            hasRole(DEFAULT_ADMIN_ROLE, msg.sender),
            "StakingFacet: caller is not admin"
        );
        _;
    }

    /// @dev Constructor for the StakingFacet contract.
    constructor() {}

    /// @notice Provider stakes tokens to be eligible to offer services
    /// @dev Transfers tokens from provider to this contract
    /// @param amount The amount of tokens to stake
    function stakeTokens(uint256 amount) external onlyRole(PROVIDER_ROLE) {
        require(amount > 0, "StakingFacet: amount must be greater than 0");
        
        AppStorage storage s = _s();
        
        // Transfer tokens from provider to Diamond contract
        LabERC20(s.labTokenAddress).transferFrom(msg.sender, address(this), amount);
        
        s.providerStakes[msg.sender].stakedAmount += amount;
        
        emit TokensStaked(msg.sender, amount, s.providerStakes[msg.sender].stakedAmount);
    }

    /// @notice Provider unstakes tokens after lock period
    /// @dev Can only unstake if lock period has passed since last reservation
    /// @param amount The amount of tokens to unstake
    function unstakeTokens(uint256 amount) external onlyRole(PROVIDER_ROLE) {
        AppStorage storage s = _s();
        
        require(amount > 0, "StakingFacet: amount must be greater than 0");
        require(
            s.providerStakes[msg.sender].stakedAmount >= amount, 
            "StakingFacet: insufficient staked balance"
        );
        
        // Check lock period
        uint256 lastReservation = s.providerStakes[msg.sender].lastReservationTimestamp;
        if (lastReservation > 0) {
            require(
                block.timestamp >= lastReservation + LOCK_PERIOD,
                "StakingFacet: tokens locked, wait for lock period to end"
            );
        }
        
        // Check minimum stake requirement (if provider received initial tokens)
        uint256 remainingStake = s.providerStakes[msg.sender].stakedAmount - amount;
        uint256 requiredStake = getRequiredStake(msg.sender);
        
        require(
            remainingStake >= requiredStake || remainingStake == 0,
            "StakingFacet: cannot unstake below required minimum"
        );
        
        s.providerStakes[msg.sender].stakedAmount = remainingStake;
        
        // Transfer tokens back to provider
        LabERC20(s.labTokenAddress).transfer(msg.sender, amount);
        
        emit TokensUnstaked(msg.sender, amount, remainingStake);
    }

    /// @notice Admin slashes a provider's stake for misconduct
    /// @dev Burns the slashed tokens
    /// @param provider The address of the provider to slash
    /// @param amount The amount of tokens to slash
    /// @param reason The reason for the slash (fraud, abandonment, etc.)
    function slashProvider(
        address provider, 
        uint256 amount, 
        string memory reason
    ) external defaultAdminRole {
        AppStorage storage s = _s();
        
        require(amount > 0, "StakingFacet: amount must be greater than 0");
        require(
            s.providerStakes[provider].stakedAmount >= amount, 
            "StakingFacet: insufficient stake to slash"
        );
        
        s.providerStakes[provider].stakedAmount -= amount;
        s.providerStakes[provider].slashedAmount += amount;
        
        // Burn the slashed tokens
        LabERC20(s.labTokenAddress).burn(amount);
        
        emit ProviderSlashed(
            provider, 
            amount, 
            reason, 
            s.providerStakes[provider].stakedAmount
        );
    }

    /// @notice Burns entire stake when a provider is removed from the system
    /// @dev Called by ProviderFacet when removeProvider is executed
    /// @param provider The address of the provider being removed
    function burnStakeOnRemoval(address provider) external defaultAdminRole {
        AppStorage storage s = _s();
        
        uint256 stakedAmount = s.providerStakes[provider].stakedAmount;
        
        if (stakedAmount > 0) {
            s.providerStakes[provider].stakedAmount = 0;
            
            // Burn all staked tokens
            LabERC20(s.labTokenAddress).burn(stakedAmount);
            
            emit StakeBurned(provider, stakedAmount, "Provider removed from system");
        }
        
        // Clean up stake data
        delete s.providerStakes[provider];
    }

    /// @notice Updates the last reservation timestamp for lock period calculation
    /// @dev Should be called by ReservationFacet when a reservation is completed/cancelled
    /// @param provider The address of the provider
    function updateLastReservation(address provider) external {
        // Only Diamond facets can call this
        require(
            msg.sender == address(this) || hasRole(DEFAULT_ADMIN_ROLE, msg.sender),
            "StakingFacet: caller not authorized"
        );
        
        AppStorage storage s = _s();
        s.providerStakes[provider].lastReservationTimestamp = block.timestamp;
        
        emit LastReservationUpdated(provider, block.timestamp);
    }

    /// @notice Checks if a provider can offer services (has required stake)
    /// @param provider The address of the provider
    /// @return bool True if provider has sufficient stake
    function canProvideService(address provider) external view returns (bool) {
        AppStorage storage s = _s();
        uint256 requiredStake = getRequiredStake(provider);
        return s.providerStakes[provider].stakedAmount >= requiredStake;
    }

    /// @notice Gets the required stake for a provider
    /// @dev Returns 900 tokens if provider received initial tokens, 0 otherwise
    /// @param provider The address of the provider
    /// @return uint256 The required stake amount
    function getRequiredStake(address provider) public view returns (uint256) {
        AppStorage storage s = _s();
        
        // If provider never received initial tokens (added after cap), no stake required
        if (s.providerStakes[provider].receivedInitialTokens == false) {
            return 0;
        }
        
        return REQUIRED_STAKE; // 900 tokens
    }

    /// @notice Gets the current stake information for a provider
    /// @param provider The address of the provider
    /// @return stakedAmount The amount of tokens currently staked
    /// @return slashedAmount The total amount of tokens slashed historically
    /// @return lastReservationTimestamp The timestamp of the last reservation
    /// @return unlockTimestamp The timestamp when tokens can be unstaked
    /// @return canUnstake Whether the provider can currently unstake
    function getStakeInfo(address provider) external view returns (
        uint256 stakedAmount,
        uint256 slashedAmount,
        uint256 lastReservationTimestamp,
        uint256 unlockTimestamp,
        bool canUnstake
    ) {
        AppStorage storage s = _s();
        
        stakedAmount = s.providerStakes[provider].stakedAmount;
        slashedAmount = s.providerStakes[provider].slashedAmount;
        lastReservationTimestamp = s.providerStakes[provider].lastReservationTimestamp;
        
        if (lastReservationTimestamp > 0) {
            unlockTimestamp = lastReservationTimestamp + LOCK_PERIOD;
            canUnstake = block.timestamp >= unlockTimestamp;
        } else {
            unlockTimestamp = 0;
            canUnstake = true;
        }
    }

    /// @dev Internal pure function to retrieve the application storage structure.
    /// @return s The storage instance of type `AppStorage`.
    function _s() internal pure returns (AppStorage storage s) {
        return LibAppStorage.diamondStorage();
    }
}
