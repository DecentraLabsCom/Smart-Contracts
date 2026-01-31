// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.33;

import "forge-std/Test.sol";
import "./BaseTest.sol";
import "./Harnesses.sol";

import "../contracts/facets/reservation/institutional/InstitutionalReservationQueryFacet.sol";

contract QueryHarness is InstitutionalReservationQueryFacet {
    function setReservationPucHash(
        bytes32 key,
        string calldata puc
    ) external {
        AppStorage storage s = LibAppStorage.diamondStorage();
        if (bytes(puc).length > 0) s.reservationPucHash[key] = keccak256(bytes(puc));
    }
}

contract InstitutionalReservationPucAndDenialTest is BaseTest {
    ConfirmHarness public confirmHarness;
    QueryHarness public queryHarness;

    uint8 internal constant _PENDING = 0;

    function setUp() public override {
        super.setUp();
        confirmHarness = new ConfirmHarness();
        queryHarness = new QueryHarness();
    }

    function test_confirm_requires_puc() public {
        address inst = address(0xBEEF);
        uint256 labId = 111;
        uint32 start = 4000;
        bytes32 key = keccak256(abi.encodePacked(labId, start));
        string memory puc = "puc@inst";

        // setup: register institution role, backend = harness itself, owner of lab = inst
        confirmHarness.setInstitutionRole(inst);
        confirmHarness.setBackend(inst, address(confirmHarness));
        confirmHarness.setOwner(labId, inst);
        confirmHarness.setReservation(key, user1, inst, 1000, _PENDING, labId, start, puc);

        vm.prank(inst);
        vm.expectRevert(); // PucRequired
        confirmHarness.ext_confirmWithPuc(inst, key, "");

        assertEq(confirmHarness.getReservationStatus(key), _PENDING);
    }

    function test_confirm_wrong_puc_reverts() public {
        address inst = address(0xCAFE);
        uint256 labId = 222;
        uint32 start = 5000;
        bytes32 key = keccak256(abi.encodePacked(labId, start));
        string memory puc = "right@puc";

        confirmHarness.setInstitutionRole(inst);
        confirmHarness.setBackend(inst, address(confirmHarness));
        confirmHarness.setOwner(labId, inst);
        confirmHarness.setReservation(key, user1, inst, 1000, _PENDING, labId, start, puc);

        vm.prank(inst);
        vm.expectRevert(); // wrong puc
        confirmHarness.ext_confirmWithPuc(inst, key, "wrong@puc");

        assertEq(confirmHarness.getReservationStatus(key), _PENDING);
    }

    function test_confirm_institution_not_registered_reverts() public {
        address inst = address(0xDEAD);
        uint256 labId = 333;
        uint32 start = 6000;
        bytes32 key = keccak256(abi.encodePacked(labId, start));
        string memory puc = "some@puc";

        // do NOT set institution role
        confirmHarness.setBackend(inst, address(confirmHarness));
        confirmHarness.setOwner(labId, inst);
        confirmHarness.setReservation(key, user1, inst, 1000, _PENDING, labId, start, puc);

        vm.prank(inst);
        vm.expectRevert(); // InstitutionNotRegistered
        confirmHarness.ext_confirmWithPuc(inst, key, puc);

        assertEq(confirmHarness.getReservationStatus(key), _PENDING);
    }

    function test_get_reservation_puc_hash() public {
        uint256 labId = 666;
        uint32 start = 9000;
        bytes32 key = keccak256(abi.encodePacked(labId, start));
        string memory puc = "query@puc";

        queryHarness.setReservationPucHash(key, puc);
        bytes32 got = queryHarness.getReservationPucHash(key);

        assertEq(got, keccak256(bytes(puc)));
    }
}
