// SPDX-License-Identifier: GPL-3.0-or-later
pragma solidity ^0.8.23;

import {IntentMeta, ReservationIntentPayload, ActionIntentPayload} from "../libraries/IntentTypes.sol";
import {LibIntent} from "../libraries/LibIntent.sol";
import {LibAppStorage, AppStorage} from "../libraries/LibAppStorage.sol";
import {EnumerableSet} from "@openzeppelin/contracts/utils/structs/EnumerableSet.sol";

/// @title IntentRegistryFacet
/// @notice Registers, cancels and exposes intents used by *WithIntent flows
contract IntentRegistryFacet {
    using EnumerableSet for EnumerableSet.AddressSet;

    modifier onlyDefaultAdmin() {
        AppStorage storage s = _s();
        require(s.roleMembers[s.DEFAULT_ADMIN_ROLE].contains(msg.sender), "Only default admin");
        _;
    }

    /// @notice Register a reservation intent (request / cancel request)
    function registerReservationIntent(
        IntentMeta calldata meta,
        ReservationIntentPayload calldata payload,
        bytes calldata signature
    ) external onlyDefaultAdmin {
        require(meta.signer == msg.sender, "Signer must be admin caller");
        LibIntent.registerReservationIntent(meta, payload, signature);
    }

    /// @notice Register an action intent (lab actions or booking cancellation)
    function registerActionIntent(
        IntentMeta calldata meta,
        ActionIntentPayload calldata payload,
        bytes calldata signature
    ) external onlyDefaultAdmin {
        require(meta.signer == msg.sender, "Signer must be admin caller");
        LibIntent.registerActionIntent(meta, payload, signature);
    }

    /// @notice Cancel a pending intent (only signer)
    function cancelIntent(bytes32 requestId) external {
        LibIntent.cancelIntent(requestId, msg.sender);
    }

    /// @notice Read stored metadata for an intent
    function getIntent(bytes32 requestId) external view returns (IntentMeta memory) {
        return LibIntent.getIntent(requestId);
    }

    /// @notice Next nonce expected for a signer
    function nextIntentNonce(address signer) external view returns (uint256) {
        return LibIntent.nextNonce(signer);
    }

    function _s() internal pure returns (AppStorage storage s) {
        return LibAppStorage.diamondStorage();
    }
}
