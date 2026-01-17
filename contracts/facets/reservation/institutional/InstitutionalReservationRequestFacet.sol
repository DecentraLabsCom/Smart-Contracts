// SPDX-License-Identifier: GPL-3.0-or-later
pragma solidity ^0.8.31;

import {EnumerableSet} from "@openzeppelin/contracts/utils/structs/EnumerableSet.sol";
import {BaseInstitutionalReservationFacet} from "../base/BaseInstitutionalReservationFacet.sol";
import {LibInstitutionalReservation} from "../../../libraries/LibInstitutionalReservation.sol";

contract InstitutionalReservationRequestFacet is BaseInstitutionalReservationFacet {
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
        LibInstitutionalReservation.requestReservation(ip, puc, lid, st, en);
    }
}
