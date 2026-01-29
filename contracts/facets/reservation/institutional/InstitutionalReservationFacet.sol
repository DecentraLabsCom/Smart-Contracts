// SPDX-License-Identifier: GPL-3.0-or-later
pragma solidity ^0.8.31;

import {LibInstitutionalReservationRelease} from "../../../libraries/LibInstitutionalReservationRelease.sol";

/// @title InstitutionalReservationFacet
/// @dev Facet for institutional reservation expired releases

contract InstitutionalReservationFacet {
    function releaseInstitutionalExpiredReservations(
        address institutionalProvider,
        string calldata puc,
        uint256 _labId,
        uint256 maxBatch
    ) external returns (uint256 processed) {
        return LibInstitutionalReservationRelease.releaseInstitutionalExpiredReservations(
            institutionalProvider, puc, _labId, maxBatch
        );
    }
}
