// SPDX-License-Identifier: GPL-3.0-or-later
pragma solidity ^0.8.31;

import {LibInstitutionalReservationConfirmation} from "../../../libraries/LibInstitutionalReservationConfirmation.sol";

contract InstitutionalReservationConfirmationFacet {
    function confirmInstitutionalReservationRequestWithPuc(
        address i,
        bytes32 k,
        string calldata puc
    ) external {
        LibInstitutionalReservationConfirmation.confirmInstitutionalReservationRequestWithPuc(i, k, puc);
    }
}
