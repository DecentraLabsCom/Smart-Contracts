// SPDX-License-Identifier: GPL-3.0-or-later
pragma solidity ^0.8.33;

import {LibLabAdmin} from "../../libraries/LibLabAdmin.sol";

/// @title LabAdminFacet
/// @author Luis de la Torre Cubillo, Juan Luis Ramos Villalón
/// @notice Administrative functions for lab management (CRUD operations)

contract LabAdminFacet {
    event LabAdded(
        uint256 indexed _labId,
        address indexed _provider,
        string _uri,
        uint96 _price,
        string _accessUri,
        string _accessKey,
        uint8 _resourceType
    );

    event LabUpdated(
        uint256 indexed _labId, string _uri, uint96 _price, string _accessUri, string _accessKey, uint8 _resourceType
    );

    event LabDeleted(uint256 indexed _labId);
    event LabURISet(uint256 indexed _labId, string _uri);
    event LabListed(uint256 indexed _labId, address indexed _provider);
    event LabUnlisted(uint256 indexed _labId, address indexed _provider);
    event LabCreatorPucHashBound(uint256 indexed labId, bytes32 indexed pucHash, address indexed actor);

    /// @notice Adds a new Lab and binds its creator PUC hash atomically.
    function addLabWithPucHash(
        string calldata _uri,
        uint96 _price,
        string calldata _accessUri,
        string calldata _accessKey,
        uint8 _resourceType,
        bytes32 pucHash
    ) external {
        LibLabAdmin._requireLabProvider();
        LibLabAdmin.addLabWithPucHash(_uri, _price, _accessUri, _accessKey, _resourceType, pucHash);
    }

    /// @notice Adds and lists a new Lab with an atomic creator PUC binding.
    function addAndListLabWithPucHash(
        string calldata _uri,
        uint96 _price,
        string calldata _accessUri,
        string calldata _accessKey,
        uint8 _resourceType,
        bytes32 pucHash
    ) external {
        LibLabAdmin._requireLabProvider();
        LibLabAdmin.addAndListLabWithPucHash(_uri, _price, _accessUri, _accessKey, _resourceType, pucHash);
    }

    /// @notice Updates the Lab with the given ID
    function updateLab(
        uint256 _labId,
        string calldata _uri,
        uint96 _price,
        string calldata _accessUri,
        string calldata _accessKey,
        uint8 _resourceType
    ) external {
        LibLabAdmin.updateLab(_labId, _uri, _price, _accessUri, _accessKey, _resourceType);
    }

    /// @notice Sets the token URI for a specific lab
    function setTokenURI(
        uint256 _labId,
        string calldata _tokenUri
    ) external {
        LibLabAdmin.setTokenURI(_labId, _tokenUri);
    }

    /// @notice Deletes a Lab identified by `_labId`
    function deleteLab(
        uint256 _labId
    ) external {
        LibLabAdmin.deleteLab(_labId);
    }

    /// @notice Lists a lab for reservations
    function listLab(
        uint256 _labId
    ) external {
        LibLabAdmin.listLab(_labId);
    }

    /// @notice Unlists a lab from reservations
    function unlistLab(
        uint256 _labId
    ) external {
        LibLabAdmin.unlistLab(_labId);
    }
}
