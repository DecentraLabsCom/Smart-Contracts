// SPDX-License-Identifier: GPL-3.0-or-later
pragma solidity ^0.8.31;

import {EnumerableSet} from "@openzeppelin/contracts/utils/structs/EnumerableSet.sol";
import {BaseInstitutionalReservationFacet} from "../base/BaseInstitutionalReservationFacet.sol";

interface IInstValidation {
    function validateInstRequest(address p, string calldata u, uint256 l, uint32 st, uint32 en) external returns (address, bytes32, address);
}

interface IInstCreation {
    struct InstInput { address p; address o; uint256 l; uint32 s; uint32 e; string u; bytes32 k; address t; }
    function createInstReservation(InstInput calldata i) external;
    function recordRecentInstReservation(uint256 l, address t, bytes32 k, uint32 st) external;
}

contract InstitutionalRequestFacet is BaseInstitutionalReservationFacet {
    using EnumerableSet for EnumerableSet.AddressSet;

    function institutionalReservationRequest(
        address ip,
        string calldata puc,
        uint256 lid,
        uint32 st,
        uint32 en
    ) external exists(lid) onlyInstitution(ip) {
        _institutionalReservationRequest(ip, puc, lid, st, en);
    }

    function _institutionalReservationRequest(
        address ip,
        string calldata puc,
        uint256 lid,
        uint32 st,
        uint32 en
    ) internal override {
        (address o, bytes32 k, address t) = IInstValidation(address(this)).validateInstRequest(ip, puc, lid, st, en);
        IInstCreation(address(this)).createInstReservation(IInstCreation.InstInput({
            p: ip, o: o, l: lid, s: st, e: en, u: puc, k: k, t: t
        }));
        IInstCreation(address(this)).recordRecentInstReservation(lid, t, k, st);
    }
}
