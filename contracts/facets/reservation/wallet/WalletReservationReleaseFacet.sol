// SPDX-License-Identifier: GPL-3.0-or-later
pragma solidity ^0.8.31;

import {LibWalletRelease} from "../../../libraries/LibWalletRelease.sol";

/// @title WalletReservationReleaseFacet
/// @author
/// - Luis de la Torre Cubillo
/// - Juan Luis Ramos VillalÃ³n
/// @notice Wallet-only helper for releasing expired reservations
contract WalletReservationReleaseFacet {
    function releaseExpiredReservations(
        uint256 _labId,
        address _user,
        uint256 maxBatch
    ) external returns (uint256 processed) {
        return LibWalletRelease.releaseExpiredReservations(_labId, _user, maxBatch);
    }
}
