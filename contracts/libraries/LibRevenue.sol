// SPDX-License-Identifier: GPL-3.0-or-later
pragma solidity ^0.8.31;

import {LibAppStorage} from "./LibAppStorage.sol";

/// @title LibRevenue - Revenue and fee calculations
/// @dev Library for pure calculations to reduce facet bytecode.
///      Only provider amounts are tracked on-chain; the platform margin is
///      implicit and computed off-chain.
library LibRevenue {
    uint256 internal constant REVENUE_DENOMINATOR = 100;
    uint256 internal constant REVENUE_PROVIDER = 70;

    /// @dev Fixed platform booking fee for zero-priced institutional reservations.
    ///      Same-institution reservations cost two credits; cross-institutional
    ///      reservations cost one credit. These fees are charged separately
    ///      from the lab price and are therefore non-refundable booking charges.
    uint256 internal constant SAME_INSTITUTION_RESERVATION_FEE = LibAppStorage.RAW_PER_CREDIT * 2;
    uint256 internal constant CROSS_INSTITUTION_RESERVATION_FEE = LibAppStorage.RAW_PER_CREDIT;

    // Physical-lab pre-start cancellation: 10% total, split 6% provider / 4% platform.
    uint256 internal constant CANCEL_FEE_TOTAL = 10;
    uint256 internal constant CANCEL_FEE_PROVIDER = 6;
    // Physical-lab no-show: 25% total, split 15% provider / 10% platform.
    uint256 internal constant NO_SHOW_FEE_TOTAL = 25;
    uint256 internal constant NO_SHOW_FEE_PROVIDER = 15;

    /// @dev Computes a scaled share and clamps to uint96 to avoid unsafe downcasts.
    function _safeScaledShare(
        uint96 price,
        uint256 numerator,
        uint256 denominator
    ) private pure returns (uint96) {
        uint256 raw = (uint256(price) * numerator) / denominator;
        if (raw > type(uint96).max) {
            return type(uint96).max;
        }
        return uint96(raw);
    }

    function calculateRevenueSplit(
        uint96 price
    ) internal pure returns (uint96 providerShare) {
        if (price == 0) {
            return 0;
        }

        providerShare = _safeScaledShare(price, REVENUE_PROVIDER, REVENUE_DENOMINATOR);
    }

    /// @notice Calculates the platform charge for an institutional reservation.
    /// @dev Priced reservations pay the lab price only. A zero-priced reservation
    ///      pays a fixed fee based on whether payer and provider are the same
    ///      institution. Demo labs do not create institutional reservations and
    ///      consequently never reach this calculation.
    function calculateInstitutionalReservationFee(
        uint96 price,
        address payerInstitution,
        address labProvider
    ) internal pure returns (uint96) {
        if (price > 0) return 0;

        uint256 fee =
            payerInstitution == labProvider ? SAME_INSTITUTION_RESERVATION_FEE : CROSS_INSTITUTION_RESERVATION_FEE;
        return uint96(fee);
    }

    function computeCancellationFee(
        uint96 price
    ) internal pure returns (uint96 providerFee, uint96 refundAmount) {
        if (price == 0) return (0, 0);

        uint96 totalFee = uint96((uint256(price) * CANCEL_FEE_TOTAL) / REVENUE_DENOMINATOR);

        providerFee = uint96((uint256(totalFee) * CANCEL_FEE_PROVIDER) / CANCEL_FEE_TOTAL);
        refundAmount = price - totalFee;
    }

    function computeNoShowSettlement(
        uint96 price
    ) internal pure returns (uint96 providerFee, uint96 refundAmount) {
        if (price == 0) return (0, 0);

        uint96 totalFee = uint96((uint256(price) * NO_SHOW_FEE_TOTAL) / REVENUE_DENOMINATOR);

        providerFee = uint96((uint256(totalFee) * NO_SHOW_FEE_PROVIDER) / NO_SHOW_FEE_TOTAL);
        refundAmount = price - totalFee;
    }
}
