// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.33;

import {EnumerableSet} from "@openzeppelin/contracts/utils/structs/EnumerableSet.sol";
import "forge-std/Test.sol";
import "./BaseTest.sol";
import "./Harnesses.sol";

import "../contracts/facets/reservation/institutional/InstitutionalReservationQueryFacet.sol";

contract QueryHarness is InstitutionalReservationQueryFacet {
    using EnumerableSet for EnumerableSet.Bytes32Set;

    function setReservationPucHash(
        bytes32 key,
        string calldata puc
    ) external {
        AppStorage storage s = LibAppStorage.diamondStorage();
        if (bytes(puc).length > 0) s.reservationPucHash[key] = keccak256(bytes(puc));
    }

    function addReservationKeyToLab(
        uint256 labId,
        bytes32 key
    ) external {
        AppStorage storage s = LibAppStorage.diamondStorage();
        s.reservationKeysByToken[labId].add(key);
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

    function test_get_reservations_of_token_count_and_index() public {
        uint256 labId = 777;
        bytes32 keyA = keccak256("res-a");
        bytes32 keyB = keccak256("res-b");

        queryHarness.addReservationKeyToLab(labId, keyA);
        queryHarness.addReservationKeyToLab(labId, keyB);

        assertEq(queryHarness.getReservationsOfToken(labId), 2);
        assertEq(queryHarness.getLabReservationCount(labId), 2);
        assertEq(queryHarness.getReservationOfTokenByIndex(labId, 0), keyA);
        assertEq(queryHarness.getReservationOfTokenByIndex(labId, 1), keyB);
    }

    function test_get_reservations_of_token_paginated() public {
        uint256 labId = 888;
        bytes32 keyA = keccak256("page-a");
        bytes32 keyB = keccak256("page-b");
        bytes32 keyC = keccak256("page-c");

        queryHarness.addReservationKeyToLab(labId, keyA);
        queryHarness.addReservationKeyToLab(labId, keyB);
        queryHarness.addReservationKeyToLab(labId, keyC);

        (bytes32[] memory page, uint256 total) = queryHarness.getReservationsOfTokenPaginated(labId, 1, 2);
        assertEq(total, 3);
        assertEq(page.length, 2);
        assertEq(page[0], keyB);
        assertEq(page[1], keyC);

        (bytes32[] memory emptyPage, uint256 sameTotal) = queryHarness.getReservationsOfTokenPaginated(labId, 4, 2);
        assertEq(sameTotal, 3);
        assertEq(emptyPage.length, 0);
    }
}
