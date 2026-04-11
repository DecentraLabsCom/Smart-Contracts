// SPDX-License-Identifier: GPL-3.0-or-later
pragma solidity ^0.8.31;

/// @title LibRevenue - Revenue and fee calculations
/// @dev Library for pure calculations to reduce facet bytecode.
///      Only the provider share is tracked on-chain; the platform margin
///      (price − providerShare) is implicit and computed off-chain.
library LibRevenue {
    uint256 internal constant REVENUE_DENOMINATOR = 100;
    uint256 internal constant REVENUE_PROVIDER = 75;

    uint256 internal constant CANCEL_FEE_TOTAL = 5;
    uint256 internal constant CANCEL_FEE_PROVIDER = 3;
    uint256 internal constant MIN_CANCELLATION_FEE = 10_000;

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

    function computeCancellationFee(
        uint96 price
    ) internal pure returns (uint96 providerFee, uint96 refundAmount) {
        if (price == 0) return (0, 0);

        uint96 totalFee = uint96((uint256(price) * CANCEL_FEE_TOTAL) / REVENUE_DENOMINATOR);
        uint96 minFee = price < MIN_CANCELLATION_FEE ? price : uint96(MIN_CANCELLATION_FEE);
        if (totalFee < minFee) {
            totalFee = minFee;
        }

        providerFee = uint96((uint256(totalFee) * CANCEL_FEE_PROVIDER) / CANCEL_FEE_TOTAL);
        refundAmount = price - totalFee;
    }
}
