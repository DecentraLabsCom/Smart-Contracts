// SPDX-License-Identifier: GPL-3.0-or-later
pragma solidity ^0.8.23;

import {AccessControlUpgradeable} from "@openzeppelin/contracts-upgradeable/access/AccessControlUpgradeable.sol";
import {LibAppStorage, AppStorage, PROVIDER_ROLE, INSTITUTION_ROLE, Provider, ProviderBase} from "../libraries/LibAppStorage.sol";
import {EnumerableSet} from "@openzeppelin/contracts/utils/structs/EnumerableSet.sol";
import {LibDiamond} from "../libraries/LibDiamond.sol";
import {LibAccessControlEnumerable} from "../libraries/LibAccessControlEnumerable.sol";
import {LabERC20} from "../external/LabERC20.sol"; // Import the LabERC20 contract, no yet implemented

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
    using EnumerableSet for EnumerableSet.AddressSet;

    /// @dev Represents the initial amount of LAB tokens minted to new providers.
    /// Total: 1000 tokens (1,000,000,000 units with 6 decimals)
    /// Distribution: 800 tokens automatically staked + 200 tokens to institutional treasury
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
    
    /// @dev Emitted when initial institutional treasury is set for a provider
    /// @param provider The address of the provider.
    /// @param amount The amount deposited to institutional treasury.
    /// @param limit The default spending limit per user.
    event InstitutionalTreasuryInitialized(
        address indexed provider,
        uint256 amount,
        uint256 limit
    );

    /// @dev Emitted when a provider authorizes a backend address
    /// @param provider The provider address
    /// @param backend The backend address being authorized
    event BackendAuthorized(address indexed provider, address indexed backend);

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
        _defaultAdminRole();
        _;
    }

    function _defaultAdminRole() internal view {
        require(
            hasRole(DEFAULT_ADMIN_ROLE, msg.sender),
            "Only the default admin can perform this action"
        );
    }

    /// @dev Constructor for the `ProviderFacet` contract.
    /// This constructor is intentionally left empty.
    constructor() {}

    /// @dev Initializes the contract setting up the initial admin role and other parameters.
    /// @notice The caller must be the contract owner.
    /// @param _name The name of the initial admin.
    /// @param _email The email of the initial admin.
    /// @param _country The country of the initial admin.
    /// @param _labErc20 The address of the LabERC20 token contract.
    function initialize(
        string memory _name,
        string memory _email,
        string memory _country,
        address _labErc20
    ) public initializer {
        LibDiamond.enforceIsContractOwner();
        _grantRole(DEFAULT_ADMIN_ROLE, msg.sender);
        _grantRole(PROVIDER_ROLE, msg.sender);
        _grantRole(INSTITUTION_ROLE, msg.sender);
        _s()._addProviderRole(msg.sender, _name, _email, _country);

        _s().DEFAULT_ADMIN_ROLE = DEFAULT_ADMIN_ROLE;
        _s().labTokenAddress = _labErc20;
        _s().labId=0;
    }

    /// @notice Adds a new provider to the system.
    /// @dev Grants the `PROVIDER_ROLE` to the specified account and initializes the provider's details.
    ///      Mints 1000 tokens: 800 to Diamond (automatically staked) + 200 to institutional treasury.
    ///      Sets default institutional user spending limit (10 tokens).
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
        string calldata _name,
        address _account,
        string calldata _email,
        string calldata _country
    ) external defaultAdminRole {
        require(_account != address(0), "Invalid provider address");
        
        // Validate string lengths to prevent DoS attacks
        require(bytes(_name).length > 0 && bytes(_name).length <= 100, "Invalid name length");
        require(bytes(_email).length > 0 && bytes(_email).length <= 100, "Invalid email length");
        require(bytes(_country).length > 0 && bytes(_country).length <= 50, "Invalid country length");
        
        // Check if provider already exists (prevents duplicate additions)
        require(!hasRole(PROVIDER_ROLE, _account), "Provider already exists");
        
        _grantRole(PROVIDER_ROLE, _account);
        _grantRole(INSTITUTION_ROLE, _account);
        _s()._addProviderRole(_account, _name, _email, _country);
        
        // Try to mint initial tokens (1000 total), but don't revert if it fails (e.g., cap reached)
        uint256 treasuryAmount = 200_000_000; // 200 tokens to institutional treasury
        uint256 stakeAmount = 800_000_000;    // 800 tokens to Diamond (staked)
        uint256 totalAmount = treasuryAmount + stakeAmount;

        bool canMintProvider = _s().providerPoolMinted + totalAmount <= LibAppStorage.PROVIDER_POOL_CAP;
        
        if (canMintProvider) {
        try LabERC20(_s().labTokenAddress).mint(address(this), treasuryAmount) {
            // Mint staked tokens directly to Diamond contract
            try LabERC20(_s().labTokenAddress).mint(address(this), stakeAmount) {
                // Mark that this provider received initial tokens (required for staking)
                _s().providerStakes[_account].receivedInitialTokens = true;
                
                // Register the auto-staked amount and timestamp (for 180-day lock)
                _s().providerStakes[_account].stakedAmount = stakeAmount;
                _s().providerStakes[_account].initialStakeTimestamp = block.timestamp;
                
                // Deposit the 200 tokens to institutional treasury
                _s().institutionalTreasury[_account] = treasuryAmount;

                // Track minted provider pool
                _s().providerPoolMinted += totalAmount;
                
                // Set default institutional user spending limit (tokens per period)
                _s().institutionalUserLimit[_account] = LibAppStorage.DEFAULT_INSTITUTIONAL_USER_LIMIT;
                
                // Set default spending period
                _s().institutionalSpendingPeriod[_account] = LibAppStorage.DEFAULT_SPENDING_PERIOD;
                
                // Auto-authorize provider address as backend for institutional treasury
                _s().institutionalBackends[_account] = _account;
                
                emit InstitutionalTreasuryInitialized(
                    _account, 
                    treasuryAmount, 
                    LibAppStorage.DEFAULT_INSTITUTIONAL_USER_LIMIT
                );
                
                emit BackendAuthorized(_account, _account);
                
                emit ProviderAdded(_account, _name, _email, _country);
            } catch {
                // If stake mint fails, revert the treasury mint too
                revert("Failed to mint stake tokens");
            }
        } catch Error(string memory reason) {
            // Provider added without tokens (no staking requirement)
            // IMPORTANT: Still initialize institutional treasury configuration
            // even if minting fails, so provider can configure it manually later
            _s().providerStakes[_account].receivedInitialTokens = false;
            
            // Initialize institutional treasury with zero balance but valid configuration
            _s().institutionalTreasury[_account] = 0;
            
            // Set default institutional user spending limit (tokens per period)
            _s().institutionalUserLimit[_account] = LibAppStorage.DEFAULT_INSTITUTIONAL_USER_LIMIT;
            
            // Set default spending period
            _s().institutionalSpendingPeriod[_account] = LibAppStorage.DEFAULT_SPENDING_PERIOD;
            
            // Auto-authorize provider address as backend for institutional treasury
            // This allows provider to configure their institutional system even without initial tokens
            _s().institutionalBackends[_account] = _account;
            
            emit InstitutionalTreasuryInitialized(
                _account, 
                0, // zero balance but valid configuration
                LibAppStorage.DEFAULT_INSTITUTIONAL_USER_LIMIT
            );
            
            emit BackendAuthorized(_account, _account);
            
            emit ProviderAddedWithoutTokens(_account, reason);
        } catch {
            // Provider added without tokens (no staking requirement)
            // IMPORTANT: Still initialize institutional treasury configuration
            _s().providerStakes[_account].receivedInitialTokens = false;
            
            // Initialize institutional treasury with zero balance but valid configuration
            _s().institutionalTreasury[_account] = 0;
            
            // Set default institutional user spending limit
            _s().institutionalUserLimit[_account] = LibAppStorage.DEFAULT_INSTITUTIONAL_USER_LIMIT;
            
            // Set default spending period
            _s().institutionalSpendingPeriod[_account] = LibAppStorage.DEFAULT_SPENDING_PERIOD;
            
            // Auto-authorize provider address as backend
            _s().institutionalBackends[_account] = _account;
            
            emit InstitutionalTreasuryInitialized(_account, 0, LibAppStorage.DEFAULT_INSTITUTIONAL_USER_LIMIT);
            emit BackendAuthorized(_account, _account);
            
            emit ProviderAddedWithoutTokens(_account, "Token minting failed: supply cap reached or other error");
        }
        } else {
            // Not enough tokens left in provider pool cap, add provider without tokens
            _s().providerStakes[_account].receivedInitialTokens = false;
            _s().institutionalTreasury[_account] = 0;
            _s().institutionalUserLimit[_account] = LibAppStorage.DEFAULT_INSTITUTIONAL_USER_LIMIT;
            _s().institutionalSpendingPeriod[_account] = LibAppStorage.DEFAULT_SPENDING_PERIOD;
            _s().institutionalBackends[_account] = _account;

            emit InstitutionalTreasuryInitialized(
                _account, 
                0, 
                LibAppStorage.DEFAULT_INSTITUTIONAL_USER_LIMIT
            );
            
            emit BackendAuthorized(_account, _account);
            
            emit ProviderAddedWithoutTokens(_account, "Provider pool exhausted");
        }
    }

    /// @notice Removes a provider from the system by revoking their PROVIDER_ROLE.
    /// @dev This function can only be called by an account with the DEFAULT_ADMIN_ROLE.
    ///      Burns all staked tokens but keeps institutional configuration untouched.
    ///      If the provider does not have the PROVIDER_ROLE, the transaction reverts with an error.
    ///      Emits a `ProviderRemoved` event upon successful removal.
    /// @param _provider The address of the provider to be removed.
    function removeProvider(
        address _provider
    ) external onlyRole(DEFAULT_ADMIN_ROLE) {
        // Check if provider exists (prevents removing non-existent providers)
        require(hasRole(PROVIDER_ROLE, _provider), "Provider does not exist");
        
        _revokeRole(PROVIDER_ROLE, _provider);
        AppStorage storage s = _s();
        
        // Burn staked tokens
        uint256 stakedAmount = s.providerStakes[_provider].stakedAmount;
        if (stakedAmount > 0) {
            s.providerStakes[_provider].stakedAmount = 0;
            LabERC20(s.labTokenAddress).burn(stakedAmount);
        }
        
        // Clean up stake data
        delete s.providerStakes[_provider];
        
        s._removeProviderRole(_provider);
        emit ProviderRemoved(_provider);
    }

    /// @notice Updates the provider information for the caller.
    /// @dev This function allows a provider to update their name, email, and country.
    ///      Only accounts with the `PROVIDER_ROLE` can call this function.
    /// @param _name The updated name of the provider.
    /// @param _email The updated email address of the provider.
    /// @param _country The updated country of the provider.
    function updateProvider(
        string calldata _name,
        string calldata _email,
        string calldata _country
    ) external onlyRole(PROVIDER_ROLE) {
        _s().providers[msg.sender] = ProviderBase({name: _name, email: _email, country: _country});
        emit ProviderUpdated(msg.sender, _name, _email, _country);
    }

    /// @notice Checks if the given account is a Lab provider.
    /// @param _account The address of the account to check.
    /// @return A boolean indicating whether the account is a Lab provider.
    function isLabProvider(address _account) external view returns (bool) {
        return _s()._isLabProvider(_account);
    }

    /// @notice Retrieves the list of all Lab providers (limited to first 100)
    /// @return An array of Provider structs (max 100)
    function getLabProviders() external view returns (Provider[] memory) {
        return _s()._getLabProvidersLimited(100);
    }

    /// @notice Retrieves a paginated list of Lab providers
    /// @dev Allows efficient querying of providers in chunks to avoid gas limits
    /// @param offset Starting index (0-based)
    /// @param limit Maximum number of providers to return (1-100)
    /// @return providers Array of Provider structs for the requested page
    /// @return total Total number of providers in the system
    /// @custom:example getLabProvidersPaginated(0, 50) returns first 50 providers
    ///                 getLabProvidersPaginated(50, 50) returns providers 50-99
    function getLabProvidersPaginated(uint256 offset, uint256 limit) 
        external view returns (Provider[] memory providers, uint256 total) 
    {
        return _s()._getLabProvidersPaginated(offset, limit);
    }

    function _grantRole(bytes32 role, address account) internal virtual override {
        super._grantRole(role, account);
        _s().roleMembers[role].add(account);
    }

    function _revokeRole(bytes32 role, address account) internal virtual override {
        super._revokeRole(role, account);
        _s().roleMembers[role].remove(account);
    }

    /// @dev Internal pure function to retrieve the application storage structure.
    ///      This function provides access to the `AppStorage` instance by calling
    ///      the `diamondStorage` function from the `LibAppStorage` library.
    /// @return s The storage instance of type `AppStorage`.
    function _s() internal pure returns (AppStorage storage s) {
        return LibAppStorage.diamondStorage();
    }
}
