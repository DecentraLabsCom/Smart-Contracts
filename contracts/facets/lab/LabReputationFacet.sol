// SPDX-License-Identifier: GPL-3.0-or-later
pragma solidity ^0.8.33;

import {EnumerableSet} from "@openzeppelin/contracts/utils/structs/EnumerableSet.sol";
import {Strings} from "@openzeppelin/contracts/utils/Strings.sol";
import {IERC721} from "@openzeppelin/contracts/token/ERC721/IERC721.sol";
import {LibAppStorage, AppStorage, LabReputation} from "../../libraries/LibAppStorage.sol";
import {LibReputation} from "../../libraries/LibReputation.sol";

/// @title LabReputationFacet
/// @notice Exposes lab reputation data and admin adjustments
contract LabReputationFacet {
    using EnumerableSet for EnumerableSet.AddressSet;

    modifier onlyDefaultAdminRole() {
        _onlyDefaultAdminRole();
        _;
    }

    function _onlyDefaultAdminRole() internal view {
        AppStorage storage s = LibAppStorage.diamondStorage();
        if (!s.roleMembers[s.DEFAULT_ADMIN_ROLE].contains(msg.sender)) {
            revert("Only default admin");
        }
    }

    function getLabReputation(uint256 labId)
        external
        view
        returns (
            int32 score,
            uint32 totalEvents,
            uint32 ownerCancellations,
            uint32 institutionalCancellations,
            uint64 lastUpdated
        )
    {
        LabReputation storage rep = LibAppStorage.diamondStorage().labReputation[labId];
        return (
            rep.score,
            rep.totalEvents,
            rep.ownerCancellations,
            rep.institutionalCancellations,
            rep.lastUpdated
        );
    }

    function getLabScore(uint256 labId) external view returns (int32 score) {
        return LibAppStorage.diamondStorage().labReputation[labId].score;
    }

    /// @notice Get the weighted reputation rating for a lab
    /// @dev Returns a rating between -1000 and 1000 representing success ratio
    ///      For new labs with no events, returns 0 (neutral)
    /// @param labId The lab ID to query
    /// @return rating The weighted reputation score
    function getLabRating(uint256 labId) external view returns (int32 rating) {
        LabReputation storage rep = LibAppStorage.diamondStorage().labReputation[labId];
        return _computeRating(rep.score, rep.totalEvents);
    }

    function adjustLabReputation(uint256 labId, int32 delta, string calldata reason)
        external
        onlyDefaultAdminRole
    {
        LibReputation.adjustScore(labId, delta, reason);
    }

    function setLabReputation(uint256 labId, int32 newScore, string calldata reason)
        external
        onlyDefaultAdminRole
    {
        LibReputation.setScore(labId, newScore, reason);
    }

    function tokenURIWithReputation(uint256 labId) external view returns (string memory) {
        IERC721(address(this)).ownerOf(labId);
        AppStorage storage s = LibAppStorage.diamondStorage();
        LabReputation storage rep = s.labReputation[labId];
        int32 rating = _computeRating(rep.score, rep.totalEvents);
        string memory ratingStr = _intToString(rating);
        string memory scoreStr = _intToString(rep.score);
        return string(
            abi.encodePacked(
                "data:application/json;utf8,{\"name\":\"Lab #",
                Strings.toString(labId),
                "\",\"external_url\":\"",
                s.labs[labId].uri,
                "\",\"attributes\":[{\"trait_type\":\"reputation_rating\",\"value\":",
                ratingStr,
                "},{\"trait_type\":\"total_score\",\"value\":",
                scoreStr,
                "},{\"trait_type\":\"reputation_events\",\"value\":",
                Strings.toString(rep.totalEvents),
                "},{\"trait_type\":\"owner_cancellations\",\"value\":",
                Strings.toString(rep.ownerCancellations),
                "},{\"trait_type\":\"institution_cancellations\",\"value\":",
                Strings.toString(rep.institutionalCancellations),
                "}]}"));
    }

    function _intToString(int32 value) internal pure returns (string memory) {
        if (value >= 0) {
            return Strings.toString(uint256(uint32(value)));
        }
        int256 signed = int256(value);
        uint256 abs = uint256(-signed);
        return string(abi.encodePacked("-", Strings.toString(abs)));
    }

    function _computeRating(int32 score, uint32 totalEvents) private pure returns (int32 rating) {
        if (totalEvents == 0) return 0;
        rating = int32((int256(score) * 1000) / int256(uint256(totalEvents)));
        if (rating > 1000) return 1000;
        if (rating < -1000) return -1000;
        return rating;
    }
}
