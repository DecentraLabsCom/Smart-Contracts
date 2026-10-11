// SPDX-License-Identifier: GPL-3.0-or-later
pragma solidity ^0.8.33;

import {EnumerableSet} from "@openzeppelin/contracts/utils/structs/EnumerableSet.sol";
import {AppStorage, LibAppStorage} from "../../libraries/LibAppStorage.sol";
import {LibLabAdmin} from "../../libraries/LibLabAdmin.sol";
import {LibRevenue} from "../../libraries/LibRevenue.sol";

/// @title LabAdminFacet
/// @author Luis de la Torre Cubillo, Juan Luis Ramos Villalón
/// @notice Administrative functions for lab management (CRUD operations)

contract LabAdminFacet {
    using EnumerableSet for EnumerableSet.AddressSet;

    error UnauthorizedCommissionAdmin();
    error CommissionLabDoesNotExist(uint256 labId);
    error CommissionBpsOutOfRange(uint16 commissionBps);

    event LabReservationCommissionUpdated(uint256 indexed labId, uint16 previousCommissionBps, uint16 newCommissionBps);
    event LabReservationCommissionReset(uint256 indexed labId, uint16 previousCommissionBps);

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

    /// @notice Sets the platform commission for future paid reservations of one lab.
    /// @dev Commission is expressed in basis points: 4,000 means 40% and 10,000 means 100%.
    function setLabReservationCommission(
        uint256 labId,
        uint16 commissionBps
    ) external onlyDefaultAdmin {
        AppStorage storage s = LibAppStorage.diamondStorage();
        _requireCommissionLabExists(s, labId);
        if (commissionBps > LibRevenue.MAX_LAB_COMMISSION_BPS) {
            revert CommissionBpsOutOfRange(commissionBps);
        }

        uint16 previousCommissionBps = LibRevenue.getLabReservationCommissionBps(labId);
        s.labReservationCommissionBps[labId] = commissionBps;
        s.labReservationCommissionOverride[labId] = true;
        emit LabReservationCommissionUpdated(labId, previousCommissionBps, commissionBps);
    }

    /// @notice Removes the per-lab override and restores the default commission.
    function clearLabReservationCommission(
        uint256 labId
    ) external onlyDefaultAdmin {
        AppStorage storage s = LibAppStorage.diamondStorage();
        _requireCommissionLabExists(s, labId);

        uint16 previousCommissionBps = LibRevenue.getLabReservationCommissionBps(labId);
        delete s.labReservationCommissionBps[labId];
        delete s.labReservationCommissionOverride[labId];
        emit LabReservationCommissionReset(labId, previousCommissionBps);
    }

    /// @notice Returns the effective platform commission and whether the lab overrides the default.
    function getLabReservationCommission(
        uint256 labId
    ) external view returns (uint16 commissionBps, bool hasOverride) {
        AppStorage storage s = LibAppStorage.diamondStorage();
        _requireCommissionLabExists(s, labId);
        hasOverride = s.labReservationCommissionOverride[labId];
        commissionBps = LibRevenue.getLabReservationCommissionBps(labId);
    }

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

    modifier onlyDefaultAdmin() {
        AppStorage storage s = LibAppStorage.diamondStorage();
        if (!s.roleMembers[s.DEFAULT_ADMIN_ROLE].contains(msg.sender)) revert UnauthorizedCommissionAdmin();
        _;
    }

    function _requireCommissionLabExists(
        AppStorage storage s,
        uint256 labId
    ) private view {
        if (s.activeLabIndexPlusOne[labId] == 0) revert CommissionLabDoesNotExist(labId);
    }
}
