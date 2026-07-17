// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.33;

import "forge-std/Test.sol";
import "./BaseTest.sol";
import "../contracts/facets/reservation/institutional/InstitutionalTreasuryFacet.sol";
import {AppStorage, CreditLot, LibAppStorage} from "../contracts/libraries/LibAppStorage.sol";
import "../contracts/libraries/LibCreditLedger.sol";

/// @dev Test harness that inherits from InstitutionalTreasuryFacet to expose internal storage for testing
contract InstitutionalTreasuryFacetHarness is InstitutionalTreasuryFacet {
    using EnumerableSet for EnumerableSet.AddressSet;

    /// @dev Exposed helper to set institution role directly in storage
    function exposed_setInstitutionRole(
        address inst
    ) external {
        AppStorage storage s = LibAppStorage.diamondStorage();
        s.roleMembers[INSTITUTION_ROLE].add(inst);
    }

    /// @dev Exposed helper to set backend directly in storage
    function exposed_setBackend(
        address inst,
        address backend
    ) external {
        AppStorage storage s = LibAppStorage.diamondStorage();
        s.institutionalBackends[inst] = backend;
    }

    function exposed_mintCredits(
        address inst,
        uint256 amount
    ) external {
        LibCreditLedger.mintCredits(inst, amount, keccak256("TEST-FUNDING"), amount, 0);
    }

    function exposed_mintCreditsWithExpiry(
        address inst,
        uint256 amount,
        uint48 expiresAt
    ) external {
        LibCreditLedger.mintCredits(inst, amount, keccak256("TEST-FUNDING-EXPIRING"), amount, expiresAt);
    }

    function exposed_refundForReservation(
        address inst,
        bytes32 pucHash,
        bytes32 reservationKey,
        uint256 amount
    ) external {
        this.refundToInstitutionalTreasuryForReservation(inst, pucHash, reservationKey, amount);
    }

    function exposed_totalCreditBalance(
        address inst
    ) external view returns (uint256) {
        return LibCreditLedger.totalBalanceOf(inst);
    }

    function exposed_getCreditLot(
        address account,
        uint256 index
    ) external view returns (CreditLot memory) {
        return LibCreditLedger.getLot(account, index);
    }
}

contract InstitutionalSpendingPeriodTest is BaseTest {
    InstitutionalTreasuryFacetHarness inst;

    address constant INST = address(0xBA11);
    address constant BACKEND = address(0xBEEF);

    function setUp() public override {
        super.setUp();
        inst = new InstitutionalTreasuryFacetHarness();
    }

    function test_spending_limit_and_period_reset() public {
        AppStorage storage s = LibAppStorage.diamondStorage();

        // set backend and initial credit balance via harness exposed methods
        inst.exposed_setInstitutionRole(INST);
        inst.exposed_setBackend(INST, BACKEND);
        inst.exposed_mintCredits(INST, 1000);

        // set tight per-user limit (100 units) via facet (requires institution caller)
        vm.prank(INST);
        inst.setInstitutionalUserLimit(100);

        bytes32 pucHash = keccak256(bytes("user@inst"));

        // backend spends 60 (should succeed)
        vm.prank(BACKEND);
        inst.spendFromInstitutionalTreasury(INST, pucHash, 60);
        assertEq(inst.getInstitutionalTreasuryBalance(INST), 940);
        assertEq(inst.getInstitutionalUserSpent(INST, pucHash), 60);

        // backend attempts to spend 50 (over limit 60+50 > 100) -> revert
        vm.prank(BACKEND);
        vm.expectRevert(bytes("User spending limit exceeded for period"));
        inst.spendFromInstitutionalTreasury(INST, pucHash, 50);

        // advance time past period boundary to reset per-period counter
        uint256 period = s.institutionalSpendingPeriod[INST];
        if (period == 0) period = LibAppStorage.DEFAULT_SPENDING_PERIOD;
        vm.warp(block.timestamp + period + 1);

        // backend can spend again up to limit
        vm.prank(BACKEND);
        inst.spendFromInstitutionalTreasury(INST, pucHash, 90);
        // read user spent via facet getter to avoid storage context mismatch
        assertEq(inst.getInstitutionalUserSpent(INST, pucHash), 90);
    }

    function test_zero_price_spend_does_not_consume_balance_but_requires_backend() public {
        AppStorage storage s = LibAppStorage.diamondStorage();
        inst.exposed_setInstitutionRole(INST);

        // no backend set -> backend requirement should revert even for zero amount
        vm.prank(BACKEND);
        vm.expectRevert(bytes("No authorized backend"));
        inst.spendFromInstitutionalTreasury(INST, keccak256(bytes("puc")), 0);

        // set backend and call spend 0 - allowed and does not change treasury
        inst.exposed_setBackend(INST, BACKEND);
        inst.exposed_mintCredits(INST, 500);
        vm.prank(BACKEND);
        inst.spendFromInstitutionalTreasury(INST, keccak256(bytes("puc")), 0);
        // read treasury from facet storage by calling getter
        assertEq(inst.getInstitutionalTreasuryBalance(INST), 500);
    }

    function test_spend_uses_service_credit_ledger_balance() public {
        inst.exposed_setInstitutionRole(INST);
        inst.exposed_setBackend(INST, BACKEND);
        inst.exposed_mintCredits(INST, 1000);

        bytes32 pucHash = keccak256(bytes("ledger-user@inst"));

        vm.prank(BACKEND);
        inst.spendFromInstitutionalTreasury(INST, pucHash, 60);

        assertEq(inst.getInstitutionalTreasuryBalance(INST), 940);
        assertEq(inst.exposed_totalCreditBalance(INST), 940);
        assertEq(inst.getInstitutionalUserSpent(INST, pucHash), 60);
    }

    function test_reservation_spend_and_refund_preserve_source_expiry_and_reference() public {
        inst.exposed_setInstitutionRole(INST);
        inst.exposed_setBackend(INST, BACKEND);
        uint48 expiry = uint48(block.timestamp + 100);
        inst.exposed_mintCreditsWithExpiry(INST, 1000, expiry);

        bytes32 pucHash = keccak256(bytes("reservation-user@inst"));
        bytes32 reservationKey = keccak256(bytes("reservation-001"));

        vm.prank(BACKEND);
        inst.spendFromInstitutionalTreasuryForReservation(INST, pucHash, reservationKey, 600);
        inst.exposed_refundForReservation(INST, pucHash, reservationKey, 600);

        CreditLot memory refundLot = inst.exposed_getCreditLot(INST, 1);
        assertEq(refundLot.fundingOrderId, reservationKey);
        assertEq(refundLot.expiresAt, expiry);
        assertEq(inst.getInstitutionalTreasuryBalance(INST), 1000);
    }
}
