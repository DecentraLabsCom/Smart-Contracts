// SPDX-License-Identifier: GPL-3.0-or-later
pragma solidity ^0.8.33;

import {IERC721} from "@openzeppelin/contracts/token/ERC721/IERC721.sol";
import {EnumerableSet} from "@openzeppelin/contracts/utils/structs/EnumerableSet.sol";
import {AppStorage, LabBase} from "../../libraries/LibAppStorage.sol";
import {LibAppStorage} from "../../libraries/LibAppStorage.sol";
import {LibAccessControlEnumerable} from "../../libraries/LibAccessControlEnumerable.sol";

using EnumerableSet for EnumerableSet.Bytes32Set;

/// @title LabAdminFacet
/// @author Luis de la Torre Cubillo, Juan Luis Ramos Villalón
/// @notice Administrative functions for lab management (CRUD operations)
/// @dev Extracted from LabFacet to reduce contract size below EIP-170 limit

interface ILabFacetMint {
    function safeMintTo(address to, uint256 tokenId) external;
    function burnToken(uint256 tokenId) external;
    function calculateRequiredStake(address provider, uint256 labCount) external view returns (uint256);
}

contract LabAdminFacet {
    using LibAccessControlEnumerable for AppStorage;

    // Status constants (must match LabFacet and ReservationFacet)
    uint8 internal constant _CONFIRMED = 1;
    uint8 internal constant _IN_USE = 2;
    uint8 internal constant _COMPLETED = 3;

    event LabAdded(
        uint256 indexed _labId,
        address indexed _provider,
        string _uri,
        uint96 _price,
        string _accessUri,
        string _accessKey
    );

    event LabUpdated(
        uint256 indexed _labId,
        string _uri,
        uint96 _price,
        string _accessUri,
        string _accessKey
    );

    event LabDeleted(uint256 indexed _labId);
    event LabURISet(uint256 indexed _labId, string _uri);
    event LabListed(uint256 indexed _labId, address indexed _provider);
    event LabUnlisted(uint256 indexed _labId, address indexed _provider);

    function _s() internal pure returns (AppStorage storage s) {
        s = LibAppStorage.diamondStorage();
    }

    modifier isLabProvider() {
        _isLabProvider();
        _;
    }

    function _isLabProvider() internal view {
        require(_s()._isLabProvider(msg.sender), "Only one LabProvider can perform this action");
    }

    modifier exists(uint256 _labId) {
        _exists(_labId);
        _;
    }

    function _exists(uint256 _labId) internal view {
        require(_labId > 0 && _labId <= _s().labId, "Lab does not exist");
    }

    modifier onlyTokenOwner(uint256 _labId) {
        _onlyTokenOwner(_labId);
        _;
    }

    function _onlyTokenOwner(uint256 _labId) internal view {
        require(IERC721(address(this)).ownerOf(_labId) == msg.sender, "Not the token owner");
    }

    /// @notice Adds a new Lab with the specified details
    function addLab(
        string calldata _uri,
        uint96 _price,
        string calldata _accessUri,
        string calldata _accessKey
    ) external isLabProvider {
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
        
        emit LabAdded(nextLabId, msg.sender, _uri, _price, _accessUri, _accessKey);
    }

    /// @notice Adds a new Lab and immediately lists it for reservations
    function addAndListLab(
        string calldata _uri,
        uint96 _price,
        string calldata _accessUri,
        string calldata _accessKey
    ) external isLabProvider {
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
        
        s.providerStakes[msg.sender].listedLabsCount = newListedCount;
        s.tokenStatus[nextLabId] = true;
        
        emit LabAdded(nextLabId, msg.sender, _uri, _price, _accessUri, _accessKey);
        emit LabListed(nextLabId, msg.sender);
    }

    /// @notice Updates the Lab with the given ID
    function updateLab(
        uint256 _labId,
        string calldata _uri,
        uint96 _price,
        string calldata _accessUri,
        string calldata _accessKey
    ) external exists(_labId) onlyTokenOwner(_labId) {
        _validateLabParams(_uri, _accessUri, _accessKey);
       
        _s().labs[_labId] = LabBase({
            uri: _uri,
            price: _price,
            accessURI: _accessUri,
            accessKey: _accessKey,
            createdAt: _s().labs[_labId].createdAt
        });
        emit LabUpdated(_labId, _uri, _price, _accessUri, _accessKey);
    }

    /// @notice Sets the token URI for a specific lab
    function setTokenURI(
        uint256 _labId,
        string calldata _tokenUri
    ) external exists(_labId) onlyTokenOwner(_labId) {
        require(bytes(_tokenUri).length > 0, "Token URI cannot be empty");
        
        _s().labs[_labId].uri = _tokenUri;
        emit LabURISet(_labId, _tokenUri);
    }

    /// @notice Deletes a Lab identified by `_labId`
    function deleteLab(uint256 _labId) external exists(_labId) onlyTokenOwner(_labId) {
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
        delete s.labs[_labId];
        emit LabDeleted(_labId);
    }

    /// @notice Lists a lab for reservations
    function listLab(uint256 _labId) external exists(_labId) onlyTokenOwner(_labId) {
        AppStorage storage s = _s();
        require(!s.tokenStatus[_labId], "Lab already listed");
        
        uint256 newListedCount = s.providerStakes[msg.sender].listedLabsCount + 1;
        uint256 requiredStake = ILabFacetMint(address(this)).calculateRequiredStake(msg.sender, newListedCount);
        
        require(s.providerStakes[msg.sender].stakedAmount >= requiredStake, "Insufficient stake to list lab");
        
        s.providerStakes[msg.sender].listedLabsCount = newListedCount;
        s.tokenStatus[_labId] = true;
        
        emit LabListed(_labId, msg.sender);
    }

    /// @notice Unlists a lab from reservations
    function unlistLab(uint256 _labId) external exists(_labId) onlyTokenOwner(_labId) {
        AppStorage storage s = _s();
        require(s.tokenStatus[_labId], "Lab not listed");
        require(!_hasActiveBookings(_labId), "Cannot unlist lab with uncollected reservations");
        
        s.tokenStatus[_labId] = false;
        
        if (s.providerStakes[msg.sender].listedLabsCount > 0) {
            s.providerStakes[msg.sender].listedLabsCount--;
        }
        
        emit LabUnlisted(_labId, msg.sender);
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

    function _hasActiveBookings(uint256 _labId) internal view returns (bool) {
        AppStorage storage s = _s();
        return s.labActiveReservationCount[_labId] > 0 || s.pendingProviderPayout[_labId] > 0;
    }
}
