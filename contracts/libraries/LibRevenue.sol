// SPDX-License-Identifier: GPL-3.0-or-later
pragma solidity ^0.8.31;

import {AppStorage, LibAppStorage} from "./LibAppStorage.sol";

/// @title LibRevenue - Revenue and fee calculations
/// @dev Shared revenue calculations to reduce facet bytecode.
///      Only provider amounts are tracked on-chain; the platform margin is
///      implicit and computed off-chain.
library LibRevenue {
    uint256 internal constant REVENUE_DENOMINATOR = 100;
    uint256 internal constant COMMISSION_DENOMINATOR_BPS = 10_000;
    uint16 internal constant DEFAULT_LAB_COMMISSION_BPS = 4000;
    uint16 internal constant MAX_LAB_COMMISSION_BPS = 10_000;

    /// @dev Fixed platform booking fee for zero-priced institutional reservations.
    ///      Own-lab internal reservations are always zero-priced and cost four
    ///      credits; free cross-institutional reservations cost two credits.
    ///      These fees are separate from lab price and are non-refundable.
    uint256 internal constant SAME_INSTITUTION_RESERVATION_FEE = LibAppStorage.RAW_PER_CREDIT * 4;
    uint256 internal constant CROSS_INSTITUTION_RESERVATION_FEE = LibAppStorage.RAW_PER_CREDIT * 2;

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

    function getLabReservationCommissionBps(
        uint256 labId
    ) internal view returns (uint16) {
        AppStorage storage s = LibAppStorage.diamondStorage();
        if (s.labReservationCommissionOverride[labId]) {
            return s.labReservationCommissionBps[labId];
        }
        return DEFAULT_LAB_COMMISSION_BPS;
    }

    function calculateRevenueSplit(
        uint256 labId,
        uint96 price
    ) internal view returns (uint96 providerShare) {
        if (price == 0) {
            return 0;
        }

        uint256 commissionBps = getLabReservationCommissionBps(labId);
        uint256 providerShareBps = COMMISSION_DENOMINATOR_BPS - commissionBps;
        providerShare = _safeScaledShare(price, providerShareBps, COMMISSION_DENOMINATOR_BPS);
    }

    /// @notice Calculates the platform charge for an institutional reservation.
    /// @dev Priced reservations pay the lab price only. Own-lab internal
    ///      reservations are zero-priced and pay four credits; a zero-priced
    ///      cross-institutional reservation pays two credits. Demo labs do not
    ///      create institutional reservations and never reach this calculation.
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
