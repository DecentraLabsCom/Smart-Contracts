// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.33;

import "forge-std/Test.sol";
import "./BaseTest.sol";
import "../contracts/Diamond.sol";
import "../contracts/facets/diamond/DiamondCutFacet.sol";
import "../contracts/facets/InitFacet.sol";
import "../contracts/facets/ProviderFacet.sol";
import "../contracts/facets/lab/LabFacet.sol";
import "../contracts/external/LabERC20.sol";
import {IDiamondCut} from "../contracts/interfaces/IDiamondCut.sol";
import "../contracts/interfaces/IDiamond.sol";

/// @title Provider Test
/// @notice Tests Provider CRUD operations per specification
/// @dev Complements ProviderStakeBoundary.t.sol which tests stake calculations
contract ProviderTest is BaseTest {
    Diamond diamond;
    ProviderFacet providerFacet;
    LabERC20 token;

    address admin = address(0xA11CE);
    address provider1 = address(0xDEAD);
    address nonAdmin = address(0xBAD);

    function _selector(
        string memory sig
    ) internal pure returns (bytes4) {
        return bytes4(keccak256(bytes(sig)));
    }

    function setUp() public override {
        super.setUp();

        // TODO: Deploy diamond with Provider facets
        // Similar to LabSecurity setup
    }

    /// @notice SPEC: "ADD PROVIDER" use case
    function test_addProvider_grants_role_and_mints_tokens() public {
        vm.prank(admin);
        providerFacet.addProvider("NewProvider", provider1, "new@provider.com", "US", "");

        // Verify provider role granted
        assertTrue(providerFacet.isLabProvider(provider1));

        // Verify 1000 LAB tokens minted (1000 * 10^6 with 6 decimals)
        assertEq(token.balanceOf(provider1), 1000 * 10 ** 6);
    }

    /// @notice SPEC: Only admin can add providers
    function test_addProvider_only_by_admin() public {
        vm.prank(nonAdmin);
        vm.expectRevert();
        providerFacet.addProvider("BadProvider", address(0x1234), "bad@example.com", "XX", "");
    }

    /// @notice SPEC: "UPDATE PROVIDER" use case
    function test_updateProvider_modifies_info() public {
        // Setup: Add provider
        vm.prank(admin);
        providerFacet.addProvider("Provider1", provider1, "p1@x", "ES", "");

        // Update provider info
        vm.prank(provider1);
        providerFacet.updateProvider("Provider1-Updated", "p1-new@x", "US");

        // TODO: Verify provider info updated (need getter function)
    }

    /// @notice MEDIUM SEVERITY: Test missing string length validation
    function test_updateProvider_missing_length_validation() public {
        // Setup: Add provider
        vm.prank(admin);
        providerFacet.addProvider("Provider1", provider1, "p1@x", "ES", "");

        // Create very long string (potential DoS)
        string memory longString = new string(10_000);
        // TODO: Fill with data

        // This SHOULD revert with length check, but currently doesn't
        vm.prank(provider1);
        // vm.expectRevert("String too long");
        providerFacet.updateProvider(longString, "p1@x", "ES");

        // This test documents the vulnerability
    }

    /// @notice SPEC: "REMOVE SPECIFIC PROVIDER" use case
    function test_removeProvider_requires_no_labs() public {
        // Setup: Add provider
        vm.prank(admin);
        providerFacet.addProvider("Provider1", provider1, "p1@x", "ES", "");

        // Remove provider (should succeed - no labs)
        vm.prank(admin);
        providerFacet.removeProvider(provider1);

        // Verify provider role revoked
        assertFalse(providerFacet.isLabProvider(provider1));
    }

    /// @notice Test cannot remove provider with active labs
    function test_removeProvider_fails_with_labs() public {
        // TODO: Setup - Add provider and create a lab
        // Then try to remove provider - should fail
    }
}
