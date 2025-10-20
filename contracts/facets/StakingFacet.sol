// SPDX-License-Identifier: GPL-3.0-or-later
pragma solidity ^0.8.23;

import "@openzeppelin/contracts-upgradeable/access/AccessControlUpgradeable.sol";
import {LibAppStorage, AppStorage, PROVIDER_ROLE} from "../libraries/LibAppStorage.sol";
import "../libraries/LibDiamond.sol";
import "../external/LabERC20.sol";
import "../abstracts/ReservableToken.sol";

/// @title StakingFacet Contract
/// @author Luis de la Torre Cubillo
/// @author Juan Luis Ramos Villalón
/// @notice Manages provider token staking for service quality assurance
/// @dev Implements staking, slashing, and unstaking mechanisms for providers
/// @custom:security Providers must stake tokens to offer services, stakes can be slashed for misconduct
contract StakingFacet is AccessControlUpgradeable {
    
    /// @notice Lock period after last reservation (30 days)
    uint256 public constant LOCK_PERIOD = 30 days;
    
    /// @notice Initial stake lock period (180 days from auto-stake)
    uint256 public constant INITIAL_STAKE_LOCK_PERIOD = 180 days;
    
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
    
    /// @notice Emitted when a provider's stake falls below the required minimum
    /// @dev This event signals that the provider's labs are automatically unlisted
    /// @param provider The address of the provider with insufficient stake
    /// @param remainingStake The current staked amount after the operation
    /// @param requiredStake The minimum required stake (800 tokens)
    event ProviderStakeInsufficient(
        address indexed provider, 
        uint256 remainingStake, 
        uint256 requiredStake
    );
    
    /// @notice Emitted when a provider's stake reaches or exceeds the required minimum
    /// @dev This event signals that the provider can now list labs
    /// @param provider The address of the provider with sufficient stake
    /// @param newTotalStake The current staked amount after the operation
    /// @param requiredStake The minimum required stake (800 tokens)
    event ProviderStakeSufficient(
        address indexed provider, 
        uint256 newTotalStake, 
        uint256 requiredStake
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
        
        uint256 previousStake = s.providerStakes[msg.sender].stakedAmount;
        uint256 requiredStake = getRequiredStake(msg.sender);
        
        // Transfer tokens from provider to Diamond contract
        LabERC20(s.labTokenAddress).transferFrom(msg.sender, address(this), amount);
        
        // If this is the first stake (no auto-stake), record timestamp
        if (s.providerStakes[msg.sender].initialStakeTimestamp == 0 && previousStake == 0) {
            s.providerStakes[msg.sender].initialStakeTimestamp = block.timestamp;
        }
        
        uint256 newTotalStake = previousStake + amount;
        s.providerStakes[msg.sender].stakedAmount = newTotalStake;
        
        emit TokensStaked(msg.sender, amount, newTotalStake);
        
        // If stake was insufficient but now is sufficient, emit event
        // This signals that provider can now list labs
        if (previousStake < requiredStake && newTotalStake >= requiredStake) {
            emit ProviderStakeSufficient(msg.sender, newTotalStake, requiredStake);
        }
    }

    /// @notice Provider unstakes tokens after lock period
    /// @dev Can only unstake if:
    ///      1. Initial stake lock period (180 days) has passed since auto-stake, AND
    ///      2. Lock period (30 days) has passed since last reservation
    /// @param amount The amount of tokens to unstake
    function unstakeTokens(uint256 amount) external onlyRole(PROVIDER_ROLE) {
        AppStorage storage s = _s();
        
        require(amount > 0, "StakingFacet: amount must be greater than 0");
        require(
            s.providerStakes[msg.sender].stakedAmount >= amount, 
            "StakingFacet: insufficient staked balance"
        );
        
        // Check initial stake lock period (180 days from auto-stake)
        uint256 initialStakeTime = s.providerStakes[msg.sender].initialStakeTimestamp;
        if (initialStakeTime > 0) {
            require(
                block.timestamp >= initialStakeTime + INITIAL_STAKE_LOCK_PERIOD,
                "StakingFacet: initial stake locked for 180 days from provider creation"
            );
        }
        
        // Check lock period (30 days from last reservation)
        uint256 lastReservation = s.providerStakes[msg.sender].lastReservationTimestamp;
        if (lastReservation > 0) {
            require(
                block.timestamp >= lastReservation + LOCK_PERIOD,
                "StakingFacet: tokens locked for 30 days after last reservation"
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
        
        // If stake falls below required minimum, emit warning event
        // This signals that provider's labs are automatically unlisted
        if (remainingStake > 0 && remainingStake < requiredStake) {
            emit ProviderStakeInsufficient(msg.sender, remainingStake, requiredStake);
        }
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
        
        uint256 remainingStake = s.providerStakes[provider].stakedAmount - amount;
        s.providerStakes[provider].stakedAmount = remainingStake;
        s.providerStakes[provider].slashedAmount += amount;
        
        // Burn the slashed tokens
        LabERC20(s.labTokenAddress).burn(amount);
        
        emit ProviderSlashed(
            provider, 
            amount, 
            reason, 
            remainingStake
        );
        
        // If stake falls below required minimum, emit warning event
        uint256 requiredStake = getRequiredStake(provider);
        if (remainingStake > 0 && remainingStake < requiredStake) {
            emit ProviderStakeInsufficient(provider, remainingStake, requiredStake);
        }
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

    /// @notice Gets the required stake for a provider based on listed labs count
    /// @dev Delegates to ReservableToken's calculation logic
    ///      Formula: 800 base + max(0, listedLabs - 10) * 200
    ///      - First 10 labs: 800 tokens (included in base)
    ///      - Each additional lab: +100 tokens
    /// @param provider The address of the provider
    /// @return uint256 The required stake amount
    function getRequiredStake(address provider) public view returns (uint256) {
        AppStorage storage s = _s();
        uint256 listedLabsCount = s.providerStakes[provider].listedLabsCount;
        
        // Call ReservableToken's public function through Diamond proxy
        return ReservableToken(address(this)).calculateRequiredStake(provider, listedLabsCount);
    }

    /// @notice Gets the current stake information for a provider
    /// @param provider The address of the provider
    /// @return stakedAmount The amount of tokens currently staked
    /// @return slashedAmount The total amount of tokens slashed historically
    /// @return lastReservationTimestamp The timestamp of the last reservation
    /// @return unlockTimestamp The timestamp when tokens can be unstaked (latest of both locks)
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
        
        // Calculate unlock timestamp as the latest of:
        // 1. Initial stake lock (180 days from auto-stake)
        // 2. Reservation lock (30 days from last reservation)
        uint256 initialUnlock = 0;
        uint256 reservationUnlock = 0;
        
        if (s.providerStakes[provider].initialStakeTimestamp > 0) {
            initialUnlock = s.providerStakes[provider].initialStakeTimestamp + INITIAL_STAKE_LOCK_PERIOD;
        }
        
        if (lastReservationTimestamp > 0) {
            reservationUnlock = lastReservationTimestamp + LOCK_PERIOD;
        }
        
        // Take the latest unlock time
        unlockTimestamp = initialUnlock > reservationUnlock ? initialUnlock : reservationUnlock;
        
        // Can unstake if both locks have expired
        canUnstake = block.timestamp >= initialUnlock && 
                     (lastReservationTimestamp == 0 || block.timestamp >= reservationUnlock);
    }

    /// @dev Internal pure function to retrieve the application storage structure.
    /// @return s The storage instance of type `AppStorage`.
    function _s() internal pure returns (AppStorage storage s) {
        return LibAppStorage.diamondStorage();
    }
}
