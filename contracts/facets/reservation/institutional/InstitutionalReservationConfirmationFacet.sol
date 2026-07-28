// SPDX-License-Identifier: GPL-3.0-or-later
pragma solidity ^0.8.31;

import {LibInstitutionalReservationConfirmation} from "../../../libraries/LibInstitutionalReservationConfirmation.sol";

contract InstitutionalReservationConfirmationFacet {
    /// @notice Confirms an external request on behalf of the current lab
    /// owner or that owner's authorized backend. The payer institution is the
    /// treasury charged by the confirmation; it is not the caller authority.
    function confirmInstitutionalReservationRequestWithPucHash(
        address i,
        bytes32 k,
        bytes32 pucHash
    ) external {
        LibInstitutionalReservationConfirmation.confirmInstitutionalReservationRequestWithPucHash(i, k, pucHash);
    }
}
