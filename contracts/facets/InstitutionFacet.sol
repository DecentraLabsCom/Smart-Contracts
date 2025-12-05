// SPDX-License-Identifier: GPL-3.0-or-later
pragma solidity ^0.8.23;

import "@openzeppelin/contracts-upgradeable/access/AccessControlUpgradeable.sol";
import {EnumerableSet} from "@openzeppelin/contracts/utils/structs/EnumerableSet.sol";
import {LibAppStorage, AppStorage, INSTITUTION_ROLE, PROVIDER_ROLE} from "../libraries/LibAppStorage.sol";
import {LibInstitutionalOrg} from "../libraries/LibInstitutionalOrg.sol";

/// @title InstitutionFacet
/// @notice Admin helpers to manage institution wallets and their associated schacHomeOrganization domains
contract InstitutionFacet is AccessControlUpgradeable {
    using EnumerableSet for EnumerableSet.Bytes32Set;
    using EnumerableSet for EnumerableSet.AddressSet;

    /// @notice Emitted whenever the INSTITUTION_ROLE is granted
    event InstitutionRoleGranted(address indexed institution, bytes32 indexed organizationHash);

    /// @notice Emitted whenever the INSTITUTION_ROLE is revoked
    event InstitutionRoleRevoked(address indexed institution);

    modifier onlyDefaultAdmin() {
        require(hasRole(DEFAULT_ADMIN_ROLE, msg.sender), "Only admin");
        _;
    }

    /// @notice Grants the INSTITUTION_ROLE to `institution` and registers its schacHomeOrganization
    /// @param institution Wallet that will manage the institutional treasury and backend
    /// @param organization schacHomeOrganization string (will be normalized to lowercase)
    function grantInstitutionRole(address institution, string calldata organization) external onlyDefaultAdmin {
        AppStorage storage s = _s();
        require(institution != address(0), "Invalid institution");

        string memory normalized = LibInstitutionalOrg.normalizeOrganization(organization);
        if (!s.roleMembers[INSTITUTION_ROLE].contains(institution)) {
            _grantRole(INSTITUTION_ROLE, institution);
        }

        LibInstitutionalOrg.registerOrganization(s, institution, normalized);
        emit InstitutionRoleGranted(institution, keccak256(bytes(normalized)));
    }

    /// @notice Revokes the INSTITUTION_ROLE from `institution` (when it no longer controls the domain)
    /// @param institution Wallet whose role should be revoked
    /// @param organization schacHomeOrganization string to unregister
    function revokeInstitutionRole(address institution, string calldata organization) external onlyDefaultAdmin {
        AppStorage storage s = _s();
        require(institution != address(0), "Invalid institution");

        string memory normalized = LibInstitutionalOrg.normalizeOrganization(organization);
        LibInstitutionalOrg.unregisterOrganization(s, institution, normalized);

        if (s.institutionSchacHomeOrganizations[institution].length() == 0) {
            _revokeRole(INSTITUTION_ROLE, institution);
            emit InstitutionRoleRevoked(institution);
        }
    }

    /// @notice Returns every wallet that currently holds INSTITUTION_ROLE (providers + consumers)
    function getAllInstitutions() external view returns (address[] memory institutions) {
        AppStorage storage s = _s();
        uint256 total = s.roleMembers[INSTITUTION_ROLE].length();
        institutions = new address[](total);
        for (uint256 i = 0; i < total; i++) {
            institutions[i] = s.roleMembers[INSTITUTION_ROLE].at(i);
        }
    }

    /// @notice Paginated list of institution wallets
    function getInstitutionsPaginated(uint256 offset, uint256 limit)
        external
        view
        returns (address[] memory institutions, uint256 total)
    {
        AppStorage storage s = _s();
        total = s.roleMembers[INSTITUTION_ROLE].length();
        require(limit > 0 && limit <= 200, "Invalid limit");
        if (offset >= total) {
            return (new address[](0), total);
        }
        uint256 end = offset + limit;
        if (end > total) end = total;
        uint256 size = end - offset;
        institutions = new address[](size);
        for (uint256 i; i < size; i++) {
            institutions[i] = s.roleMembers[INSTITUTION_ROLE].at(offset + i);
        }
    }

    function _grantRole(bytes32 role, address account) internal virtual override {
        super._grantRole(role, account);
        _s().roleMembers[role].add(account);
    }

    function _revokeRole(bytes32 role, address account) internal virtual override {
        super._revokeRole(role, account);
        _s().roleMembers[role].remove(account);
    }

    function _s() internal pure returns (AppStorage storage s) {
        return LibAppStorage.diamondStorage();
    }
}
