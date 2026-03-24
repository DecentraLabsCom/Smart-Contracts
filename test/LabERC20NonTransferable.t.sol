// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.33;

import "forge-std/Test.sol";
import "./BaseTest.sol";
import "../contracts/external/LabERC20.sol";

/// @title Non-transferability tests for LabERC20 (MiCA 4.3.d enforcement)
contract LabERC20NonTransferableTest is BaseTest {
    LabERC20 internal token;
    address internal diamond;

    function setUp() public override {
        super.setUp();
        diamond = makeAddr("diamond");
        token = new LabERC20();
        token.initialize("LAB", diamond);

        // Mint some tokens to diamond for testing (1 decimal)
        token.grantRole(token.MINTER_ROLE(), address(this));
        token.mint(diamond, 1000 * 10 ** 1);
    }

    // ── transfer ──────────────────────────────────────────────────────────
    function test_transfer_reverts() public {
        vm.prank(diamond);
        vm.expectRevert(bytes("LabERC20: transfers disabled"));
        token.transfer(user1, 100);
    }

    // ── transferFrom ──────────────────────────────────────────────────────
    function test_transferFrom_reverts() public {
        vm.prank(diamond);
        vm.expectRevert(bytes("LabERC20: transfers disabled"));
        token.transferFrom(diamond, user1, 100);
    }

    // ── approve ───────────────────────────────────────────────────────────
    function test_approve_reverts() public {
        vm.prank(diamond);
        vm.expectRevert(bytes("LabERC20: approvals disabled"));
        token.approve(user1, 100);
    }

    // ── permit ────────────────────────────────────────────────────────────
    function test_permit_reverts() public {
        vm.expectRevert(bytes("LabERC20: permit disabled"));
        token.permit(diamond, user1, 100, block.timestamp + 1, 27, bytes32(0), bytes32(0));
    }

    // ── mint still works ──────────────────────────────────────────────────
    function test_mint_works_for_minter_role() public {
        uint256 before_ = token.balanceOf(user1);
        token.mint(user1, 500);
        assertEq(token.balanceOf(user1), before_ + 500);
    }

    // ── balanceOf and totalSupply still work ──────────────────────────────
    function test_read_functions_work() public view {
        assertGt(token.balanceOf(diamond), 0);
        assertGt(token.totalSupply(), 0);
        assertEq(token.decimals(), 1);
    }
}
