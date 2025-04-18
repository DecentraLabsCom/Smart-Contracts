// SPDX-License-Identifier: GPL-2.0-or-later
pragma solidity ^0.8.23;

// @title ProviderFacet
// @author
// - Juan Luis Ramos Villalón
// - Luis de la Torre Cubillo
// @dev This contract is a facet of a diamond that handles admin and provider roles.
//      It inherits from AccessControlUpgradeable to manage role-based access control.
//      Ensure to initialize the AccessControlUpgradeable properly when deploying or upgrading.

uint32 constant INITIAL_LAB_TOKENS = 1000;

import "@openzeppelin/contracts-upgradeable/access/AccessControlUpgradeable.sol";
import {LibAppStorage, AppStorage, PROVIDER_ROLE, Provider, ProviderBase} from "../libraries/LibAppStorage.sol";
import "../libraries/LibDiamond.sol";
import {LibAccessControlEnumerable} from "../libraries/LibAccessControlEnumerable.sol";
import "../external/LabERC20.sol"; // Import the LabERC20 contract, no yet implemented

contract ProviderFacet is AccessControlUpgradeable {
    using LibAccessControlEnumerable for AppStorage;

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
    }

    /// @notice Adds a new provider to the system.
    /// @dev Grants the `PROVIDER_ROLE` to the specified account and initializes the provider's details.
    ///      Mints `INITIAL_LAB_TOKENS` LabERC20 tokens to the provider's account upon successful addition.
    ///      Emits a `ProviderAdded` event upon successful addition.
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
            LabERC20(_s().labTokenAddress).mint(_account, INITIAL_LAB_TOKENS);
            emit ProviderAdded(_account, _name, _email, _country);
        } else {
            revert("Provider already exists");
        }
    }

    /// @notice Removes a provider from the system by revoking their PROVIDER_ROLE.
    /// @dev This function can only be called by an account with the DEFAULT_ADMIN_ROLE.
    ///      If the provider does not have the PROVIDER_ROLE, the transaction reverts with an error.
    ///      Emits a `ProviderRemoved` event upon successful removal.
    /// @param _provider The address of the provider to be removed.
    function removeProvider(
        address _provider
    ) external onlyRole(DEFAULT_ADMIN_ROLE) {
        if (_revokeRole(PROVIDER_ROLE, _provider)) {
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
