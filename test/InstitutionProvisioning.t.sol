// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.33;

import "forge-std/Test.sol";
import {EnumerableSet} from "@openzeppelin/contracts/utils/structs/EnumerableSet.sol";
import {ProviderFacet} from "../contracts/facets/ProviderFacet.sol";
import {InstitutionFacet} from "../contracts/facets/reservation/institutional/InstitutionFacet.sol";
import {AppStorage, LibAppStorage, PROVIDER_ROLE, INSTITUTION_ROLE} from "../contracts/libraries/LibAppStorage.sol";

contract InstitutionProvisioningHarness is InstitutionFacet {
    using EnumerableSet for EnumerableSet.AddressSet;

    function seedAdmin(
        address admin
    ) external {
        _s().DEFAULT_ADMIN_ROLE = DEFAULT_ADMIN_ROLE;
        _grantRole(DEFAULT_ADMIN_ROLE, admin);
    }

    function hasInstitutionRole(
        address account
    ) external view returns (bool) {
        return _s().roleMembers[INSTITUTION_ROLE].contains(account);
    }

    function registeredWallet(
        string calldata organization
    ) external view returns (address) {
        bytes32 hash = keccak256(bytes(organization));
        return _s().organizationInstitutionWallet[hash];
    }

    function registeredBackend(
        string calldata organization
    ) external view returns (string memory) {
        bytes32 hash = keccak256(bytes(organization));
        return _s().organizationBackendUrls[hash];
    }
}

contract ProviderProvisioningHarness is ProviderFacet {
    using EnumerableSet for EnumerableSet.AddressSet;

    function seedAdmin(
        address admin
    ) external {
        _s().DEFAULT_ADMIN_ROLE = DEFAULT_ADMIN_ROLE;
        _grantRole(DEFAULT_ADMIN_ROLE, admin);
    }

    function hasProviderRole(
        address account
    ) external view returns (bool) {
        return _s().roleMembers[PROVIDER_ROLE].contains(account);
    }

    function hasInstitutionRole(
        address account
    ) external view returns (bool) {
        return _s().roleMembers[INSTITUTION_ROLE].contains(account);
    }

    function registeredWallet(
        string calldata organization
    ) external view returns (address) {
        bytes32 hash = keccak256(bytes(organization));
        return _s().organizationInstitutionWallet[hash];
    }
}

contract InstitutionProvisioningTest is Test {
    address internal constant ADMIN = address(0xA11CE);

    function test_consumer_provisioning_is_atomic_and_complete() public {
        InstitutionProvisioningHarness harness = new InstitutionProvisioningHarness();
        harness.seedAdmin(ADMIN);
        address institution = address(0xCAFE);

        vm.prank(ADMIN);
        harness.provisionInstitution(institution, "Example.EDU", "https://auth.example.com");

        assertTrue(harness.hasInstitutionRole(institution));
        assertEq(harness.registeredWallet("example.edu"), institution);
        assertEq(harness.registeredBackend("example.edu"), "https://auth.example.com");
    }

    function test_consumer_provisioning_rolls_back_role_when_organization_conflicts() public {
        InstitutionProvisioningHarness harness = new InstitutionProvisioningHarness();
        harness.seedAdmin(ADMIN);
        address first = address(0xCAFE);
        address second = address(0xBEEF);

        vm.prank(ADMIN);
        harness.provisionInstitution(first, "example.edu", "https://first.example.com");

        vm.prank(ADMIN);
        vm.expectRevert();
        harness.provisionInstitution(second, "example.edu", "https://second.example.com");

        assertFalse(harness.hasInstitutionRole(second));
    }

    function test_provider_provisioning_rolls_back_provider_when_organization_conflicts() public {
        ProviderProvisioningHarness harness = new ProviderProvisioningHarness();
        harness.seedAdmin(ADMIN);
        address first = address(0xCAFE);
        address second = address(0xBEEF);

        vm.prank(ADMIN);
        harness.provisionProvider(
            "First Provider",
            first,
            "first@example.com",
            "ES",
            "https://first.example.com/auth",
            "example.edu",
            "https://first.example.com"
        );

        vm.prank(ADMIN);
        vm.expectRevert();
        harness.provisionProvider(
            "Second Provider",
            second,
            "second@example.com",
            "ES",
            "https://second.example.com/auth",
            "example.edu",
            "https://second.example.com"
        );

        assertFalse(harness.hasProviderRole(second));
        assertFalse(harness.hasInstitutionRole(second));
    }
}
