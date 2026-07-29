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
            reservationKey, makeAddr("renter"), payer, 100_000_000, 1, 7, uint32(block.timestamp + 7 days), "puc"
        );
        harness.setReservationAccounting(
            reservationKey, 1_890_000_000, uint48(1_905_000_000), keccak256("funding-order"), 100_000_000
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
        assertEq(price, 100_000_000);
        assertEq(totalFee, 10_000_000);
        assertEq(providerFee, 6_000_000);
        assertEq(refundAmount, 90_000_000);
        assertEq(cutoff, uint32(block.timestamp + 7 days));
        assertEq(periodStart, 1_890_000_000);
        assertEq(periodEnd, 1_890_000_000 + 120 days);
        assertEq(sourceExpiry, 1_905_000_000);
        assertEq(allocations.length, 1);
        assertEq(allocations[0].fundingOrderId, keccak256("funding-order"));
        assertEq(allocations[0].amount, 100_000_000);
        assertEq(policyVersion, 2);
    }

    function test_previewForSimulationReturnsFullRefund() public {
        harness.setLabResourceType(7, 1);

        (
            ,
            bool cancellable,,
            uint96 price,
            uint96 totalFee,
            uint96 providerFee,
            uint96 refundAmount,,,,,,
            uint8 policyVersion
        ) = harness.previewInstitutionalBookingCancellation(reservationKey);

        assertTrue(cancellable);
        assertEq(price, 100_000_000);
        assertEq(totalFee, 0);
        assertEq(providerFee, 0);
        assertEq(refundAmount, price);
        assertEq(policyVersion, 2);
    }
}
