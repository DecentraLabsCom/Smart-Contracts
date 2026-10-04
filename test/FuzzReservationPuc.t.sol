// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.33;

import "forge-std/Test.sol";
import "./BaseTest.sol";
import "./Harnesses.sol";
import "../contracts/libraries/LibRevenue.sol";

contract RevenueHarness {
    function calculateRevenueSplitPublic(
        uint96 price
    ) external pure returns (uint96) {
        return LibRevenue.calculateRevenueSplit(price);
    }

    function calculateInstitutionalReservationFeePublic(
        uint96 price,
        address payerInstitution,
        address labProvider
    ) external pure returns (uint96) {
        return LibRevenue.calculateInstitutionalReservationFee(price, payerInstitution, labProvider);
    }

    function computeCancellationFeePublic(
        uint96 price
    ) external pure returns (uint96, uint96) {
        return LibRevenue.computeCancellationFee(price);
    }

    function computeNoShowSettlementPublic(
        uint96 price
    ) external pure returns (uint96, uint96) {
        return LibRevenue.computeNoShowSettlement(price);
    }
}

contract FuzzReservationPucTest is BaseTest {
    ConfirmHarness public confirmHarness;
    RevenueHarness public rev;

    function setUp() public override {
        super.setUp();
        confirmHarness = new ConfirmHarness();
        rev = new RevenueHarness();
    }

    // Fuzz: confirm succeeds when provided puc matches stored puc hash
    function test_fuzz_confirm_with_matching_puc(
        string memory puc
    ) public {
        vm.assume(bytes(puc).length > 0 && bytes(puc).length < 128);

        address inst = address(0xF00D);
        uint256 labId = 777;
        // derive a deterministic start from puc to avoid collisions in fuzz
        uint32 start = uint32(uint256(keccak256(bytes(puc))) % 1_000_000) + 1000;
        bytes32 key = keccak256(abi.encodePacked(labId, start));

        confirmHarness.setInstitutionRole(inst);
        confirmHarness.setBackend(provider, address(confirmHarness));
        // make provider able to fulfill
        confirmHarness.setOwner(labId, provider);
        confirmHarness.setTokenStatus(labId, true);
        confirmHarness.setProviderActive(provider);
        confirmHarness.setReservation(key, user1, inst, 1000, 0, labId, start, puc);

        vm.prank(provider);
        confirmHarness.ext_confirmWithPucHash(inst, key, keccak256(bytes(puc)));

        assertEq(confirmHarness.getReservationStatus(key), 1);
    }

    // Fuzz: confirm reverts when provided puc does not match stored hash
    function test_fuzz_confirm_with_different_puc(
        string memory base,
        string memory suffix
    ) public {
        vm.assume(bytes(base).length > 0 && bytes(base).length < 64);
        vm.assume(bytes(suffix).length > 0 && bytes(suffix).length < 64);
        string memory puc = string(abi.encodePacked(base));
        string memory wrong = string(abi.encodePacked(base, suffix));
        vm.assume(keccak256(bytes(puc)) != keccak256(bytes(wrong)));

        address inst = address(0xE0);
        uint256 labId = 888;
        uint32 start = 54_321;
        bytes32 key = keccak256(abi.encodePacked(labId, start));

        confirmHarness.setInstitutionRole(inst);
        confirmHarness.setBackend(provider, address(confirmHarness));
        // make provider able to fulfill
        confirmHarness.setOwner(labId, provider);
        confirmHarness.setTokenStatus(labId, true);
        confirmHarness.setProviderActive(provider);
        confirmHarness.setReservation(key, user1, inst, 1000, 0, labId, start, puc);

        vm.prank(provider);
        vm.expectRevert();
        confirmHarness.ext_confirmWithPucHash(inst, key, keccak256(bytes(wrong)));
    }

    // Fuzz: cancellation fees are consistent (sum of fees + refund == price)
    function test_fuzz_computeCancellationFee(
        uint96 price
    ) public {
        (uint96 providerFee, uint96 refund) = rev.computeCancellationFeePublic(price);
        uint256 sum = uint256(providerFee) + uint256(refund);
        assert(sum <= uint256(price));
        assert(refund <= price);
    }

    function test_fuzz_computeNoShowSettlement(
        uint96 price
    ) public {
        (uint96 providerFee, uint96 refund) = rev.computeNoShowSettlementPublic(price);
        assert(uint256(providerFee) + uint256(refund) <= uint256(price));
        assert(refund <= price);
    }

    function test_no_show_uses_exact_25_percent_for_normal_price() public {
        (uint96 providerFee, uint96 refund) = rev.computeNoShowSettlementPublic(10_000_000);

        assertEq(providerFee, 1_500_000);
        assertEq(refund, 7_500_000);
    }

    function test_no_show_uses_exact_25_percent_for_small_price() public {
        (uint96 providerFee, uint96 refund) = rev.computeNoShowSettlementPublic(1_000_000);

        assertEq(providerFee, 150_000);
        assertEq(refund, 750_000);
    }

    function test_no_show_uses_exact_25_percent_below_one_tenth_credit() public {
        (uint96 providerFee, uint96 refund) = rev.computeNoShowSettlementPublic(500_000);

        assertEq(providerFee, 75_000);
        assertEq(refund, 375_000);
    }

    function test_cancellation_uses_exact_10_percent_for_small_price() public {
        (uint96 providerFee, uint96 refund) = rev.computeCancellationFeePublic(1_000_000);

        assertEq(providerFee, 60_000);
        assertEq(refund, 900_000);
    }

    function test_normal_paid_reservation_keeps_70_percent_for_provider() public {
        assertEq(rev.calculateRevenueSplitPublic(100), 70);
    }

    function test_zero_price_same_institution_costs_two_credits() public {
        assertEq(rev.calculateInstitutionalReservationFeePublic(0, address(0xBEEF), address(0xBEEF)), 20_000_000);
    }

    function test_zero_price_cross_institution_costs_one_credit() public {
        assertEq(rev.calculateInstitutionalReservationFeePublic(0, address(0xBEEF), address(0xCAFE)), 10_000_000);
    }

    function test_paid_reservation_has_no_additional_fixed_fee() public {
        assertEq(rev.calculateInstitutionalReservationFeePublic(1, address(0xBEEF), address(0xCAFE)), 0);
    }
}
