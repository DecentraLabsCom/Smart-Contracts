// SPDX-License-Identifier: GPL-3.0-or-later
pragma solidity ^0.8.31;

import {EnumerableSet} from "@openzeppelin/contracts/utils/structs/EnumerableSet.sol";
import {IERC721} from "@openzeppelin/contracts/token/ERC721/IERC721.sol";
import {AppStorage, LibAppStorage, INSTITUTION_ROLE} from "../../../libraries/LibAppStorage.sol";
import {LibInstitutionalReservation} from "../../../libraries/LibInstitutionalReservation.sol";

contract InstitutionalReservationRequestFacet {
    using EnumerableSet for EnumerableSet.AddressSet;

    error TokenNotFound();
    error UnknownInstitution();
    error UnauthorizedInstitution();

    function institutionalReservationRequest(
        address ip,
        string calldata puc,
        uint256 lid,
        uint32 st,
        uint32 en
    ) external {
        _checkExists(lid);
        _onlyInstitution(ip);
        LibInstitutionalReservation.requestReservation(ip, puc, lid, st, en);
    }

    function _s() internal pure returns (AppStorage storage s) {
        return LibAppStorage.diamondStorage();
    }

    function _checkExists(
        uint256 lid
    ) internal view {
        if (IERC721(address(this)).ownerOf(lid) == address(0)) revert TokenNotFound();
    }

    function _onlyInstitution(
        address institution
    ) internal view {
        AppStorage storage s = _s();
        if (!s.roleMembers[INSTITUTION_ROLE].contains(institution)) revert UnknownInstitution();
        address backend = s.institutionalBackends[institution];
        if (!(msg.sender == institution || (backend != address(0) && msg.sender == backend))) {
            revert UnauthorizedInstitution();
        }
    }
}
