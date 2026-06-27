// SPDX-License-Identifier: GPL-3.0-or-later
pragma solidity ^0.8.31;

import {LibInstitutionalReservationConfirmation} from "../../../libraries/LibInstitutionalReservationConfirmation.sol";

contract InstitutionalReservationConfirmationFacet {
    function confirmInstitutionalReservationRequestWithPucHash(
        address i,
        bytes32 k,
        bytes32 pucHash
    ) external {
        LibInstitutionalReservationConfirmation.confirmInstitutionalReservationRequestWithPucHash(i, k, pucHash);
    }
}
