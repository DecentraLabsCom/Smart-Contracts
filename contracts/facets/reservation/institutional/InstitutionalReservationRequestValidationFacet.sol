// SPDX-License-Identifier: GPL-3.0-or-later
pragma solidity ^0.8.31;

import {LibInstitutionalReservationRequestValidation} from "../../../libraries/LibInstitutionalReservationRequestValidation.sol";

contract InstitutionalReservationRequestValidationFacet {
    function validateInstRequest(
        address p,
        string calldata u,
        uint256 l,
        uint32 st,
        uint32 en
    ) external returns (address o, bytes32 k, address t) {
        return LibInstitutionalReservationRequestValidation.validateInstRequest(p, u, l, st, en);
    }
}
