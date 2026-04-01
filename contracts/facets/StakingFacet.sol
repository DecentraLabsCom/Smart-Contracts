// SPDX-License-Identifier: GPL-3.0-or-later
pragma solidity ^0.8.31;

import {AccessControlUpgradeable} from "@openzeppelin/contracts-upgradeable/access/AccessControlUpgradeable.sol";
import {LibAppStorage, AppStorage, PROVIDER_ROLE, PendingSlash} from "../libraries/LibAppStorage.sol";
import {ReentrancyGuardTransient} from "@openzeppelin/contracts/utils/ReentrancyGuardTransient.sol";
import {ReservableToken} from "../abstracts/ReservableToken.sol";

/// @title StakingFacet Contract
/// @author Luis de la Torre Cubillo
/// @author Juan Luis Ramos Villalón
/// @notice Manages provider token staking for service quality assurance
/// @dev Implements staking, slashing, and unstaking mechanisms for providers
/// @custom:security Providers must stake tokens to offer services, stakes can be slashed for misconduct
contract StakingFacet is AccessControlUpgradeable, ReentrancyGuardTransient {
    /// @notice Lock period after last reservation (30 days)
    uint256 public constant LOCK_PERIOD = 30 days;

    /// @notice Initial stake lock period (180 days from auto-stake)
    uint256 public constant INITIAL_STAKE_LOCK_PERIOD = 180 days;

    /// @notice Maximum slash amount per queued action (20 credits with 5 decimals)
    uint256 public constant MAX_SLASH_AMOUNT = 2_000_000;

    /// @notice Delay before an admin slash can be executed
    uint256 public constant SLASH_TIMELOCK = 48 hours;

    /// @notice Emitted when a provider is slashed for misconduct
    /// @param provider The address of the provider being slashed
    /// @param amount The amount of tokens slashed
    /// @param reason The reason for the slash
    /// @param remainingStake The remaining staked amount after slash
    event ProviderSlashed(address indexed provider, uint256 indexed amount, string reason, uint256 remainingStake);

    /// @notice Emitted when a provider's stake is burned (e.g., when removed)
    /// @param provider The address of the provider
    /// @param amount The amount of tokens burned
    /// @param reason The reason for burning
    event StakeBurned(address indexed provider, uint256 indexed amount, string reason);

    /// @notice Emitted when the last reservation timestamp is updated
    /// @param provider The address of the provider
    /// @param timestamp The new last reservation timestamp
    event LastReservationUpdated(address indexed provider, uint256 timestamp);

    /// @notice Emitted when a provider's stake falls below the required minimum
    /// @dev This event signals that the provider's labs are automatically unlisted
    /// @param provider The address of the provider with insufficient stake
    /// @param remainingStake The current staked amount after the operation
    /// @param requiredStake The minimum required stake (800 credits)
    event ProviderStakeInsufficient(address indexed provider, uint256 remainingStake, uint256 requiredStake);

    /// @notice Emitted when a slash is queued and waiting for timelock
    event SlashQueued(address indexed provider, uint256 amount, uint256 executeAfter, string reason);

    /// @notice Emitted when a queued slash is cancelled
    event SlashCancelled(address indexed provider, address indexed cancelledBy);

    /// @dev Modifier to restrict access to functions that can only be executed by accounts
    ///      with the `DEFAULT_ADMIN_ROLE`.
    modifier onlyDefaultAdminRole() {
        _onlyDefaultAdminRole();
        _;
    }

    function _onlyDefaultAdminRole() internal view {
        require(hasRole(DEFAULT_ADMIN_ROLE, msg.sender), "StakingFacet: caller is not admin");
    }

    /// @dev Constructor for the StakingFacet contract.
    constructor() {}

    /// @notice Updates the last reservation timestamp for lock period calculation
    /// @dev Should be called by reservation facets when a reservation is completed/cancelled
    /// @param provider The address of the provider
    function updateLastReservation(
        address provider
    ) external {
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
    function canProvideService(
        address provider
    ) external view returns (bool) {
        AppStorage storage s = _s();
        uint256 requiredStake = getRequiredStake(provider);
        return s.providerStakes[provider].stakedAmount >= requiredStake;
    }

    /// @notice Gets the required stake for a provider based on listed labs count
    /// @dev Delegates to ReservableToken's calculation logic
    ///      Formula: 800 base + max(0, listedLabs - 10) * 200
    ///      - First 10 labs: 800 credits (included in base)
    ///      - Each additional lab: +200 credits
    /// @param provider The address of the provider
    /// @return uint256 The required stake amount
    function getRequiredStake(
        address provider
    ) public view returns (uint256) {
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
    function getStakeInfo(
        address provider
    )
        external
        view
        returns (
            uint256 stakedAmount,
            uint256 slashedAmount,
            uint256 lastReservationTimestamp,
            uint256 unlockTimestamp,
            bool canUnstake
        )
    {
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
        canUnstake =
            block.timestamp >= initialUnlock && (lastReservationTimestamp == 0 || block.timestamp >= reservationUnlock);
    }

    /// @dev Internal pure function to retrieve the application storage structure.
    /// @return s The storage instance of type `AppStorage`.
    function _s() internal pure returns (AppStorage storage s) {
        return LibAppStorage.diamondStorage();
    }
}
