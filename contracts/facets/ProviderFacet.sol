// SPDX-License-Identifier: GPL-3.0-or-later
pragma solidity ^0.8.31;

import {AccessControlUpgradeable} from "@openzeppelin/contracts-upgradeable/access/AccessControlUpgradeable.sol";
import {
    LibAppStorage,
    AppStorage,
    PROVIDER_ROLE,
    INSTITUTION_ROLE,
    Provider,
    ProviderBase,
    ProviderNetworkStatus
} from "../libraries/LibAppStorage.sol";
import {EnumerableSet} from "@openzeppelin/contracts/utils/structs/EnumerableSet.sol";
import {LibDiamond} from "../libraries/LibDiamond.sol";
import {ReentrancyGuardTransient} from "@openzeppelin/contracts/utils/ReentrancyGuardTransient.sol";
import {LibAccessControlEnumerable} from "../libraries/LibAccessControlEnumerable.sol";

/// @title ProviderFacet Contract
/// @author Juan Luis Ramos Villalón
/// @author Luis de la Torre Cubillo
/// @notice This contract is part of a diamond architecture.
/// @dev This contract manages the providers in the system, allowing for the addition, removal, and updating of provider information.
///      It also includes role-based access control to restrict certain actions to administrators or providers.
///      Provider onboarding now issues non-monetary service credits instead of ERC-20 tokens.
/// @notice The contract uses the Diamond Standard (EIP-2535) for modularity and extensibility, enabling seamless upgrades and modular design.
/// @custom:security Only accounts with the appropriate roles can perform restricted actions.
contract ProviderFacet is AccessControlUpgradeable, ReentrancyGuardTransient {
    using LibAccessControlEnumerable for AppStorage;
    using EnumerableSet for EnumerableSet.AddressSet;

    /// @dev Represents the initial service credits issued to new providers for onboarding.
    /// These are non-monetary credits, not ERC-20 tokens.
    /// Distribution: credits used for platform familiarization only.
    uint256 constant INITIAL_SERVICE_CREDITS = 100_000_000; // 1000 credits with 5 decimals

    /// @dev Emitted when a new provider is added to the system.
    /// @param _account The address of the provider being added.
    /// @param _name The name of the provider.
    /// @param _email The email address of the provider.
    /// @param _country The country of the provider.
    event ProviderAdded(address indexed _account, string _name, string _email, string _country);

    /// @dev Emitted when a provider is added with initial service credits
    /// @param _account The address of the provider being added.
    /// @param credits The amount of service credits issued.
    event ProviderServiceCreditsIssued(address indexed _account, uint256 credits);

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
    event ProviderUpdated(address indexed _account, string _name, string _email, string _country);

    /// @dev Emitted when a provider's authentication URI is set or updated.
    /// @param _provider The address of the provider.
    /// @param _authURI The authentication service base URL.
    event ProviderAuthURIUpdated(address indexed _provider, string _authURI);

    /// @dev Emitted when a provider's limited-network participation status changes.
    /// @param provider The address of the provider.
    /// @param previousStatus The previous network status.
    /// @param newStatus The new network status.
    event ProviderNetworkStatusChanged(
        address indexed provider,
        ProviderNetworkStatus previousStatus,
        ProviderNetworkStatus newStatus
    );

    /// @dev Modifier to restrict access to functions that can only be executed by accounts
    ///      with the `DEFAULT_ADMIN_ROLE`. Ensures that the caller of the function has the
    ///      required role before proceeding with the execution of the function.
    /// @notice Reverts if the caller does not have the `DEFAULT_ADMIN_ROLE`.
    modifier onlyDefaultAdminRole() {
        _onlyDefaultAdminRole();
        _;
    }

    function _onlyDefaultAdminRole() internal view {
        require(hasRole(DEFAULT_ADMIN_ROLE, msg.sender), "Only the default admin can perform this action");
    }

    /// @dev Constructor for the `ProviderFacet` contract.
    /// This constructor is intentionally left empty.
    constructor() {}

    /// @dev Initializes the contract setting up the initial admin role and other parameters.
    /// @notice The caller must be the contract owner.
    /// @param _name The name of the initial admin.
    /// @param _email The email of the initial admin.
    /// @param _country The country of the initial admin.
    function initialize(
        string memory _name,
        string memory _email,
        string memory _country
    ) public onlyInitializing {
        LibDiamond.enforceIsContractOwner();
        _grantRole(DEFAULT_ADMIN_ROLE, msg.sender);
        _grantRole(PROVIDER_ROLE, msg.sender);
        _grantRole(INSTITUTION_ROLE, msg.sender);
        _s()._addProviderRole(msg.sender, _name, _email, _country, "");

        _s().DEFAULT_ADMIN_ROLE = DEFAULT_ADMIN_ROLE;
        _s().labId = 0;
    }

    /// @notice Adds a new provider to the system.
    /// @dev Grants the `PROVIDER_ROLE` to the specified account and initializes the provider's details.
    ///      Issues non-monetary service credits for platform familiarization.
    ///      Sets default institutional user spending limit.
    ///      No ERC-20 tokens are minted — provider economics use service credits only.
    ///      Optionally sets the provider's authentication URI during registration.
    ///      Emits a `ProviderAdded` event upon successful addition.
    ///      Emits a `ProviderServiceCreditsIssued` event when credits are issued.
    ///      Reverts if the provider already exists.
    /// @param _name The name of the provider.
    /// @param _account The address of the provider's account.
    /// @param _email The email address of the provider.
    /// @param _country The country of the provider.
    /// @param _authURI Optional authentication service base URL (can be empty and set later by provider)
    function addProvider(
        string calldata _name,
        address _account,
        string calldata _email,
        string calldata _country,
        string calldata _authURI
    ) external onlyDefaultAdminRole nonReentrant {
        require(_account != address(0), "Invalid provider address");

        // Validate string lengths to prevent DoS attacks
        require(bytes(_name).length > 0 && bytes(_name).length <= 100, "Invalid name length");
        require(bytes(_email).length > 0 && bytes(_email).length <= 100, "Invalid email length");
        require(bytes(_country).length > 0 && bytes(_country).length <= 50, "Invalid country length");

        // Check if provider already exists (prevents duplicate additions)
        require(!hasRole(PROVIDER_ROLE, _account), "Provider already exists");

        // Validate authURI format if provided
        if (bytes(_authURI).length > 0) {
            _validateAuthURI(_authURI);
        }

        _grantRole(PROVIDER_ROLE, _account);
        _grantRole(INSTITUTION_ROLE, _account);
        _s()._addProviderRole(_account, _name, _email, _country, _authURI);

        // Emit authURI event if provided
        if (bytes(_authURI).length > 0) {
            emit ProviderAuthURIUpdated(_account, _authURI);
        }

        // Issue non-monetary service credits for platform familiarization
        AppStorage storage s = _s();
        s.serviceCreditBalance[_account] = INITIAL_SERVICE_CREDITS;

        // Activate provider in the limited network
        s.providerNetworkStatus[_account] = ProviderNetworkStatus.ACTIVE;

        // Set institutional defaults (spending limits, period, backend)
        s.institutionalUserLimit[_account] = LibAppStorage.DEFAULT_INSTITUTIONAL_USER_LIMIT;
        s.institutionalSpendingPeriod[_account] = LibAppStorage.DEFAULT_SPENDING_PERIOD;
        s.institutionalBackends[_account] = _account;

        emit BackendAuthorized(_account, _account);
        emit ProviderServiceCreditsIssued(_account, INITIAL_SERVICE_CREDITS);
        emit ProviderNetworkStatusChanged(_account, ProviderNetworkStatus.NONE, ProviderNetworkStatus.ACTIVE);
        emit ProviderAdded(_account, _name, _email, _country);
    }

    /// @notice Removes a provider from the system by revoking their PROVIDER_ROLE.
    /// @dev This function can only be called by an account with the DEFAULT_ADMIN_ROLE.
    ///      Clears provider service credits and stake data.
    ///      If the provider does not have the PROVIDER_ROLE, the transaction reverts with an error.
    ///      Emits a `ProviderRemoved` event upon successful removal.
    /// @param _provider The address of the provider to be removed.
    function removeProvider(
        address _provider
    ) external onlyRole(DEFAULT_ADMIN_ROLE) nonReentrant {
        // Check if provider exists (prevents removing non-existent providers)
        require(hasRole(PROVIDER_ROLE, _provider), "Provider does not exist");

        _revokeRole(PROVIDER_ROLE, _provider);
        AppStorage storage s = _s();

        // Clear provider data
        delete s.providerStakes[_provider];
        s.serviceCreditBalance[_provider] = 0;
        ProviderNetworkStatus prevStatus = s.providerNetworkStatus[_provider];
        s.providerNetworkStatus[_provider] = ProviderNetworkStatus.TERMINATED;
        s._removeProviderRole(_provider);

        emit ProviderNetworkStatusChanged(_provider, prevStatus, ProviderNetworkStatus.TERMINATED);
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
        ProviderBase storage provider = _s().providers[msg.sender];
        provider.name = _name;
        provider.email = _email;
        provider.country = _country;
        emit ProviderUpdated(msg.sender, _name, _email, _country);
    }

    /// @notice Sets or updates the authentication service URI for the caller provider.
    /// @dev This function allows a provider to set their authentication service base URL.
    ///      The authURI is validated to ensure it starts with https:// and has no trailing slash.
    ///      Only accounts with the `PROVIDER_ROLE` can call this function.
    ///      Emits a `ProviderAuthURIUpdated` event upon successful update.
    /// @param _authURI The base URL of the authentication service (e.g., https://provider.example.com/auth)
    function setProviderAuthURI(
        string calldata _authURI
    ) external onlyRole(PROVIDER_ROLE) {
        require(bytes(_authURI).length > 0, "AuthURI cannot be empty");
        _validateAuthURI(_authURI);

        _s().providers[msg.sender].authURI = _authURI;
        emit ProviderAuthURIUpdated(msg.sender, _authURI);
    }

    /// @notice Retrieves the authentication URI for a specific provider.
    /// @param _provider The address of the provider.
    /// @return The authentication service base URL.
    function getProviderAuthURI(
        address _provider
    ) external view returns (string memory) {
        return _s().providers[_provider].authURI;
    }

    /// @dev Internal function to validate authURI format.
    ///      Ensures the URI starts with https://, ends with /auth, and doesn't have a trailing slash.
    /// @param _authURI The authentication URI to validate.
    function _validateAuthURI(
        string calldata _authURI
    ) internal pure {
        bytes memory uri = bytes(_authURI);

        // Must start with "https://"
        require(
            uri.length >= 8 && uri[0] == "h" && uri[1] == "t" && uri[2] == "t" && uri[3] == "p" && uri[4] == "s"
                && uri[5] == ":" && uri[6] == "/" && uri[7] == "/",
            "AuthURI must start with https://"
        );

        // Must not end with '/'
        require(uri[uri.length - 1] != "/", "AuthURI must not end with a slash");

        // Must end with "/auth"
        require(
            uri.length >= 5 && uri[uri.length - 5] == "/" && uri[uri.length - 4] == "a" && uri[uri.length - 3] == "u"
                && uri[uri.length - 2] == "t" && uri[uri.length - 1] == "h",
            "AuthURI must end with /auth"
        );
    }

    /// @notice Checks if the given account is a Lab provider.
    /// @param _account The address of the account to check.
    /// @return A boolean indicating whether the account is a Lab provider.
    function isLabProvider(
        address _account
    ) external view returns (bool) {
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
    function getLabProvidersPaginated(
        uint256 offset,
        uint256 limit
    ) external view returns (Provider[] memory providers, uint256 total) {
        return _s()._getLabProvidersPaginated(offset, limit);
    }

    /// @notice Sets the network participation status for an existing provider.
    /// @dev Only callable by DEFAULT_ADMIN_ROLE. Valid transitions:
    ///      ACTIVE -> SUSPENDED, SUSPENDED -> ACTIVE, any -> TERMINATED.
    ///      Cannot set to NONE or revive a TERMINATED provider.
    /// @param _provider The address of the provider.
    /// @param _newStatus The new network status to assign.
    function setProviderNetworkStatus(
        address _provider,
        ProviderNetworkStatus _newStatus
    ) external onlyDefaultAdminRole {
        require(hasRole(PROVIDER_ROLE, _provider), "Provider does not exist");
        require(_newStatus != ProviderNetworkStatus.NONE, "Cannot set status to NONE");

        AppStorage storage s = _s();
        ProviderNetworkStatus current = s.providerNetworkStatus[_provider];
        require(current != ProviderNetworkStatus.TERMINATED, "Cannot change status of terminated provider");
        require(current != _newStatus, "Status already set");

        s.providerNetworkStatus[_provider] = _newStatus;
        emit ProviderNetworkStatusChanged(_provider, current, _newStatus);
    }

    /// @notice Returns the network participation status of a provider.
    /// @param _provider The address of the provider.
    /// @return The current ProviderNetworkStatus.
    function getProviderNetworkStatus(
        address _provider
    ) external view returns (ProviderNetworkStatus) {
        return _s().providerNetworkStatus[_provider];
    }

    /// @notice Returns whether a provider is active in the limited network.
    /// @param _provider The address of the provider.
    /// @return True if the provider status is ACTIVE.
    function isProviderNetworkActive(
        address _provider
    ) external view returns (bool) {
        return _s().providerNetworkStatus[_provider] == ProviderNetworkStatus.ACTIVE;
    }

    function _grantRole(
        bytes32 role,
        address account
    ) internal virtual override returns (bool) {
        bool granted = super._grantRole(role, account);
        if (granted) {
            _s().roleMembers[role].add(account);
        }
        return granted;
    }

    function _revokeRole(
        bytes32 role,
        address account
    ) internal virtual override returns (bool) {
        bool revoked = super._revokeRole(role, account);
        if (revoked) {
            _s().roleMembers[role].remove(account);
        }
        return revoked;
    }

    /// @dev Internal pure function to retrieve the application storage structure.
    ///      This function provides access to the `AppStorage` instance by calling
    ///      the `diamondStorage` function from the `LibAppStorage` library.
    /// @return s The storage instance of type `AppStorage`.
    function _s() internal pure returns (AppStorage storage s) {
        return LibAppStorage.diamondStorage();
    }
}
