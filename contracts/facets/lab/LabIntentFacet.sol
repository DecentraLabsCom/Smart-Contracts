// SPDX-License-Identifier: GPL-3.0-or-later
pragma solidity ^0.8.31;

import {AppStorage, LibAppStorage} from "../../libraries/LibAppStorage.sol";
import {LibIntent} from "../../libraries/LibIntent.sol";
import {ActionIntentPayload} from "../../libraries/IntentTypes.sol";
import {LibLabAdmin} from "../../libraries/LibLabAdmin.sol";

/// @title LabIntentFacet Contract
/// @author
/// - Juan Luis Ramos Villalón
/// - Luis de la Torre Cubillo
/// @notice Facet for lab operations via intent system. Split from LabFacet to reduce contract size.
/// @dev This facet handles intent-based operations for labs: add, update, delete, list, unlist with intents.
contract LabIntentFacet {
    /// @notice Intent lifecycle event for lab operations
    event LabIntentProcessed(
        bytes32 indexed requestId, uint256 labId, string action, address provider, bool success, string reason
    );
    event LabCreatorBound(uint256 indexed labId, bytes32 indexed pucHash);

    /// @dev Returns the AppStorage struct from the diamond storage slot.
    function _s() internal pure returns (AppStorage storage s) {
        s = LibAppStorage.diamondStorage();
    }

    /// @dev Consumes a pending intent ensuring the caller matches signer/executor
    function _consumeLabIntent(
        bytes32 requestId,
        uint8 action,
        ActionIntentPayload memory payload
    ) internal {
        require(payload.executor == msg.sender, "Executor must be caller");
        bytes32 payloadHash = LibIntent.hashActionPayload(payload);
        LibIntent.consumeIntent(requestId, action, payloadHash, msg.sender);
    }

    function _requireNewLabIntent(
        ActionIntentPayload calldata payload,
        string memory invalidLabIdReason,
        string memory missingPucHashReason
    ) internal pure {
        require(payload.labId == 0, invalidLabIdReason);
        require(payload.pucHash != bytes32(0), missingPucHashReason);
    }

    function _bindCreatorToLatestLab(
        bytes32 pucHash
    ) internal returns (uint256 labId) {
        AppStorage storage s = _s();
        labId = s.labId;
        s.pucHashByLab[labId] = pucHash;

        emit LabCreatorBound(labId, pucHash);
    }

    function _createLabWithIntent(
        bytes32 requestId,
        ActionIntentPayload calldata payload,
        uint8 action,
        string memory invalidLabIdReason,
        string memory missingPucHashReason,
        string memory actionName,
        bool listImmediately
    ) internal {
        LibLabAdmin._requireLabProvider();
        _requireNewLabIntent(payload, invalidLabIdReason, missingPucHashReason);
        _consumeLabIntent(requestId, action, payload);

        if (listImmediately) {
            LibLabAdmin.addAndListLab(
                payload.uri, payload.price, payload.accessURI, payload.accessKey, payload.resourceType
            );
        } else {
            LibLabAdmin.addLab(payload.uri, payload.price, payload.accessURI, payload.accessKey, payload.resourceType);
        }

        uint256 newLabId = _bindCreatorToLatestLab(payload.pucHash);
        emit LabIntentProcessed(requestId, newLabId, actionName, msg.sender, true, "");
    }

    /// @notice Adds a new Lab via intent and emits event with requestId.
    function addLabWithIntent(
        bytes32 requestId,
        ActionIntentPayload calldata payload
    ) external {
        _createLabWithIntent(
            requestId,
            payload,
            LibIntent.ACTION_LAB_ADD,
            "LAB_ADD: labId must be 0",
            "LAB_ADD: pucHash required",
            "LAB_ADD",
            false
        );
    }

    /// @notice Adds and lists a new Lab via intent and emits event with requestId.
    function addAndListLabWithIntent(
        bytes32 requestId,
        ActionIntentPayload calldata payload
    ) external {
        _createLabWithIntent(
            requestId,
            payload,
            LibIntent.ACTION_LAB_ADD_AND_LIST,
            "LAB_ADD_AND_LIST: labId must be 0",
            "LAB_ADD_AND_LIST: pucHash required",
            "LAB_ADD_AND_LIST",
            true
        );
    }

    /// @notice Updates a lab via intent
    function updateLabWithIntent(
        bytes32 requestId,
        ActionIntentPayload calldata payload
    ) external {
        require(payload.labId != 0, "LAB_UPDATE: labId required");
        _consumeLabIntent(requestId, LibIntent.ACTION_LAB_UPDATE, payload);
        LibLabAdmin._requireLabCreator(payload.labId, payload.pucHash);

        LibLabAdmin.updateLab(
            payload.labId, payload.uri, payload.price, payload.accessURI, payload.accessKey, payload.resourceType
        );
        emit LabIntentProcessed(requestId, payload.labId, "LAB_UPDATE", msg.sender, true, "");
    }

    /// @notice Deletes a lab via intent
    function deleteLabWithIntent(
        bytes32 requestId,
        ActionIntentPayload calldata payload
    ) external {
        require(payload.labId != 0, "LAB_DELETE: labId required");
        _consumeLabIntent(requestId, LibIntent.ACTION_LAB_DELETE, payload);
        LibLabAdmin._requireLabCreator(payload.labId, payload.pucHash);

        LibLabAdmin.deleteLab(payload.labId);
        emit LabIntentProcessed(requestId, payload.labId, "LAB_DELETE", msg.sender, true, "");
    }

    /// @notice Updates URI via intent and emits LabIntentProcessed
    function setTokenURIWithIntent(
        bytes32 requestId,
        ActionIntentPayload calldata payload
    ) external {
        require(payload.labId != 0, "LAB_SET_URI: labId required");
        _consumeLabIntent(requestId, LibIntent.ACTION_LAB_SET_URI, payload);
        LibLabAdmin._requireLabCreator(payload.labId, payload.pucHash);

        LibLabAdmin.setTokenURI(payload.labId, payload.tokenURI);
        emit LabIntentProcessed(requestId, payload.labId, "LAB_SET_URI", msg.sender, true, "");
    }

    /// @notice Lists a lab via intent
    function listLabWithIntent(
        bytes32 requestId,
        ActionIntentPayload calldata payload
    ) external {
        require(payload.labId != 0, "LAB_LIST: labId required");
        _consumeLabIntent(requestId, LibIntent.ACTION_LAB_LIST, payload);
        LibLabAdmin._requireLabCreator(payload.labId, payload.pucHash);

        LibLabAdmin.listLab(payload.labId);
        emit LabIntentProcessed(requestId, payload.labId, "LAB_LIST", msg.sender, true, "");
    }

    /// @notice Unlists a lab via intent
    function unlistLabWithIntent(
        bytes32 requestId,
        ActionIntentPayload calldata payload
    ) external {
        require(payload.labId != 0, "LAB_UNLIST: labId required");
        _consumeLabIntent(requestId, LibIntent.ACTION_LAB_UNLIST, payload);
        LibLabAdmin._requireLabCreator(payload.labId, payload.pucHash);

        LibLabAdmin.unlistLab(payload.labId);
        emit LabIntentProcessed(requestId, payload.labId, "LAB_UNLIST", msg.sender, true, "");
    }
}
