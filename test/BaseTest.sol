// SPDX-License-Identifier: MIT
pragma solidity ^0.8.23;

import "forge-std/Test.sol";

/// @title Base test contract for DecentraLabs Diamond
/// @notice Provides common setup and utilities for all tests
abstract contract BaseTest is Test {
    // Common test addresses
    address public owner = makeAddr("owner");
    address public user1 = makeAddr("user1");
    address public user2 = makeAddr("user2");
    address public provider = makeAddr("provider");

    function setUp() public virtual {
        // Common setup logic
        vm.deal(owner, 100 ether);
        vm.deal(user1, 10 ether);
        vm.deal(user2, 10 ether);
        vm.deal(provider, 10 ether);
    }
}
