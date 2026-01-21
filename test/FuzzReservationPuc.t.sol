// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.33;

import "forge-std/Test.sol";
import "./BaseTest.sol";
import "./Harnesses.sol";
import "../contracts/libraries/LibRevenue.sol";

contract RevenueHarness {
    function computeCancellationFeePublic(
        uint96 price
    ) external pure returns (uint96, uint96, uint96, uint96) {
        return LibRevenue.computeCancellationFee(price);
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
        confirmHarness.setBackend(inst, address(confirmHarness));
        // make provider able to fulfill
        confirmHarness.setOwner(labId, provider);
        confirmHarness.setTokenStatus(labId, true);
        confirmHarness.setProviderStake(provider, type(uint256).max);
        confirmHarness.setReservation(key, user1, inst, 1000, 0, labId, start, puc);

        vm.prank(inst);
        confirmHarness.ext_confirmWithPuc(inst, key, puc);

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
        confirmHarness.setBackend(inst, address(confirmHarness));
        // make provider able to fulfill
        confirmHarness.setOwner(labId, provider);
        confirmHarness.setTokenStatus(labId, true);
        confirmHarness.setProviderStake(provider, type(uint256).max);
        confirmHarness.setReservation(key, user1, inst, 1000, 0, labId, start, puc);

        vm.prank(inst);
        vm.expectRevert();
        confirmHarness.ext_confirmWithPuc(inst, key, wrong);
    }

    // Fuzz: cancellation fees are consistent (sum of fees + refund == price)
    function test_fuzz_computeCancellationFee(
        uint96 price
    ) public {
        (uint96 providerFee, uint96 treasuryFee, uint96 governanceFee, uint96 refund) =
            rev.computeCancellationFeePublic(price);
        uint256 sum = uint256(providerFee) + uint256(treasuryFee) + uint256(governanceFee) + uint256(refund);
        assertEq(sum, uint256(price));
        assert(refund <= price);
    }
}
