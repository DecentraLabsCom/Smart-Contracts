// SPDX-License-Identifier: GPL-3.0-or-later
pragma solidity ^0.8.31;

import {
    LibInstitutionalReservationRequestValidation
} from "../../../libraries/LibInstitutionalReservationRequestValidation.sol";
import {IInstValidation} from "../../../libraries/LibInstitutionalReservation.sol";

contract InstitutionalReservationRequestValidationFacet is IInstValidation {
    function validateInstRequest(
        address p,
        bytes32 u,
        uint256 l,
        uint32 st,
        uint32 en
    ) external override returns (address o, bytes32 k, address t) {
        (o, k, t) = LibInstitutionalReservationRequestValidation.validateInstRequest(p, u, l, st, en);
    }
}
