// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.33;

import "forge-std/Test.sol";
import "./BaseTest.sol";
import "../contracts/abstracts/ReservableToken.sol";
import "../contracts/libraries/LibAppStorage.sol";

contract DummyReservable is ReservableToken {
    // no overrides required — call the public implementation directly in tests

    }

contract ProviderStakeBoundaryTest is BaseTest {
    DummyReservable token;

    function setUp() public override {
        super.setUp();
        token = new DummyReservable();
    }

    function test_calculateRequiredStake_always_returns_zero() public {
        // In the service-credit model, calculateRequiredStake always returns 0
        assertEq(token.calculateRequiredStake(address(1), 0), 0);
        assertEq(token.calculateRequiredStake(address(1), 1), 0);
        assertEq(token.calculateRequiredStake(address(1), 10), 0);
        assertEq(token.calculateRequiredStake(address(1), 11), 0);
        assertEq(token.calculateRequiredStake(address(1), 100), 0);
    }
}
