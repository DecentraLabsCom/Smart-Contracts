// SPDX-License-Identifier: GPL-3.0-or-later
pragma solidity ^0.8.31;

import {BaseInstitutionalReservationFacet} from "../base/BaseInstitutionalReservationFacet.sol";

/// @title InstitutionalReservationCoreFacet
/// @author Luis de la Torre Cubillo, Juan Luis Ramos Villalón
/// @notice Stub facet for institutional reservations - actual logic moved to specialized facets
/// @dev All functions redirect to InstitutionalReservationRequestFacet, InstitutionalReservationConfirmationFacet

contract InstitutionalReservationCoreFacet is BaseInstitutionalReservationFacet {

    /// @notice Create institutional reservation request - MOVED to InstitutionalReservationRequestFacet
    function institutionalReservationRequest(address, string calldata, uint256, uint32, uint32) external pure {
        revert("Use InstitutionalReservationRequestFacet");
    }

    /// @notice Confirm institutional reservation - MOVED to InstitutionalReservationConfirmationFacet
    function confirmInstitutionalReservationRequest(address, bytes32) external pure {
        revert("Use InstitutionalReservationConfirmationFacet");
    }

    /// @notice Deny institutional reservation - MOVED to InstitutionalReservationDenialFacet
    function denyInstitutionalReservationRequest(address, string calldata, bytes32) external pure {
        revert("Use InstitutionalReservationDenialFacet");
    }
}
