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

    function authorizedBackend(
        address institution
    ) external view returns (address) {
        return _s().institutionalBackends[institution];
    }

    function setAuthorizedBackend(
        address institution,
        address backend
    ) external {
        _s().institutionalBackends[institution] = backend;
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

        vm.expectEmit(true, true, false, true);
        emit InstitutionFacet.BackendAuthorized(institution, institution);

        vm.prank(ADMIN);
        harness.provisionInstitution(institution, "Example.EDU", "https://auth.example.com");

        assertTrue(harness.hasInstitutionRole(institution));
        assertEq(harness.registeredWallet("example.edu"), institution);
        assertEq(harness.registeredBackend("example.edu"), "https://auth.example.com");
        assertEq(harness.authorizedBackend(institution), institution);
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

    function test_revokeLastOrganization_clearsBackend_and_reprovisionRequiresFreshAuthorization() public {
        InstitutionProvisioningHarness harness = new InstitutionProvisioningHarness();
        harness.seedAdmin(ADMIN);
        address institution = address(0xCAFE);
        address oldBackend = address(0xD00D);

        vm.prank(ADMIN);
        harness.provisionInstitution(institution, "example.edu", "https://auth.example.com");
        harness.setAuthorizedBackend(institution, oldBackend);

        vm.recordLogs();
        vm.prank(ADMIN);
        harness.revokeInstitutionRole(institution, "example.edu");

        Vm.Log[] memory logs = vm.getRecordedLogs();
        bytes32 backendRevokedTopic = keccak256("BackendRevoked(address,address)");
        bool backendRevoked;
        for (uint256 i; i < logs.length; i++) {
            if (logs[i].topics.length == 3 && logs[i].topics[0] == backendRevokedTopic) {
                assertEq(address(uint160(uint256(logs[i].topics[1]))), institution);
                assertEq(address(uint160(uint256(logs[i].topics[2]))), oldBackend);
                backendRevoked = true;
            }
        }
        assertTrue(backendRevoked);

        assertFalse(harness.hasInstitutionRole(institution));
        assertEq(harness.authorizedBackend(institution), address(0));

        vm.prank(ADMIN);
        harness.provisionInstitution(institution, "example.edu", "https://auth.example.com");

        assertTrue(harness.hasInstitutionRole(institution));
        assertEq(harness.authorizedBackend(institution), institution);
        assertTrue(harness.authorizedBackend(institution) != oldBackend);
    }

    function test_revokeOrganization_preservesBackend_whileAnotherOrganizationRemains() public {
        InstitutionProvisioningHarness harness = new InstitutionProvisioningHarness();
        harness.seedAdmin(ADMIN);
        address institution = address(0xCAFE);
        address backend = address(0xD00D);

        vm.startPrank(ADMIN);
        harness.provisionInstitution(institution, "first.example.edu", "");
        harness.provisionInstitution(institution, "second.example.edu", "");
        vm.stopPrank();
        harness.setAuthorizedBackend(institution, backend);

        vm.prank(ADMIN);
        harness.revokeInstitutionRole(institution, "first.example.edu");

        assertTrue(harness.hasInstitutionRole(institution));
        assertEq(harness.authorizedBackend(institution), backend);
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
