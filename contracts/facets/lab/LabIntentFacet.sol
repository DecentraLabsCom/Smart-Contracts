// SPDX-License-Identifier: GPL-3.0-or-later
pragma solidity ^0.8.31;

import {AppStorage, LibAppStorage} from "../../libraries/LibAppStorage.sol";
import {LibAccessControlEnumerable} from "../../libraries/LibAccessControlEnumerable.sol";
import {LibIntent} from "../../libraries/LibIntent.sol";
import {ActionIntentPayload} from "../../libraries/IntentTypes.sol";

/// @dev Interface to call LabFacet functions
interface ILabFacet {
    function addLab(string calldata _uri, uint96 _price, string calldata _accessUri, string calldata _accessKey) external;
    function addAndListLab(string calldata _uri, uint96 _price, string calldata _accessUri, string calldata _accessKey) external;
    function updateLab(uint256 _labId, string calldata _uri, uint96 _price, string calldata _accessUri, string calldata _accessKey) external;
    function setTokenURI(uint256 _labId, string calldata _tokenUri) external;
    function deleteLab(uint256 _labId) external;
    function listToken(uint256 tokenId) external;
    function unlistToken(uint256 tokenId) external;
}

/// @title LabIntentFacet Contract
/// @author
/// - Juan Luis Ramos Villalón
/// - Luis de la Torre Cubillo
/// @notice Facet for lab operations via intent system. Split from LabFacet to reduce contract size.
/// @dev This facet handles intent-based operations for labs: add, update, delete, list, unlist with intents.
contract LabIntentFacet {
    using LibAccessControlEnumerable for AppStorage;

    /// @notice Intent lifecycle event for lab operations
    event LabIntentProcessed(bytes32 indexed requestId, uint256 labId, string action, address provider, bool success, string reason);

    /// @dev Returns the AppStorage struct from the diamond storage slot.
    function _s() internal pure returns (AppStorage storage s) {
        s = LibAppStorage.diamondStorage();
    }

    /// @dev Modifier to restrict access to functions that can only be executed by the LabProvider.
    modifier isLabProvider() {
        _isLabProvider();
        _;
    }

    function _isLabProvider() internal view {
        require(
            _s()._isLabProvider(msg.sender),
            "Only one LabProvider can perform this action"
        );
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

    /// @notice Adds a new Lab via intent and emits event with requestId.
    function addLabWithIntent(
        bytes32 requestId,
        ActionIntentPayload calldata payload
    ) external isLabProvider {
        require(payload.labId == 0, "LAB_ADD: labId must be 0");
        _consumeLabIntent(requestId, LibIntent.ACTION_LAB_ADD, payload);

        // Delegate to LabFacet via delegatecall so msg.sender stays the original executor
        {
            (bool ok, bytes memory ret) = address(this).delegatecall(
                abi.encodeWithSignature(
                    "addLab(string,uint96,string,string)",
                    payload.uri,
                    payload.price,
                    payload.accessURI,
                    payload.accessKey
                )
            );
            if (!ok) {
                if (ret.length > 0) {
                    assembly {
                        revert(add(ret, 32), mload(ret))
                    }
                }
                revert();
            }
        }
        uint256 newLabId = _s().labId;
        emit LabIntentProcessed(requestId, newLabId, "LAB_ADD", msg.sender, true, "");
    }

    /// @notice Adds and lists a new Lab via intent and emits event with requestId.
    function addAndListLabWithIntent(
        bytes32 requestId,
        ActionIntentPayload calldata payload
    ) external isLabProvider {
        require(payload.labId == 0, "LAB_ADD_AND_LIST: labId must be 0");
        _consumeLabIntent(requestId, LibIntent.ACTION_LAB_ADD_AND_LIST, payload);

        // Delegate to LabFacet via delegatecall so msg.sender stays the original executor
        {
            (bool ok, bytes memory ret) = address(this).delegatecall(
                abi.encodeWithSignature(
                    "addAndListLab(string,uint96,string,string)",
                    payload.uri,
                    payload.price,
                    payload.accessURI,
                    payload.accessKey
                )
            );
            if (!ok) {
                if (ret.length > 0) {
                    assembly {
                        revert(add(ret, 32), mload(ret))
                    }
                }
                revert();
            }
        }
        uint256 newLabId = _s().labId;
        emit LabIntentProcessed(requestId, newLabId, "LAB_ADD_AND_LIST", msg.sender, true, "");
    }

    /// @notice Updates a lab via intent
    function updateLabWithIntent(
        bytes32 requestId,
        ActionIntentPayload calldata payload
    ) external {
        require(payload.labId != 0, "LAB_UPDATE: labId required");
        _consumeLabIntent(requestId, LibIntent.ACTION_LAB_UPDATE, payload);

        // Delegate to LabFacet via delegatecall so msg.sender stays the original executor
        {
            (bool ok, bytes memory ret) = address(this).delegatecall(
                abi.encodeWithSignature(
                    "updateLab(uint256,string,uint96,string,string)",
                    payload.labId,
                    payload.uri,
                    payload.price,
                    payload.accessURI,
                    payload.accessKey
                )
            );
            if (!ok) {
                if (ret.length > 0) {
                    assembly {
                        revert(add(ret, 32), mload(ret))
                    }
                }
                revert();
            }
        }
        emit LabIntentProcessed(requestId, payload.labId, "LAB_UPDATE", msg.sender, true, "");
    }

    /// @notice Deletes a lab via intent
    function deleteLabWithIntent(
        bytes32 requestId,
        ActionIntentPayload calldata payload
    ) external {
        require(payload.labId != 0, "LAB_DELETE: labId required");
        _consumeLabIntent(requestId, LibIntent.ACTION_LAB_DELETE, payload);

        // Delegate to LabFacet via delegatecall so msg.sender stays the original executor
        {
            (bool ok, bytes memory ret) = address(this).delegatecall(
                abi.encodeWithSignature(
                    "deleteLab(uint256)",
                    payload.labId
                )
            );
            if (!ok) {
                if (ret.length > 0) {
                    assembly {
                        revert(add(ret, 32), mload(ret))
                    }
                }
                revert();
            }
        }
        emit LabIntentProcessed(requestId, payload.labId, "LAB_DELETE", msg.sender, true, "");
    }

    /// @notice Updates URI via intent and emits LabIntentProcessed
    function setTokenURIWithIntent(
        bytes32 requestId,
        ActionIntentPayload calldata payload
    ) external {
        require(payload.labId != 0, "LAB_SET_URI: labId required");
        _consumeLabIntent(requestId, LibIntent.ACTION_LAB_SET_URI, payload);

        // Delegate to LabFacet via delegatecall so msg.sender stays the original executor
        {
            (bool ok, bytes memory ret) = address(this).delegatecall(
                abi.encodeWithSignature(
                    "setTokenURI(uint256,string)",
                    payload.labId,
                    payload.tokenURI
                )
            );
            if (!ok) {
                if (ret.length > 0) {
                    assembly {
                        revert(add(ret, 32), mload(ret))
                    }
                }
                revert();
            }
        }
        emit LabIntentProcessed(requestId, payload.labId, "LAB_SET_URI", msg.sender, true, "");
    }

    /// @notice Lists a lab via intent
    function listLabWithIntent(bytes32 requestId, ActionIntentPayload calldata payload) external {
        require(payload.labId != 0, "LAB_LIST: labId required");
        _consumeLabIntent(requestId, LibIntent.ACTION_LAB_LIST, payload);

        // Delegate to LabFacet via delegatecall so msg.sender stays the original executor
        {
            (bool ok, bytes memory ret) = address(this).delegatecall(
                abi.encodeWithSignature(
                    "listToken(uint256)",
                    payload.labId
                )
            );
            if (!ok) {
                if (ret.length > 0) {
                    assembly {
                        revert(add(ret, 32), mload(ret))
                    }
                }
                revert();
            }
        }
        emit LabIntentProcessed(requestId, payload.labId, "LAB_LIST", msg.sender, true, "");
    }

    /// @notice Unlists a lab via intent
    function unlistLabWithIntent(bytes32 requestId, ActionIntentPayload calldata payload) external {
        require(payload.labId != 0, "LAB_UNLIST: labId required");
        _consumeLabIntent(requestId, LibIntent.ACTION_LAB_UNLIST, payload);

        // Delegate to LabFacet via delegatecall so msg.sender stays the original executor
        {
            (bool ok, bytes memory ret) = address(this).delegatecall(
                abi.encodeWithSignature(
                    "unlistToken(uint256)",
                    payload.labId
                )
            );
            if (!ok) {
                if (ret.length > 0) {
                    assembly {
                        revert(add(ret, 32), mload(ret))
                    }
                }
                revert();
            }
        }
        emit LabIntentProcessed(requestId, payload.labId, "LAB_UNLIST", msg.sender, true, "");
    }
}
