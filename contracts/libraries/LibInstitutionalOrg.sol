// SPDX-License-Identifier: GPL-3.0-or-later
pragma solidity ^0.8.23;

import {EnumerableSet} from "@openzeppelin/contracts/utils/structs/EnumerableSet.sol";
import {AppStorage, INSTITUTION_ROLE} from "./LibAppStorage.sol";

/// @title LibInstitutionalOrg
/// @notice Shared helpers to normalize and manage schacHomeOrganization registrations
library LibInstitutionalOrg {
    using EnumerableSet for EnumerableSet.Bytes32Set;

    /// @notice Emitted when an institution registers a schacHomeOrganization
    event SchacHomeOrganizationRegistered(
        address indexed institution,
        string organization,
        bytes32 indexed organizationHash
    );

    /// @notice Emitted when an institution unregisters a schacHomeOrganization
    event SchacHomeOrganizationRemoved(
        address indexed institution,
        string organization,
        bytes32 indexed organizationHash
    );

    /// @notice Normalizes schacHomeOrganization identifiers to lowercase and validates characters
    function normalizeOrganization(string memory organization) internal pure returns (string memory) {
        bytes memory input = bytes(organization);
        require(input.length >= 3 && input.length <= 255, "Invalid org length");

        bytes memory normalized = new bytes(input.length);
        for (uint256 i = 0; i < input.length; i++) {
            bytes1 char = input[i];

            if (char >= 0x41 && char <= 0x5A) {
                char = bytes1(uint8(char) + 32);
            }

            require(
                (char >= 0x61 && char <= 0x7A) ||
                (char >= 0x30 && char <= 0x39) ||
                char == 0x2D ||
                char == 0x2E,
                "Invalid org character"
            );

            normalized[i] = char;
        }

        return string(normalized);
    }

    /// @notice Registers a normalized organization for an institution wallet
    function registerOrganization(
        AppStorage storage s,
        address institution,
        string memory normalizedOrganization
    ) internal {
        require(institution != address(0), "Invalid institution");
        require(s.roleMembers[INSTITUTION_ROLE].contains(institution), "Unknown institution");

        bytes32 orgHash = keccak256(bytes(normalizedOrganization));
        require(
            s.organizationInstitutionWallet[orgHash] == address(0),
            "Organization already registered"
        );

        s.organizationInstitutionWallet[orgHash] = institution;
        s.schacHomeOrganizationNames[orgHash] = normalizedOrganization;

        bool added = s.institutionSchacHomeOrganizations[institution].add(orgHash);
        require(added, "Organization already tracked");

        emit SchacHomeOrganizationRegistered(institution, normalizedOrganization, orgHash);
    }

    /// @notice Removes a normalized organization from an institution wallet
    function unregisterOrganization(
        AppStorage storage s,
        address institution,
        string memory normalizedOrganization
    ) internal {
        bytes32 orgHash = keccak256(bytes(normalizedOrganization));
        require(
            s.organizationInstitutionWallet[orgHash] == institution,
            "Organization not registered by wallet"
        );

        delete s.organizationInstitutionWallet[orgHash];
        delete s.schacHomeOrganizationNames[orgHash];

        bool removed = s.institutionSchacHomeOrganizations[institution].remove(orgHash);
        require(removed, "Organization not tracked");

        emit SchacHomeOrganizationRemoved(institution, normalizedOrganization, orgHash);
    }
}
