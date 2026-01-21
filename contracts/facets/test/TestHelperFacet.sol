// SPDX-License-Identifier: GPL-3.0-or-later
pragma solidity ^0.8.31;

import {LibAppStorage, AppStorage, INSTITUTION_ROLE} from "../../libraries/LibAppStorage.sol";
import {EnumerableSet} from "@openzeppelin/contracts/utils/structs/EnumerableSet.sol";

/// @title TestHelperFacet
/// @notice Test-only facet for manipulating AppStorage in tests
/// @dev NEVER deploy this facet to production networks
/// @dev Only add to diamond during test setup to maintain storage context consistency
contract TestHelperFacet {
    using EnumerableSet for EnumerableSet.AddressSet;

    /// @notice Set institution role for testing
    /// @dev TEST ONLY - Adds an address to the INSTITUTION_ROLE
    function test_setInstitutionRole(
        address inst
    ) external {
        AppStorage storage s = LibAppStorage.diamondStorage();
        s.roleMembers[INSTITUTION_ROLE].add(inst);
    }

    /// @notice Set backend for institution for testing
    /// @dev TEST ONLY - Directly sets the backend address for an institution
    function test_setBackend(
        address inst,
        address backend
    ) external {
        AppStorage storage s = LibAppStorage.diamondStorage();
        s.institutionalBackends[inst] = backend;
    }

    /// @notice Set institutional treasury balance for testing
    /// @dev TEST ONLY - Directly sets the treasury balance
    function test_setInstitutionalTreasury(
        address inst,
        uint256 amount
    ) external {
        AppStorage storage s = LibAppStorage.diamondStorage();
        s.institutionalTreasury[inst] = amount;
    }
}
