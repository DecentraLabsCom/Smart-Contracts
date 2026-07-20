// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.33;

import "forge-std/Test.sol";
import "./Harnesses.sol";

contract InstitutionalCancellationPreviewTest is Test {
    InstReservationHarness harness;
    address payer = makeAddr("payer");
    bytes32 reservationKey = keccak256("preview-reservation");

    function setUp() public {
        harness = new InstReservationHarness();
        harness.setReservation(
            reservationKey, makeAddr("renter"), payer, 1_000_000, 1, 7, uint32(block.timestamp + 7 days), "puc"
        );
        harness.setReservationAccounting(
            reservationKey, 1_890_000_000, uint48(1_905_000_000), keccak256("funding-order"), 1_000_000
        );
    }

    function test_previewMatchesCancellationPolicyAndAccountingSources() public {
        (
            uint8 status,
            bool cancellable,
            address destination,
            uint96 price,
            uint96 totalFee,
            uint96 providerFee,
            uint96 refundAmount,
            uint32 cutoff,
            uint256 periodStart,
            uint256 periodEnd,
            uint48 sourceExpiry,
            CreditReservationAllocation[] memory allocations,
            uint8 policyVersion
        ) = harness.previewInstitutionalBookingCancellation(reservationKey);

        assertEq(status, 1);
        assertTrue(cancellable);
        assertEq(destination, payer);
        assertEq(price, 1_000_000);
        assertEq(totalFee, 50_000);
        assertEq(providerFee, 30_000);
        assertEq(refundAmount, 950_000);
        assertEq(cutoff, uint32(block.timestamp + 7 days));
        assertEq(periodStart, 1_890_000_000);
        assertEq(periodEnd, 1_890_000_000 + 120 days);
        assertEq(sourceExpiry, 1_905_000_000);
        assertEq(allocations.length, 1);
        assertEq(allocations[0].fundingOrderId, keccak256("funding-order"));
        assertEq(allocations[0].amount, 1_000_000);
        assertEq(policyVersion, 1);
    }
}
