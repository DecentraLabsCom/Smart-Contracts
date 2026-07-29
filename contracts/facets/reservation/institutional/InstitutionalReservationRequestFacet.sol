// SPDX-License-Identifier: GPL-3.0-or-later
pragma solidity ^0.8.31;

import {EnumerableSet} from "@openzeppelin/contracts/utils/structs/EnumerableSet.sol";
import {AppStorage, LibAppStorage, INSTITUTION_ROLE} from "../../../libraries/LibAppStorage.sol";
import {LibERC721Storage} from "../../../libraries/LibERC721Storage.sol";
import {LibInstitutionalReservation} from "../../../libraries/LibInstitutionalReservation.sol";

contract InstitutionalReservationRequestFacet {
    using EnumerableSet for EnumerableSet.AddressSet;

    error TokenNotFound();
    error UnknownInstitution();
    error UnauthorizedInstitution();

    /// @notice Creates a pending institutional reservation request directly.
    /// @dev This selector is an institution-authorized administrative path. It
    ///      validates only the institution/backend caller and reservation
    ///      rules; it does not consume an intent and cannot verify WebAuthn.
    ///      The current Marketplace DIRECT_BOOKING flow does not call this
    ///      function; it calls institutionalDirectBookingWithIntent instead.
    function institutionalReservationRequest(
        address ip,
        bytes32 pucHash,
        uint256 lid,
        uint32 st,
        uint32 en
    ) external {
        _checkExists(lid);
        _onlyInstitution(ip);
        LibInstitutionalReservation.requestReservation(ip, pucHash, lid, st, en);
    }

    function _s() internal pure returns (AppStorage storage s) {
        return LibAppStorage.diamondStorage();
    }

    function _checkExists(
        uint256 lid
    ) internal view {
        if (LibERC721Storage.ownerOfOptional(lid) == address(0)) revert TokenNotFound();
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
