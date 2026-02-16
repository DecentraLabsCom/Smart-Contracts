// SPDX-License-Identifier: GPL-3.0-or-later
pragma solidity ^0.8.33;

import {AppStorage, Lab, LibAppStorage} from "../../libraries/LibAppStorage.sol";
import {IERC721} from "@openzeppelin/contracts/token/ERC721/IERC721.sol";

/// @title LabQueryFacet Contract
/// @author
/// - Juan Luis Ramos Villalón
/// - Luis de la Torre Cubillo
/// @notice Read-only facet for querying Lab data. Split from LabFacet to reduce contract size.
/// @dev This facet provides query functions that don't modify state.
contract LabQueryFacet {
    /// @dev Modifier to check if a lab exists and is currently active (not deleted/burned).
    modifier exists(
        uint256 _labId
    ) {
        _exists(_labId);
        _;
    }

    function _exists(
        uint256 _labId
    ) internal view {
        require(_labExists(_labId), "Lab does not exist");
    }

    function _labExists(
        uint256 _labId
    ) internal view returns (bool) {
        return _s().activeLabIndexPlusOne[_labId] != 0;
    }

    /// @dev Returns the AppStorage struct from the diamond storage slot.
    function _s() internal pure returns (AppStorage storage s) {
        s = LibAppStorage.diamondStorage();
    }

    /// @notice Retrieves the details of a Lab by its ID.
    /// @dev This function returns the Lab details, including its ID, URI, and price.
    /// @param _labId The ID of the Lab to retrieve.
    /// @return A Lab structure containing the details of the specified Lab.
    function getLab(
        uint256 _labId
    ) external view exists(_labId) returns (Lab memory) {
        return Lab({labId: _labId, base: _s().labs[_labId]});
    }

    /// @notice Retrieves a paginated list of lab token IDs
    /// @dev Returns a subset of lab IDs to avoid gas limit issues with large datasets
    ///      Order follows internal active index storage and may change after deletions.
    /// @param offset The starting index for pagination (0-based)
    /// @param limit The maximum number of labs to return (max 100)
    /// @return ids Array of lab token IDs for the requested page
    /// @return total The total number of existing labs available (excluding deleted/burned IDs)
    /// @custom:example To get first 50 labs: getLabsPaginated(0, 50)
    /// @custom:example To get next 50 labs: getLabsPaginated(50, 50)
    function getLabsPaginated(
        uint256 offset,
        uint256 limit
    ) external view returns (uint256[] memory ids, uint256 total) {
        require(limit > 0 && limit <= 100, "Limit must be between 1 and 100");

        AppStorage storage s = _s();
        total = s.activeLabIds.length;

        if (offset >= total) {
            return (new uint256[](0), total);
        }

        uint256 end = offset + limit;
        if (end > total) {
            end = total;
        }

        uint256 count = end - offset;
        ids = new uint256[](count);

        for (uint256 i = 0; i < count;) {
            ids[i] = s.activeLabIds[offset + i];
            unchecked {
                ++i;
            }
        }

        return (ids, total);
    }

    /// @notice Returns the current lab counter (total minted labs)
    /// @return The highest lab ID that has been minted
    function getLabCount() external view returns (uint256) {
        return _s().labId;
    }

    /// @notice Checks if a lab is currently listed for reservations
    /// @param _labId The ID of the lab to check
    /// @return True if the lab is listed, false otherwise
    function isLabListed(
        uint256 _labId
    ) external view returns (bool) {
        return _s().tokenStatus[_labId];
    }

    /// @notice Returns the price of a lab (per second, LAB base units)
    /// @param _labId The ID of the lab
    /// @return The price per second in LAB base units
    function getLabPrice(
        uint256 _labId
    ) external view exists(_labId) returns (uint96) {
        return _s().labs[_labId].price;
    }

    /// @notice Returns the authentication URI for a lab by resolving it from the provider
    /// @dev This function resolves the lab's provider and returns their authURI
    /// @param _labId The ID of the lab
    /// @return The authentication service URI from the provider
    function getLabAuthURI(
        uint256 _labId
    ) external view exists(_labId) returns (string memory) {
        address provider = IERC721(address(this)).ownerOf(_labId);
        return _s().providers[provider].authURI;
    }

    /// @notice Returns the access URI for a lab
    /// @param _labId The ID of the lab
    /// @return The access URI for the lab services
    function getLabAccessURI(
        uint256 _labId
    ) external view exists(_labId) returns (string memory) {
        return _s().labs[_labId].accessURI;
    }

    /// @notice Returns the access key for a lab
    /// @param _labId The ID of the lab
    /// @return The public access key for routing
    function getLabAccessKey(
        uint256 _labId
    ) external view exists(_labId) returns (string memory) {
        return _s().labs[_labId].accessKey;
    }

    /// @notice Returns the age of a lab in seconds since registration
    /// @param _labId The ID of the lab
    /// @return The age in seconds
    function getLabAge(
        uint256 _labId
    ) external view exists(_labId) returns (uint256) {
        return block.timestamp - _s().labs[_labId].createdAt;
    }
}
