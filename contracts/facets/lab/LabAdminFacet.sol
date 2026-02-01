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
        string _accessKey
    );

    event LabUpdated(uint256 indexed _labId, string _uri, uint96 _price, string _accessUri, string _accessKey);

    event LabDeleted(uint256 indexed _labId);
    event LabURISet(uint256 indexed _labId, string _uri);
    event LabListed(uint256 indexed _labId, address indexed _provider);
    event LabUnlisted(uint256 indexed _labId, address indexed _provider);

    /// @notice Adds a new Lab with the specified details
    function addLab(
        string calldata _uri,
        uint96 _price,
        string calldata _accessUri,
        string calldata _accessKey
    ) external {
        LibLabAdmin._requireLabProvider();
        LibLabAdmin.addLab(_uri, _price, _accessUri, _accessKey);
    }

    /// @notice Adds a new Lab and immediately lists it for reservations
    function addAndListLab(
        string calldata _uri,
        uint96 _price,
        string calldata _accessUri,
        string calldata _accessKey
    ) external {
        LibLabAdmin._requireLabProvider();
        LibLabAdmin.addAndListLab(_uri, _price, _accessUri, _accessKey);
    }

    /// @notice Updates the Lab with the given ID
    function updateLab(
        uint256 _labId,
        string calldata _uri,
        uint96 _price,
        string calldata _accessUri,
        string calldata _accessKey
    ) external {
        LibLabAdmin.updateLab(_labId, _uri, _price, _accessUri, _accessKey);
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
