// SPDX-License-Identifier: GPL-3.0-or-later
pragma solidity ^0.8.31;

import {EnumerableSet} from "@openzeppelin/contracts/utils/structs/EnumerableSet.sol";
import {IERC721} from "@openzeppelin/contracts/token/ERC721/IERC721.sol";
import {BaseInstitutionalReservationFacet} from "../base/BaseInstitutionalReservationFacet.sol";
import {AppStorage, Reservation, INSTITUTION_ROLE} from "../../../libraries/LibAppStorage.sol";

/// @title InstitutionalReservationDenialFacet
/// @notice Denial functions for institutional reservations

contract InstitutionalReservationDenialFacet is BaseInstitutionalReservationFacet {
    using EnumerableSet for EnumerableSet.AddressSet;

    function denyInstitutionalReservationRequest(address inst, string calldata puc, bytes32 key) external {
        AppStorage storage s = _s();
        require(s.roleMembers[INSTITUTION_ROLE].contains(inst), "!i");
        address bk = s.institutionalBackends[inst];
        require(msg.sender == inst || (bk != address(0) && msg.sender == bk), "!a");
        Reservation storage r = s.reservations[key];
        require(r.labId != 0, "!r");
        address own = IERC721(address(this)).ownerOf(r.labId);
        bk = s.institutionalBackends[own];
        require(msg.sender == own || (bk != address(0) && msg.sender == bk), "!p");
        _denyInstitutionalReservationRequest(inst, puc, key);
    }

    function _denyInstitutionalReservationRequest(address inst, string calldata puc, bytes32 key) internal override {
        AppStorage storage s = _s();
        Reservation storage r = s.reservations[key];
        if (r.status != _PENDING) revert("!pnd");
        if (r.payerInstitution != inst) revert("!i");
        if (keccak256(bytes(puc)) != keccak256(bytes(r.puc))) revert("!puc");
        _cancelReservation(key);
        emit ReservationRequestDenied(key, r.labId);
    }
}
