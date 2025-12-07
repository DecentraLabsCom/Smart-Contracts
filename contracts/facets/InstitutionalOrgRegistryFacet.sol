// SPDX-License-Identifier: GPL-3.0-or-later
pragma solidity ^0.8.23;

import {EnumerableSet} from "@openzeppelin/contracts/utils/structs/EnumerableSet.sol";
import {LibAppStorage, AppStorage, INSTITUTION_ROLE} from "../libraries/LibAppStorage.sol";
import {LibInstitutionalOrg} from "../libraries/LibInstitutionalOrg.sol";

/// @title InstitutionalOrgRegistryFacet
/// @notice On-chain registry that maps schacHomeOrganization identifiers to provider wallets
/// @dev Allows lab providers to self-register the domains (usually the institution's schacHomeOrganization)
///      they control so authorized backends can resolve which institutional treasury should be charged.
contract InstitutionalOrgRegistryFacet {
    using EnumerableSet for EnumerableSet.AddressSet;
    using EnumerableSet for EnumerableSet.Bytes32Set;

    /// @notice Register a schacHomeOrganization for the caller's provider account
    /// @param schacHomeOrganization The organization identifier (will be normalized to lowercase)
    function registerSchacHomeOrganization(string calldata schacHomeOrganization) external onlyInstitution {
        string memory normalized = LibInstitutionalOrg.normalizeOrganization(schacHomeOrganization);
        LibInstitutionalOrg.registerOrganization(_s(), msg.sender, normalized);
    }

    /// @notice Admin helper to register a schacHomeOrganization on behalf of an institution
    /// @param institution The institution wallet that owns the organization
    /// @param schacHomeOrganization The organization identifier (will be normalized to lowercase)
    function adminRegisterSchacHomeOrganization(
        address institution,
        string calldata schacHomeOrganization
    ) external onlyDefaultAdmin {
        string memory normalized = LibInstitutionalOrg.normalizeOrganization(schacHomeOrganization);
        LibInstitutionalOrg.registerOrganization(_s(), institution, normalized);
    }

    /// @notice Remove a schacHomeOrganization previously registered by the caller
    /// @param schacHomeOrganization The organization identifier to remove
    function unregisterSchacHomeOrganization(string calldata schacHomeOrganization) external onlyInstitution {
        string memory normalized = LibInstitutionalOrg.normalizeOrganization(schacHomeOrganization);
        LibInstitutionalOrg.unregisterOrganization(_s(), msg.sender, normalized);
    }

    /// @notice Admin helper to remove a schacHomeOrganization from an institution
    /// @param institution The institution wallet that owns the organization
    /// @param schacHomeOrganization The organization identifier to remove
    function adminUnregisterSchacHomeOrganization(
        address institution,
        string calldata schacHomeOrganization
    ) external onlyDefaultAdmin {
        string memory normalized = LibInstitutionalOrg.normalizeOrganization(schacHomeOrganization);
        LibInstitutionalOrg.unregisterOrganization(_s(), institution, normalized);
    }

    /// @notice Resolve a schacHomeOrganization to the provider wallet that registered it
    /// @param schacHomeOrganization The organization identifier to resolve (case-insensitive)
    /// @return institution The institution wallet associated with the normalized identifier
    function resolveSchacHomeOrganization(string calldata schacHomeOrganization) external view returns (address institution) {
        string memory normalized = LibInstitutionalOrg.normalizeOrganization(schacHomeOrganization);
        // forge-lint: disable-next-line(asm-keccak256)
        bytes32 orgHash = keccak256(bytes(normalized));
        return _s().organizationInstitutionWallet[orgHash];
    }

    /// @notice Returns all schacHomeOrganization identifiers registered by a provider
    /// @param institution The institution wallet to inspect
    /// @return organizations Array of normalized schacHomeOrganization identifiers
    function getRegisteredSchacHomeOrganizations(address institution) external view returns (string[] memory organizations) {
        AppStorage storage s = _s();
        uint256 total = s.institutionSchacHomeOrganizations[institution].length();
        organizations = new string[](total);

        for (uint256 i = 0; i < total; i++) {
            bytes32 orgHash = s.institutionSchacHomeOrganizations[institution].at(i);
            organizations[i] = s.schacHomeOrganizationNames[orgHash];
        }
    }

    /// @notice Paginated schacHomeOrganization identifiers registered by an institution
    function getRegisteredSchacHomeOrganizationsPaginated(
        address institution,
        uint256 offset,
        uint256 limit
    ) external view returns (string[] memory organizations, uint256 total) {
        AppStorage storage s = _s();
        total = s.institutionSchacHomeOrganizations[institution].length();
        require(limit > 0 && limit <= 200, "Invalid limit");
        if (offset >= total) {
            return (new string[](0), total);
        }
        uint256 end = offset + limit;
        if (end > total) end = total;
        uint256 size = end - offset;
        organizations = new string[](size);
        for (uint256 i; i < size; i++) {
            bytes32 orgHash = s.institutionSchacHomeOrganizations[institution].at(offset + i);
            organizations[i] = s.schacHomeOrganizationNames[orgHash];
        }
    }

    /// @notice View helper that returns both the provider and the normalized identifier for a hash
    /// @param organizationHash keccak256 hash of the normalized schacHomeOrganization
    /// @return institution The institution wallet that owns the identifier
    /// @return organization The normalized schacHomeOrganization string
    function getOrganizationByHash(bytes32 organizationHash) external view returns (address institution, string memory organization) {
        AppStorage storage s = _s();
        institution = s.organizationInstitutionWallet[organizationHash];
        organization = s.schacHomeOrganizationNames[organizationHash];
    }

    /// @notice Returns the institution wallet registered for an organization hash
    function getInstitutionWalletByOrganizationHash(bytes32 organizationHash) external view returns (address) {
        return _s().organizationInstitutionWallet[organizationHash];
    }

    /// @notice Returns the organization hashes registered by an institution wallet
    function getOrganizationHashesByInstitution(address institution) external view returns (bytes32[] memory organizationHashes) {
        AppStorage storage s = _s();
        uint256 total = s.institutionSchacHomeOrganizations[institution].length();
        organizationHashes = new bytes32[](total);
        for (uint256 i = 0; i < total; i++) {
            organizationHashes[i] = s.institutionSchacHomeOrganizations[institution].at(i);
        }
    }

    /// @notice Paginated organization hashes registered by an institution wallet
    function getOrganizationHashesByInstitutionPaginated(
        address institution,
        uint256 offset,
        uint256 limit
    ) external view returns (bytes32[] memory organizationHashes, uint256 total) {
        AppStorage storage s = _s();
        total = s.institutionSchacHomeOrganizations[institution].length();
        require(limit > 0 && limit <= 200, "Invalid limit");
        if (offset >= total) {
            return (new bytes32[](0), total);
        }
        uint256 end = offset + limit;
        if (end > total) end = total;
        uint256 size = end - offset;
        organizationHashes = new bytes32[](size);
        for (uint256 i; i < size; i++) {
            organizationHashes[i] = s.institutionSchacHomeOrganizations[institution].at(offset + i);
        }
    }

    /// @dev Ensures the caller owns an institution role
    modifier onlyInstitution() {
        _onlyInstitution();
        _;
    }

    /// @dev Ensures the caller has the DEFAULT_ADMIN_ROLE
    modifier onlyDefaultAdmin() {
        _onlyDefaultAdmin();
        _;
    }

    function _onlyInstitution() internal view {
        AppStorage storage s = _s();
        require(s.roleMembers[INSTITUTION_ROLE].contains(msg.sender), "Only institution");
    }

    function _onlyDefaultAdmin() internal view {
        AppStorage storage s = _s();
        require(s.roleMembers[s.DEFAULT_ADMIN_ROLE].contains(msg.sender), "Only admin");
    }

    function _s() internal pure returns (AppStorage storage s) {
        return LibAppStorage.diamondStorage();
    }
}
