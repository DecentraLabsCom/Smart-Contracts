// SPDX-License-Identifier: GPL-3.0-or-later
pragma solidity ^0.8.33;

import {IERC721} from "@openzeppelin/contracts/token/ERC721/IERC721.sol";
import {LibAccessControlEnumerable} from "./LibAccessControlEnumerable.sol";
import {LibAppStorage, AppStorage, LabBase} from "./LibAppStorage.sol";

interface ILabFacetMint {
    function safeMintTo(
        address to,
        uint256 tokenId
    ) external;
    function burnToken(
        uint256 tokenId
    ) external;
    function calculateRequiredStake(
        address provider,
        uint256 labCount
    ) external view returns (uint256);
}

library LibLabAdmin {
    using LibAccessControlEnumerable for AppStorage;

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

    function addLab(
        string calldata _uri,
        uint96 _price,
        string calldata _accessUri,
        string calldata _accessKey
    ) internal {
        _validateLabParams(_uri, _accessUri, _accessKey);

        AppStorage storage s = _s();
        uint256 nextLabId = s.labId + 1;

        ILabFacetMint(address(this)).safeMintTo(msg.sender, nextLabId);
        s.labId = nextLabId;

        s.labs[nextLabId].uri = _uri;
        s.labs[nextLabId].price = _price;
        s.labs[nextLabId].accessURI = _accessUri;
        s.labs[nextLabId].accessKey = _accessKey;
        s.labs[nextLabId].createdAt = uint32(block.timestamp);
        _addActiveLabToIndex(s, nextLabId);

        emit LabAdded(nextLabId, msg.sender, _uri, _price, _accessUri, _accessKey);
    }

    function addAndListLab(
        string calldata _uri,
        uint96 _price,
        string calldata _accessUri,
        string calldata _accessKey
    ) internal {
        _validateLabParams(_uri, _accessUri, _accessKey);

        AppStorage storage s = _s();

        uint256 newListedCount = s.providerStakes[msg.sender].listedLabsCount + 1;
        uint256 requiredStake = ILabFacetMint(address(this)).calculateRequiredStake(msg.sender, newListedCount);

        require(s.providerStakes[msg.sender].stakedAmount >= requiredStake, "Insufficient stake to list lab");

        uint256 nextLabId = s.labId + 1;

        ILabFacetMint(address(this)).safeMintTo(msg.sender, nextLabId);
        s.labId = nextLabId;

        s.labs[nextLabId].uri = _uri;
        s.labs[nextLabId].price = _price;
        s.labs[nextLabId].accessURI = _accessUri;
        s.labs[nextLabId].accessKey = _accessKey;
        s.labs[nextLabId].createdAt = uint32(block.timestamp);
        _addActiveLabToIndex(s, nextLabId);

        s.providerStakes[msg.sender].listedLabsCount = newListedCount;
        s.tokenStatus[nextLabId] = true;

        emit LabAdded(nextLabId, msg.sender, _uri, _price, _accessUri, _accessKey);
        emit LabListed(nextLabId, msg.sender);
    }

    function updateLab(
        uint256 _labId,
        string calldata _uri,
        uint96 _price,
        string calldata _accessUri,
        string calldata _accessKey
    ) internal {
        _requireExists(_labId);
        _requireOnlyTokenOwner(_labId);
        _validateLabParams(_uri, _accessUri, _accessKey);

        AppStorage storage s = _s();
        s.labs[_labId] = LabBase({
            uri: _uri, price: _price, accessURI: _accessUri, accessKey: _accessKey, createdAt: s.labs[_labId].createdAt
        });
        emit LabUpdated(_labId, _uri, _price, _accessUri, _accessKey);
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
            if (s.providerStakes[msg.sender].listedLabsCount > 0) {
                s.providerStakes[msg.sender].listedLabsCount--;
            }
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

        uint256 newListedCount = s.providerStakes[msg.sender].listedLabsCount + 1;
        uint256 requiredStake = ILabFacetMint(address(this)).calculateRequiredStake(msg.sender, newListedCount);

        require(s.providerStakes[msg.sender].stakedAmount >= requiredStake, "Insufficient stake to list lab");

        s.providerStakes[msg.sender].listedLabsCount = newListedCount;
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
        if (s.providerStakes[msg.sender].listedLabsCount > 0) {
            s.providerStakes[msg.sender].listedLabsCount--;
        }

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
        require(IERC721(address(this)).ownerOf(_labId) == msg.sender, "Not the token owner");
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
        return s.labActiveReservationCount[_labId] > 0 || s.pendingProviderPayout[_labId] > 0;
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
