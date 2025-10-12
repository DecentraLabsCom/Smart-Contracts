// SPDX-License-Identifier: GPL-2.0-or-later
pragma solidity ^0.8.23;

import "@openzeppelin/contracts-upgradeable/access/AccessControlUpgradeable.sol";
import {LibAppStorage, AppStorage, PROVIDER_ROLE, Provider, ProviderBase} from "../libraries/LibAppStorage.sol";
import "../libraries/LibDiamond.sol";
import {LibAccessControlEnumerable} from "../libraries/LibAccessControlEnumerable.sol";
import "../external/LabERC20.sol"; // Import the LabERC20 contract, no yet implemented

/// @title ProviderFacet Contract
/// @author Juan Luis Ramos Villalón
/// @author Luis de la Torre Cubillo
/// @notice This contract is part of a diamond architecture.
/// @dev This contract manages the providers in the system, allowing for the addition, removal, and updating of provider information.
///      It also includes role-based access control to restrict certain actions to administrators or providers.
///      The contract integrates with the LabERC20 token to mint initial tokens for new providers.
/// @notice The contract uses the Diamond Standard (EIP-2535) for modularity and extensibility, enabling seamless upgrades and modular design.
/// @custom:security Only accounts with the appropriate roles can perform restricted actions.
contract ProviderFacet is AccessControlUpgradeable {
    using LibAccessControlEnumerable for AppStorage;

    /// @dev Represents the initial amount of LAB tokens minted to new providers.
    /// Total: 1000 tokens (1,000,000,000 units with 6 decimals)
    /// Distribution: 100 tokens sent to provider wallet + 900 tokens automatically staked
    uint32 constant INITIAL_LAB_TOKENS = 1000000000;

    /// @dev Emitted when a new provider is added to the system.
    /// @param _account The address of the provider being added.
    /// @param _name The name of the provider.
    /// @param _email The email address of the provider.
    /// @param _country The country of the provider.
    event ProviderAdded(
        address indexed _account,
        string _name,
        string _email,
        string _country
    );

    /// @dev Emitted when a provider is added but initial tokens cannot be minted due to cap
    /// @param _account The address of the provider being added.
    /// @param reason The reason why tokens could not be minted.
    event ProviderAddedWithoutTokens(
        address indexed _account,
        string reason
    );

    /// @dev Emitted when a provider is removed.
    /// @param _account The address of the provider that was removed.
    event ProviderRemoved(address indexed _account);

    /// @dev Emitted when a provider's information is updated.
    /// @param _account The address of the provider.
    /// @param _name The name of the provider.
    /// @param _email The email address of the provider.
    /// @param _country The country of the provider.
    event ProviderUpdated(
        address indexed _account,
        string _name,
        string _email,
        string _country
    );

    /// @dev Modifier to restrict access to functions that can only be executed by accounts
    ///      with the `DEFAULT_ADMIN_ROLE`. Ensures that the caller of the function has the
    ///      required role before proceeding with the execution of the function.
    /// @notice Reverts if the caller does not have the `DEFAULT_ADMIN_ROLE`.
    modifier defaultAdminRole() {
        require(
            hasRole(DEFAULT_ADMIN_ROLE, msg.sender),
            "Only the default admin can perform this action"
        );
        _;
    }

    /// @dev Constructor for the `ProviderFacet` contract.
    /// This constructor is intentionally left empty.
    constructor() {}

    /// @dev Initializes the contract setting up the initial admin role and other parameters.
    /// @notice The caller must be the contract owner.
    /// @param _name The name of the initial admin.
    /// @param _email The email of the initial admin.
    /// @param _country The country of the initial admin.
    /// @param _labERC20 The address of the LabERC20 token contract.
    function initialize(
        string memory _name,
        string memory _email,
        string memory _country,
        address _labERC20
    ) public initializer {
        LibDiamond.enforceIsContractOwner();
        bool granted = _grantRole(DEFAULT_ADMIN_ROLE, msg.sender);
        if (granted) _s()._addProviderRole(msg.sender, _name, _email, _country);

        _s().DEFAULT_ADMIN_ROLE = DEFAULT_ADMIN_ROLE;
        _s().labTokenAddress = _labERC20;
        _s().labId=0;
    }

    /// @notice Adds a new provider to the system.
    /// @dev Grants the `PROVIDER_ROLE` to the specified account and initializes the provider's details.
    ///      Mints 1000 tokens: 100 to provider wallet + 900 to Diamond (automatically staked).
    ///      If minting fails (e.g., supply cap reached), the provider is still added without tokens.
    ///      Marks whether the provider received initial tokens for staking requirements.
    ///      Emits a `ProviderAdded` event upon successful addition with tokens.
    ///      Emits a `ProviderAddedWithoutTokens` event if tokens cannot be minted.
    ///      Reverts if the provider already exists.
    /// @param _name The name of the provider.
    /// @param _account The address of the provider's account.
    /// @param _email The email address of the provider.
    /// @param _country The country of the provider.
    function addProvider(
        string memory _name,
        address _account,
        string memory _email,
        string memory _country
    ) external defaultAdminRole {
        if (_grantRole(PROVIDER_ROLE, _account)) {
            _s()._addProviderRole(_account, _name, _email, _country);
            
            // Try to mint initial tokens (1000 total), but don't revert if it fails (e.g., cap reached)
            uint256 providerAmount = 100_000_000; // 100 tokens to provider wallet
            uint256 stakeAmount = 900_000_000;    // 900 tokens to Diamond (staked)
            
            try LabERC20(_s().labTokenAddress).mint(_account, providerAmount) {
                // Mint staked tokens directly to Diamond contract
                try LabERC20(_s().labTokenAddress).mint(address(this), stakeAmount) {
                    // Mark that this provider received initial tokens (required for staking)
                    _s().providerStakes[_account].receivedInitialTokens = true;
                    
                    // Register the auto-staked amount
                    _s().providerStakes[_account].stakedAmount = stakeAmount;
                    
                    emit ProviderAdded(_account, _name, _email, _country);
                } catch {
                    // If stake mint fails, revert the provider mint too
                    revert("Failed to mint stake tokens");
                }
            } catch Error(string memory reason) {
                // Provider added without tokens (no staking requirement)
                _s().providerStakes[_account].receivedInitialTokens = false;
                emit ProviderAddedWithoutTokens(_account, reason);
            } catch {
                // Provider added without tokens (no staking requirement)
                _s().providerStakes[_account].receivedInitialTokens = false;
                emit ProviderAddedWithoutTokens(_account, "Token minting failed: supply cap reached or other error");
            }
        } else {
            revert("Provider already exists");
        }
    }

    /// @notice Removes a provider from the system by revoking their PROVIDER_ROLE.
    /// @dev This function can only be called by an account with the DEFAULT_ADMIN_ROLE.
    ///      Burns all staked tokens before removal (penalty for removal).
    ///      If the provider does not have the PROVIDER_ROLE, the transaction reverts with an error.
    ///      Emits a `ProviderRemoved` event upon successful removal.
    /// @param _provider The address of the provider to be removed.
    function removeProvider(
        address _provider
    ) external onlyRole(DEFAULT_ADMIN_ROLE) {
        if (_revokeRole(PROVIDER_ROLE, _provider)) {
            // Burn any staked tokens before removing
            uint256 stakedAmount = _s().providerStakes[_provider].stakedAmount;
            if (stakedAmount > 0) {
                _s().providerStakes[_provider].stakedAmount = 0;
                LabERC20(_s().labTokenAddress).burn(stakedAmount);
            }
            
            // Clean up stake data
            delete _s().providerStakes[_provider];
            
            _s()._removeProviderRole(_provider);
            emit ProviderRemoved(_provider);
        } else {
            revert("Provider does not exist");
        }
    }

    /// @notice Updates the provider information for the caller.
    /// @dev This function allows a provider to update their name, email, and country.
    ///      Only accounts with the `PROVIDER_ROLE` can call this function.
    /// @param _name The updated name of the provider.
    /// @param _email The updated email address of the provider.
    /// @param _country The updated country of the provider.
    function updateProvider(
        string memory _name,
        string memory _email,
        string memory _country
    ) external onlyRole(PROVIDER_ROLE) {
        _s().providers[msg.sender] = ProviderBase(_name, _email, _country);
        emit ProviderUpdated(msg.sender, _name, _email, _country);
    }

    /// @notice Checks if the given account is a Lab provider.
    /// @param _account The address of the account to check.
    /// @return A boolean indicating whether the account is a Lab provider.
    function isLabProvider(address _account) external view returns (bool) {
        return _s()._isLabProvider(_account);
    }

    /// @notice Retrieves the list of all Lab providers.
    /// @return An array of LabProviderExt structs representing all Lab providers.
    function getLabProviders() external view returns (Provider[] memory) {
        return _s()._getLabProviders();
    }

    /// @dev Internal pure function to retrieve the application storage structure.
    ///      This function provides access to the `AppStorage` instance by calling
    ///      the `diamondStorage` function from the `LibAppStorage` library.
    /// @return s The storage instance of type `AppStorage`.
    function _s() internal pure returns (AppStorage storage s) {
        return LibAppStorage.diamondStorage();
    }
}
