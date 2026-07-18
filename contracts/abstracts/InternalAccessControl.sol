// SPDX-License-Identifier: GPL-3.0-or-later
pragma solidity ^0.8.33;

import {Initializable} from "@openzeppelin/contracts/proxy/utils/Initializable.sol";

/// @dev Internal-only access control aligned with OpenZeppelin's ERC-7201 storage layout.
///      The generic grant/revoke/renounce entry points are intentionally not exposed.
abstract contract InternalAccessControl is Initializable {
    struct RoleData {
        mapping(address account => bool) hasRole;
        bytes32 adminRole;
    }

    struct AccessControlStorage {
        mapping(bytes32 role => RoleData) roles;
    }

    bytes32 public constant DEFAULT_ADMIN_ROLE = bytes32(0);

    bytes32 private constant _ACCESS_CONTROL_STORAGE_LOCATION =
        0x02dd7bc7dec4dceedda775e58dd541e08a116c6c53815c0bd028192f7b626800;

    error AccessControlUnauthorizedAccount(address account, bytes32 neededRole);

    event RoleGranted(bytes32 indexed role, address indexed account, address indexed sender);
    event RoleRevoked(bytes32 indexed role, address indexed account, address indexed sender);

    modifier onlyRole(
        bytes32 role
    ) {
        if (!hasRole(role, msg.sender)) revert AccessControlUnauthorizedAccount(msg.sender, role);
        _;
    }

    function hasRole(
        bytes32 role,
        address account
    ) public view returns (bool) {
        return _accessControlStorage().roles[role].hasRole[account];
    }

    function getRoleAdmin(
        bytes32 role
    ) public view returns (bytes32) {
        return _accessControlStorage().roles[role].adminRole;
    }

    function _grantRole(
        bytes32 role,
        address account
    ) internal virtual returns (bool) {
        AccessControlStorage storage store = _accessControlStorage();
        if (store.roles[role].hasRole[account]) return false;

        store.roles[role].hasRole[account] = true;
        emit RoleGranted(role, account, msg.sender);
        return true;
    }

    function _revokeRole(
        bytes32 role,
        address account
    ) internal virtual returns (bool) {
        AccessControlStorage storage store = _accessControlStorage();
        if (!store.roles[role].hasRole[account]) return false;

        store.roles[role].hasRole[account] = false;
        emit RoleRevoked(role, account, msg.sender);
        return true;
    }

    function _accessControlStorage() private pure returns (AccessControlStorage storage store) {
        bytes32 slot = _ACCESS_CONTROL_STORAGE_LOCATION;
        assembly {
            store.slot := slot
        }
    }
}
