// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.33;

import "forge-std/Test.sol";
import "./BaseTest.sol";
import "../contracts/facets/reservation/institutional/InstitutionalTreasuryFacet.sol";
import "../contracts/libraries/LibAppStorage.sol";

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

    /// @dev Exposed helper to set treasury balance directly in storage
    function exposed_setInstitutionalTreasury(
        address inst,
        uint256 amount
    ) external {
        AppStorage storage s = LibAppStorage.diamondStorage();
        s.institutionalTreasury[inst] = amount;
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

        // set backend and initial treasury via harness exposed methods
        inst.exposed_setInstitutionRole(INST);
        inst.exposed_setBackend(INST, BACKEND);
        inst.exposed_setInstitutionalTreasury(INST, 1000);

        // set tight per-user limit (100 units) via facet (requires institution caller)
        vm.prank(INST);
        inst.setInstitutionalUserLimit(100);

        string memory puc = "user@inst";

        // backend spends 60 (should succeed)
        vm.prank(BACKEND);
        inst.spendFromInstitutionalTreasury(INST, puc, 60);
        assertEq(inst.getInstitutionalTreasuryBalance(INST), 940);
        assertEq(inst.getInstitutionalUserSpent(INST, puc), 60);

        // backend attempts to spend 50 (over limit 60+50 > 100) -> revert
        vm.prank(BACKEND);
        vm.expectRevert(bytes("User spending limit exceeded for period"));
        inst.spendFromInstitutionalTreasury(INST, puc, 50);

        // advance time past period boundary to reset per-period counter
        uint256 period = s.institutionalSpendingPeriod[INST];
        if (period == 0) period = LibAppStorage.DEFAULT_SPENDING_PERIOD;
        vm.warp(block.timestamp + period + 1);

        // backend can spend again up to limit
        vm.prank(BACKEND);
        inst.spendFromInstitutionalTreasury(INST, puc, 90);
        // read user spent via facet getter to avoid storage context mismatch
        assertEq(inst.getInstitutionalUserSpent(INST, puc), 90);
    }

    function test_zero_price_spend_does_not_consume_balance_but_requires_backend() public {
        AppStorage storage s = LibAppStorage.diamondStorage();
        inst.exposed_setInstitutionRole(INST);

        // no backend set -> backend requirement should revert even for zero amount
        vm.prank(BACKEND);
        vm.expectRevert(bytes("No authorized backend"));
        inst.spendFromInstitutionalTreasury(INST, "puc", 0);

        // set backend and call spend 0 - allowed and does not change treasury
        inst.exposed_setBackend(INST, BACKEND);
        inst.exposed_setInstitutionalTreasury(INST, 500);
        vm.prank(BACKEND);
        inst.spendFromInstitutionalTreasury(INST, "puc", 0);
        // read treasury from facet storage by calling getter
        assertEq(inst.getInstitutionalTreasuryBalance(INST), 500);
    }
}
