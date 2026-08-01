// SPDX-License-Identifier: GPL-3.0-or-later
pragma solidity ^0.8.33;

import {Test} from "forge-std/Test.sol";
import {AppStorage, CreditReservationAllocation, LibAppStorage} from "../contracts/libraries/LibAppStorage.sol";
import {LibCreditLedger} from "../contracts/libraries/LibCreditLedger.sol";
import {LibReservationIdentity} from "../contracts/libraries/LibReservationIdentity.sol";

contract ReservationGenerationHarness {
    function createGeneration(
        bytes32 slotKey
    ) external returns (bytes32 reservationId) {
        reservationId = LibReservationIdentity.createReservationId(LibAppStorage.diamondStorage(), slotKey);
    }

    function currentReservationId(
        bytes32 slotKey
    ) external view returns (bytes32) {
        return LibReservationIdentity.currentReservationId(LibAppStorage.diamondStorage(), slotKey);
    }

    function debitForSlot(
        address account,
        uint256 amount,
        bytes32 slotKey
    ) external {
        AppStorage storage s = LibAppStorage.diamondStorage();
        LibCreditLedger.debitCredits(account, amount, LibReservationIdentity.currentReservationId(s, slotKey));
    }

    function cancelForSlot(
        address account,
        uint256 amount,
        bytes32 slotKey
    ) external {
        AppStorage storage s = LibAppStorage.diamondStorage();
        LibCreditLedger.cancelCredits(account, amount, LibReservationIdentity.currentReservationId(s, slotKey));
    }

    function mintCredits(
        address account,
        uint256 amount,
        bytes32 fundingOrderId,
        uint256 eurGrossAmount,
        uint48 expiresAt
    ) external {
        LibCreditLedger.mintCredits(account, amount, fundingOrderId, eurGrossAmount, expiresAt);
    }

    function allocationCount(
        address account,
        bytes32 reservationId
    ) external view returns (uint256) {
        return LibAppStorage.diamondStorage().creditReservationAllocations[account][reservationId].length;
    }

    function allocation(
        address account,
        bytes32 reservationId,
        uint256 index
    ) external view returns (CreditReservationAllocation memory) {
        return LibAppStorage.diamondStorage().creditReservationAllocations[account][reservationId][index];
    }
}

contract ReservationGenerationTest is Test {
    address private constant ACCOUNT = address(0xA11CE);

    function test_reusedSlotCreatesIndependentCreditAllocationGenerations() external {
        ReservationGenerationHarness harness = new ReservationGenerationHarness();
        bytes32 slotKey = keccak256("same-lab-and-start");
        bytes32 fundingOrderA = keccak256("funding-order-a");
        bytes32 fundingOrderB = keccak256("funding-order-b");

        vm.warp(1_000_000);

        bytes32 reservationIdA = harness.createGeneration(slotKey);
        harness.mintCredits(ACCOUNT, 100, fundingOrderA, 1000, uint48(block.timestamp + 1000));
        harness.debitForSlot(ACCOUNT, 100, slotKey);
        harness.cancelForSlot(ACCOUNT, 90, slotKey);

        bytes32 reservationIdB = harness.createGeneration(slotKey);
        harness.mintCredits(ACCOUNT, 100, fundingOrderB, 2000, uint48(block.timestamp + 2000));
        harness.debitForSlot(ACCOUNT, 100, slotKey);
        harness.cancelForSlot(ACCOUNT, 100, slotKey);

        assertTrue(reservationIdA != reservationIdB);
        assertEq(harness.currentReservationId(slotKey), reservationIdB);
        assertEq(harness.allocationCount(ACCOUNT, reservationIdA), 1);
        assertEq(harness.allocationCount(ACCOUNT, reservationIdB), 2);

        CreditReservationAllocation memory allocationA = harness.allocation(ACCOUNT, reservationIdA, 0);
        assertEq(allocationA.fundingOrderId, fundingOrderA);
        assertEq(allocationA.amount, 100);
        assertEq(allocationA.refundedAmount, 90);

        CreditReservationAllocation memory allocationB0 = harness.allocation(ACCOUNT, reservationIdB, 0);
        CreditReservationAllocation memory allocationB1 = harness.allocation(ACCOUNT, reservationIdB, 1);
        assertEq(allocationB0.refundedAmount, allocationB0.amount);
        assertEq(allocationB1.refundedAmount, allocationB1.amount);
    }
}
