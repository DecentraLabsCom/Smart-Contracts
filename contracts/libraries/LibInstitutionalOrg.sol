// SPDX-License-Identifier: GPL-3.0-or-later
pragma solidity ^0.8.33;

import {EnumerableSet} from "@openzeppelin/contracts/utils/structs/EnumerableSet.sol";
import {AppStorage, INSTITUTION_ROLE} from "./LibAppStorage.sol";

// Custom errors for gas-efficient reverts (Solidity 0.8.26+)
error InvalidOrgLength();
error InvalidOrgCharacter();
error InvalidInstitutionAddress();
error UnknownInstitution();
error OrganizationAlreadyRegistered();
error OrganizationAlreadyTracked();
error OrganizationNotRegisteredByWallet();
error OrganizationNotTracked();

/// @title LibInstitutionalOrg
/// @notice Shared helpers to normalize and manage schacHomeOrganization registrations
library LibInstitutionalOrg {
    using EnumerableSet for EnumerableSet.Bytes32Set;
    using EnumerableSet for EnumerableSet.AddressSet;

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
        uint256 length = input.length;
        require(length >= 3 && length <= 255, InvalidOrgLength());

        bytes memory normalized = new bytes(length);
        for (uint256 i; i < length; ) {
            bytes1 char = input[i];

            if (char >= 0x41 && char <= 0x5A) {
                char = bytes1(uint8(char) + 32);
            }

            require(
                (char >= 0x61 && char <= 0x7A) ||
                (char >= 0x30 && char <= 0x39) ||
                char == 0x2D ||
                char == 0x2E,
                InvalidOrgCharacter()
            );

            normalized[i] = char;
            unchecked {
                ++i;
            }
        }

        return string(normalized);
    }

    /// @notice Registers a normalized organization for an institution wallet
    function registerOrganization(
        AppStorage storage s,
        address institution,
        string memory normalizedOrganization
    ) internal {
        require(institution != address(0), InvalidInstitutionAddress());
        require(s.roleMembers[INSTITUTION_ROLE].contains(institution), UnknownInstitution());

        // forge-lint: disable-next-line(asm-keccak256)
        bytes32 orgHash = keccak256(bytes(normalizedOrganization));
        require(
            s.organizationInstitutionWallet[orgHash] == address(0),
            OrganizationAlreadyRegistered()
        );

        s.organizationInstitutionWallet[orgHash] = institution;
        s.schacHomeOrganizationNames[orgHash] = normalizedOrganization;

        bool added = s.institutionSchacHomeOrganizations[institution].add(orgHash);
        require(added, OrganizationAlreadyTracked());

        emit SchacHomeOrganizationRegistered(institution, normalizedOrganization, orgHash);
    }

    /// @notice Removes a normalized organization from an institution wallet
    function unregisterOrganization(
        AppStorage storage s,
        address institution,
        string memory normalizedOrganization
    ) internal {
        // forge-lint: disable-next-line(asm-keccak256)
        bytes32 orgHash = keccak256(bytes(normalizedOrganization));
        require(
            s.organizationInstitutionWallet[orgHash] == institution,
            OrganizationNotRegisteredByWallet()
        );

        delete s.organizationInstitutionWallet[orgHash];
        delete s.schacHomeOrganizationNames[orgHash];

        bool removed = s.institutionSchacHomeOrganizations[institution].remove(orgHash);
        require(removed, OrganizationNotTracked());

        emit SchacHomeOrganizationRemoved(institution, normalizedOrganization, orgHash);
    }
}
