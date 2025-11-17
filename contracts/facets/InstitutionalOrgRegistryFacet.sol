// SPDX-License-Identifier: GPL-3.0-or-later
pragma solidity ^0.8.23;

import {EnumerableSet} from "@openzeppelin/contracts/utils/structs/EnumerableSet.sol";
import {LibAppStorage, AppStorage, PROVIDER_ROLE} from "../libraries/LibAppStorage.sol";

/// @title InstitutionalOrgRegistryFacet
/// @notice On-chain registry that maps schacHomeOrganization identifiers to provider wallets
/// @dev Allows lab providers to self-register the domains (usually the institution's schacHomeOrganization)
///      they control so authorized backends can resolve which institutional treasury should be charged.
contract InstitutionalOrgRegistryFacet {
    using EnumerableSet for EnumerableSet.AddressSet;
    using EnumerableSet for EnumerableSet.Bytes32Set;

    /// @notice Emitted when a provider registers a schacHomeOrganization
    event SchacHomeOrganizationRegistered(
        address indexed provider,
        string organization,
        bytes32 indexed organizationHash
    );

    /// @notice Emitted when a provider removes a schacHomeOrganization from the registry
    event SchacHomeOrganizationRemoved(
        address indexed provider,
        string organization,
        bytes32 indexed organizationHash
    );

    /// @notice Register a schacHomeOrganization for the caller's provider account
    /// @param schacHomeOrganization The organization identifier (will be normalized to lowercase)
    function registerSchacHomeOrganization(string calldata schacHomeOrganization) external onlyProvider {
        string memory normalized = _normalizeOrganization(schacHomeOrganization);
        _registerOrganization(msg.sender, normalized);
    }

    /// @notice Admin helper to register a schacHomeOrganization on behalf of a provider
    /// @param provider The provider wallet that owns the institution
    /// @param schacHomeOrganization The organization identifier (will be normalized to lowercase)
    function adminRegisterSchacHomeOrganization(
        address provider,
        string calldata schacHomeOrganization
    ) external onlyDefaultAdmin {
        string memory normalized = _normalizeOrganization(schacHomeOrganization);
        _registerOrganization(provider, normalized);
    }

    /// @notice Remove a schacHomeOrganization previously registered by the caller
    /// @param schacHomeOrganization The organization identifier to remove
    function unregisterSchacHomeOrganization(string calldata schacHomeOrganization) external onlyProvider {
        string memory normalized = _normalizeOrganization(schacHomeOrganization);
        _unregisterOrganization(msg.sender, normalized);
    }

    /// @notice Admin helper to remove a schacHomeOrganization from a provider
    /// @param provider The provider wallet that owns the organization
    /// @param schacHomeOrganization The organization identifier to remove
    function adminUnregisterSchacHomeOrganization(
        address provider,
        string calldata schacHomeOrganization
    ) external onlyDefaultAdmin {
        string memory normalized = _normalizeOrganization(schacHomeOrganization);
        _unregisterOrganization(provider, normalized);
    }

    /// @notice Resolve a schacHomeOrganization to the provider wallet that registered it
    /// @param schacHomeOrganization The organization identifier to resolve (case-insensitive)
    /// @return provider The provider wallet associated with the normalized identifier
    function resolveSchacHomeOrganization(string calldata schacHomeOrganization) external view returns (address provider) {
        string memory normalized = _normalizeOrganization(schacHomeOrganization);
        bytes32 orgHash = keccak256(bytes(normalized));
        return _s().schacHomeOrganizationRegistry[orgHash];
    }

    /// @notice Returns all schacHomeOrganization identifiers registered by a provider
    /// @param provider The provider wallet to inspect
    /// @return organizations Array of normalized schacHomeOrganization identifiers
    function getRegisteredSchacHomeOrganizations(address provider) external view returns (string[] memory organizations) {
        AppStorage storage s = _s();
        uint256 total = s.providerSchacHomeOrganizations[provider].length();
        organizations = new string[](total);

        for (uint256 i = 0; i < total; i++) {
            bytes32 orgHash = s.providerSchacHomeOrganizations[provider].at(i);
            organizations[i] = s.schacHomeOrganizationNames[orgHash];
        }
    }

    /// @notice View helper that returns both the provider and the normalized identifier for a hash
    /// @param organizationHash keccak256 hash of the normalized schacHomeOrganization
    /// @return provider The provider wallet that owns the identifier
    /// @return organization The normalized schacHomeOrganization string
    function getOrganizationByHash(bytes32 organizationHash) external view returns (address provider, string memory organization) {
        AppStorage storage s = _s();
        provider = s.schacHomeOrganizationRegistry[organizationHash];
        organization = s.schacHomeOrganizationNames[organizationHash];
    }

    /// @dev Internal helper that registers the normalized identifier for a provider
    function _registerOrganization(address provider, string memory normalizedOrganization) internal {
        require(provider != address(0), "Invalid provider");

        AppStorage storage s = _s();
        require(s.roleMembers[PROVIDER_ROLE].contains(provider), "Unknown provider");

        bytes32 orgHash = keccak256(bytes(normalizedOrganization));
        require(
            s.schacHomeOrganizationRegistry[orgHash] == address(0),
            "Organization already registered"
        );

        s.schacHomeOrganizationRegistry[orgHash] = provider;
        s.schacHomeOrganizationNames[orgHash] = normalizedOrganization;
        bool added = s.providerSchacHomeOrganizations[provider].add(orgHash);
        require(added, "Organization already tracked for provider");

        emit SchacHomeOrganizationRegistered(provider, normalizedOrganization, orgHash);
    }

    /// @dev Internal helper that unregisters a normalized identifier from a provider
    function _unregisterOrganization(address provider, string memory normalizedOrganization) internal {
        AppStorage storage s = _s();
        bytes32 orgHash = keccak256(bytes(normalizedOrganization));

        require(
            s.schacHomeOrganizationRegistry[orgHash] == provider,
            "Organization not registered by provider"
        );

        delete s.schacHomeOrganizationRegistry[orgHash];
        delete s.schacHomeOrganizationNames[orgHash];
        bool removed = s.providerSchacHomeOrganizations[provider].remove(orgHash);
        require(removed, "Organization not tracked for provider");

        emit SchacHomeOrganizationRemoved(provider, normalizedOrganization, orgHash);
    }

    /// @dev Ensures the caller owns a provider role
    modifier onlyProvider() {
        AppStorage storage s = _s();
        require(s.roleMembers[PROVIDER_ROLE].contains(msg.sender), "Only provider");
        _;
    }

    /// @dev Ensures the caller has the DEFAULT_ADMIN_ROLE
    modifier onlyDefaultAdmin() {
        AppStorage storage s = _s();
        require(s.roleMembers[s.DEFAULT_ADMIN_ROLE].contains(msg.sender), "Only admin");
        _;
    }

    /// @dev Normalizes schacHomeOrganization identifiers to lowercase and validates characters
    function _normalizeOrganization(string memory organization) internal pure returns (string memory) {
        bytes memory input = bytes(organization);
        require(input.length >= 3 && input.length <= 255, "Invalid org length");

        bytes memory normalized = new bytes(input.length);
        for (uint256 i = 0; i < input.length; i++) {
            bytes1 char = input[i];

            // Uppercase ASCII -> lowercase
            if (char >= 0x41 && char <= 0x5A) {
                char = bytes1(uint8(char) + 32);
            }

            require(
                (char >= 0x61 && char <= 0x7A) || // a-z
                (char >= 0x30 && char <= 0x39) || // 0-9
                char == 0x2D || // -
                char == 0x2E,   // .
                "Invalid org character"
            );

            normalized[i] = char;
        }

        return string(normalized);
    }

    function _s() internal pure returns (AppStorage storage s) {
        return LibAppStorage.diamondStorage();
    }
}
