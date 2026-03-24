// SPDX-License-Identifier: GPL-3.0-or-later
pragma solidity ^0.8.31;

import {LibAppStorage, AppStorage, INSTITUTION_ROLE} from "../../libraries/LibAppStorage.sol";
import {IntentMeta, IntentState} from "../../libraries/IntentTypes.sol";
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

    /// @notice Set a pending action intent for testing LabIntentFacet flows
    /// @dev TEST ONLY - Bypasses EIP-712; sets intent so executor can consume it
    function test_setPendingActionIntent(
        bytes32 requestId,
        address signer,
        address executor,
        uint8 action,
        bytes32 payloadHash,
        uint64 requestedAt,
        uint64 expiresAt
    ) external {
        AppStorage storage s = LibAppStorage.diamondStorage();
        s.intents[requestId] = IntentMeta({
            requestId: requestId,
            signer: signer,
            executor: executor,
            action: action,
            payloadHash: payloadHash,
            nonce: 0,
            requestedAt: requestedAt,
            expiresAt: expiresAt,
            state: IntentState.Pending
        });
    }

    /// @notice Set creator hash for a lab for testing
    function test_setCreatorPucHash(
        uint256 labId,
        bytes32 creatorPucHash
    ) external {
        AppStorage storage s = LibAppStorage.diamondStorage();
        s.creatorPucHashByLab[labId] = creatorPucHash;
    }

    /// @notice Set provider stake amount for testing
    /// @dev TEST ONLY - Directly sets the staked amount for a provider
    function test_setProviderStake(
        address provider,
        uint256 amount
    ) external {
        AppStorage storage s = LibAppStorage.diamondStorage();
        s.providerStakes[provider].stakedAmount = amount;
    }
}
