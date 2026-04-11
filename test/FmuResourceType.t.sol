// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.33;

import "forge-std/Test.sol";
import "./BaseTest.sol";
import "./Harnesses.sol";
import "../contracts/libraries/LibAppStorage.sol";

/// @title FMU Resource Type Tests
/// @notice Verifies that FMU resources (resourceType=1) bypass the exclusive calendar,
///         allowing overlapping reservations, while regular labs (resourceType=0) still
///         revert on overlapping ranges.
contract FmuResourceTypeTest is BaseTest {
    ConfirmHarness public harness;

    uint8 internal constant _PENDING = 0;
    uint8 internal constant _CONFIRMED = 1;

    function setUp() public override {
        super.setUp();
        harness = new ConfirmHarness();
    }

    /// @notice FMU lab (resourceType=1): two overlapping reservations should both confirm
    function test_fmu_allows_overlapping_reservations() public {
        address inst = address(0x2222);
        uint256 labId = 42;
        uint32 start1 = 10000;
        uint32 start2 = 10100; // overlaps with first (both have 1h duration in harness)

        bytes32 key1 = keccak256(abi.encodePacked(labId, start1));
        bytes32 key2 = keccak256(abi.encodePacked(labId, start2));

        // set lab as FMU
        harness.setLabResourceType(labId, 1);

        // set up first reservation
        harness.setReservation(key1, user1, inst, 50, _PENDING, labId, start1, "alice@inst");
        harness.setOwner(labId, provider);
        harness.setInstitutionRole(inst);
        harness.setBackend(inst, address(0x0));
        harness.setTokenStatus(labId, true);
        harness.setProviderActive(provider);

        // confirm first
        vm.prank(inst);
        harness.confirmInstitutionalReservationRequestWithPuc(inst, key1, "alice@inst");
        assertEq(harness.getReservationStatus(key1), _CONFIRMED);

        // set up second overlapping reservation
        harness.setReservation(key2, address(0xBBBB), inst, 50, _PENDING, labId, start2, "bob@inst");

        // confirm second — should NOT revert because FMU bypasses calendar insert
        vm.prank(inst);
        harness.confirmInstitutionalReservationRequestWithPuc(inst, key2, "bob@inst");
        assertEq(harness.getReservationStatus(key2), _CONFIRMED);
    }

    /// @notice Regular lab (resourceType=0): overlapping reservations should revert
    function test_regular_lab_blocks_overlapping_reservations() public {
        address inst = address(0x2222);
        uint256 labId = 43;
        uint32 start1 = 20000;
        uint32 start2 = 20100; // overlaps

        bytes32 key1 = keccak256(abi.encodePacked(labId, start1));
        bytes32 key2 = keccak256(abi.encodePacked(labId, start2));

        // resourceType defaults to 0 (regular lab)

        harness.setReservation(key1, user1, inst, 50, _PENDING, labId, start1, "alice@inst");
        harness.setOwner(labId, provider);
        harness.setInstitutionRole(inst);
        harness.setBackend(inst, address(0x0));
        harness.setTokenStatus(labId, true);
        harness.setProviderActive(provider);

        // confirm first
        vm.prank(inst);
        harness.confirmInstitutionalReservationRequestWithPuc(inst, key1, "alice@inst");
        assertEq(harness.getReservationStatus(key1), _CONFIRMED);

        // set up second overlapping reservation
        harness.setReservation(key2, address(0xBBBB), inst, 50, _PENDING, labId, start2, "bob@inst");

        // confirm second — should revert because regular lab uses exclusive calendar
        vm.prank(inst);
        vm.expectRevert();
        harness.confirmInstitutionalReservationRequestWithPuc(inst, key2, "bob@inst");
    }

    /// @notice FMU default resourceType value is 0 (backward compatible)
    function test_default_resource_type_is_zero() public {
        uint256 labId = 44;
        // labId 44 has never been touched; resourceType should default to 0
        // We can't easily read it from storage in this harness, but we verify
        // by confirming overlapping reservations fail (same as regular lab test)
        address inst = address(0x2222);
        uint32 start1 = 30000;
        uint32 start2 = 30100;

        bytes32 key1 = keccak256(abi.encodePacked(labId, start1));
        bytes32 key2 = keccak256(abi.encodePacked(labId, start2));

        harness.setReservation(key1, user1, inst, 50, _PENDING, labId, start1, "alice@inst");
        harness.setOwner(labId, provider);
        harness.setInstitutionRole(inst);
        harness.setBackend(inst, address(0x0));
        harness.setTokenStatus(labId, true);
        harness.setProviderActive(provider);

        vm.prank(inst);
        harness.confirmInstitutionalReservationRequestWithPuc(inst, key1, "alice@inst");

        harness.setReservation(key2, address(0xBBBB), inst, 50, _PENDING, labId, start2, "bob@inst");

        // should revert — default resourceType is 0 (exclusive calendar)
        vm.prank(inst);
        vm.expectRevert();
        harness.confirmInstitutionalReservationRequestWithPuc(inst, key2, "bob@inst");
    }

    /// @notice FMU lab: three concurrent users should all succeed (#26 wallet-path overlap)
    function test_fmu_three_concurrent_users() public {
        address inst = address(0x2222);
        uint256 labId = 45;
        uint32 baseStart = 50000;
        uint32 step = 50; // all three overlap in the same window

        // set lab as FMU
        harness.setLabResourceType(labId, 1);
        harness.setOwner(labId, provider);
        harness.setInstitutionRole(inst);
        harness.setBackend(inst, address(0x0));
        harness.setTokenStatus(labId, true);
        harness.setProviderActive(provider);

        // Three overlapping reservations
        for (uint256 i = 0; i < 3; i++) {
            uint32 start = baseStart + uint32(i) * step;
            bytes32 key = keccak256(abi.encodePacked(labId, start));
            address renter = address(uint160(0xCC00 + i));
            string memory puc = string(abi.encodePacked("user", vm.toString(i), "@inst"));

            harness.setReservation(key, renter, inst, 50, _PENDING, labId, start, puc);

            vm.prank(inst);
            harness.confirmInstitutionalReservationRequestWithPuc(inst, key, puc);
            assertEq(harness.getReservationStatus(key), _CONFIRMED);
        }
    }
}
