// SPDX-License-Identifier: GPL-3.0-or-later
pragma solidity ^0.8.33;

import {LibAccessControlEnumerable} from "./LibAccessControlEnumerable.sol";
import {LibAppStorage, AppStorage, LabBase} from "./LibAppStorage.sol";
import {LibERC721Storage} from "./LibERC721Storage.sol";

interface ILabFacetMint {
    function safeMintTo(
        address to,
        uint256 tokenId
    ) external;
    function burnToken(
        uint256 tokenId
    ) external;
}

library LibLabAdmin {
    using LibAccessControlEnumerable for AppStorage;

    error LabLegacyNotMigrated(uint256 labId);
    error LabCreatorMismatch(uint256 labId);
    error LabCreatorPucRequired();

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

    function addLab(
        string calldata _uri,
        uint96 _price,
        string calldata _accessUri,
        string calldata _accessKey,
        uint8 _resourceType
    ) internal {
        uint256 nextLabId = _createLab(_uri, _price, _accessUri, _accessKey, _resourceType, false);
        emit LabAdded(nextLabId, msg.sender, _uri, _price, _accessUri, _accessKey, _resourceType);
    }

    function addAndListLab(
        string calldata _uri,
        uint96 _price,
        string calldata _accessUri,
        string calldata _accessKey,
        uint8 _resourceType
    ) internal {
        uint256 nextLabId = _createLab(_uri, _price, _accessUri, _accessKey, _resourceType, true);
        emit LabAdded(nextLabId, msg.sender, _uri, _price, _accessUri, _accessKey, _resourceType);
        emit LabListed(nextLabId, msg.sender);
    }

    function updateLab(
        uint256 _labId,
        string calldata _uri,
        uint96 _price,
        string calldata _accessUri,
        string calldata _accessKey,
        uint8 _resourceType
    ) internal {
        require(_resourceType <= 1, "Invalid resource type");
        _requireExists(_labId);
        _requireOnlyTokenOwner(_labId);
        _validateLabParams(_uri, _accessUri, _accessKey);

        AppStorage storage s = _s();
        LabBase storage existingLab = s.labs[_labId];
        if (existingLab.resourceType != _resourceType) {
            require(!_hasActiveBookings(_labId), "Cannot change resource type with active bookings");
        }
        s.labs[_labId] = LabBase({
            uri: _uri,
            price: _price,
            accessURI: _accessUri,
            accessKey: _accessKey,
            createdAt: existingLab.createdAt,
            resourceType: _resourceType
        });
        emit LabUpdated(_labId, _uri, _price, _accessUri, _accessKey, _resourceType);
    }

    function setTokenURI(
        uint256 _labId,
        string calldata _tokenUri
    ) internal {
        _requireExists(_labId);
        _requireOnlyTokenOwner(_labId);
        require(bytes(_tokenUri).length > 0, "Token URI cannot be empty");

        _s().labs[_labId].uri = _tokenUri;
        emit LabURISet(_labId, _tokenUri);
    }

    function deleteLab(
        uint256 _labId
    ) internal {
        _requireExists(_labId);
        _requireOnlyTokenOwner(_labId);

        AppStorage storage s = _s();
        require(!_hasActiveBookings(_labId), "Cannot delete lab with uncollected reservations");

        if (s.tokenStatus[_labId]) {
            s.tokenStatus[_labId] = false;
            emit LabUnlisted(_labId, msg.sender);
        }

        ILabFacetMint(address(this)).burnToken(_labId);
        _removeActiveLabFromIndex(s, _labId);
        delete s.labs[_labId];
        emit LabDeleted(_labId);
    }

    function listLab(
        uint256 _labId
    ) internal {
        _requireExists(_labId);
        _requireOnlyTokenOwner(_labId);

        AppStorage storage s = _s();
        require(!s.tokenStatus[_labId], "Lab already listed");

        s.tokenStatus[_labId] = true;

        emit LabListed(_labId, msg.sender);
    }

    function unlistLab(
        uint256 _labId
    ) internal {
        _requireExists(_labId);
        _requireOnlyTokenOwner(_labId);

        AppStorage storage s = _s();
        require(s.tokenStatus[_labId], "Lab not listed");
        require(!_hasActiveBookings(_labId), "Cannot unlist lab with uncollected reservations");

        s.tokenStatus[_labId] = false;

        emit LabUnlisted(_labId, msg.sender);
    }

    function _requireLabProvider() internal view {
        require(_s()._isLabProvider(msg.sender), "Only one LabProvider can perform this action");
    }

    function _requireExists(
        uint256 _labId
    ) internal view {
        require(_s().activeLabIndexPlusOne[_labId] != 0, "Lab does not exist");
    }

    function _requireOnlyTokenOwner(
        uint256 _labId
    ) internal view {
        require(LibERC721Storage.ownerOf(_labId) == msg.sender, "Not the token owner");
    }

    function _requireLabCreator(
        uint256 _labId,
        string memory puc
    ) internal view {
        if (bytes(puc).length == 0) revert LabCreatorPucRequired();

        bytes32 creatorHash = _s().creatorPucHashByLab[_labId];
        if (creatorHash == bytes32(0)) revert LabLegacyNotMigrated(_labId);
        if (creatorHash != keccak256(bytes(puc))) revert LabCreatorMismatch(_labId);
    }

    function _validateLabParams(
        string calldata _uri,
        string calldata _accessUri,
        string calldata _accessKey
    ) internal pure {
        require(bytes(_uri).length > 0 && bytes(_uri).length <= 500, "Invalid URI length");
        require(bytes(_accessUri).length > 0 && bytes(_accessUri).length <= 500, "Invalid accessURI length");
        require(bytes(_accessKey).length > 0 && bytes(_accessKey).length <= 200, "Invalid accessKey length");
    }

    function _hasActiveBookings(
        uint256 _labId
    ) internal view returns (bool) {
        AppStorage storage s = _s();
        return s.labActiveReservationCount[_labId] > 0 || s.providerReceivableAccrued[_labId] > 0
            || s.providerSettlementQueue[_labId] > 0 || s.providerReceivableInvoiced[_labId] > 0
            || s.providerReceivableApproved[_labId] > 0 || s.providerReceivableDisputed[_labId] > 0;
    }

    function _createLab(
        string calldata _uri,
        uint96 _price,
        string calldata _accessUri,
        string calldata _accessKey,
        uint8 _resourceType,
        bool listImmediately
    ) private returns (uint256 nextLabId) {
        require(_resourceType <= 1, "Invalid resource type");
        _validateLabParams(_uri, _accessUri, _accessKey);

        AppStorage storage s = _s();
        nextLabId = s.labId + 1;

        ILabFacetMint(address(this)).safeMintTo(msg.sender, nextLabId);
        s.labId = nextLabId;

        s.labs[nextLabId] = LabBase({
            uri: _uri,
            price: _price,
            accessURI: _accessUri,
            accessKey: _accessKey,
            createdAt: uint32(block.timestamp),
            resourceType: _resourceType
        });
        _addActiveLabToIndex(s, nextLabId);

        if (listImmediately) {
            s.tokenStatus[nextLabId] = true;
        }
    }

    function _addActiveLabToIndex(
        AppStorage storage s,
        uint256 labId
    ) private {
        s.activeLabIds.push(labId);
        s.activeLabIndexPlusOne[labId] = s.activeLabIds.length;
    }

    function _removeActiveLabFromIndex(
        AppStorage storage s,
        uint256 labId
    ) private {
        uint256 indexPlusOne = s.activeLabIndexPlusOne[labId];
        if (indexPlusOne == 0) {
            return;
        }

        uint256 index = indexPlusOne - 1;
        uint256 lastIndex = s.activeLabIds.length - 1;

        if (index != lastIndex) {
            uint256 lastLabId = s.activeLabIds[lastIndex];
            s.activeLabIds[index] = lastLabId;
            s.activeLabIndexPlusOne[lastLabId] = index + 1;
        }

        s.activeLabIds.pop();
        delete s.activeLabIndexPlusOne[labId];
    }

    function _s() internal pure returns (AppStorage storage s) {
        return LibAppStorage.diamondStorage();
    }
}
