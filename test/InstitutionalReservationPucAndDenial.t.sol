// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.33;

import "forge-std/Test.sol";
import "./BaseTest.sol";
import "./Harnesses.sol";

import "../contracts/facets/reservation/institutional/InstitutionalReservationDenialFacet.sol";
import "../contracts/facets/reservation/institutional/InstitutionalReservationQueryFacet.sol";

contract DenialHarness is InstitutionalReservationDenialFacet {
    mapping(uint256 => address) public owners;

    function setOwner(
        uint256 tokenId,
        address owner
    ) external {
        owners[tokenId] = owner;
    }

    function ownerOf(
        uint256 tokenId
    ) external view returns (address) {
        return owners[tokenId];
    }

    function setReservation(
        bytes32 key,
        address renter,
        address payerInstitution,
        uint96 price,
        uint8 status,
        uint256 labId,
        uint32 start,
        string calldata puc
    ) external {
        AppStorage storage s = LibAppStorage.diamondStorage();
        Reservation storage r = s.reservations[key];
        r.renter = renter;
        r.payerInstitution = payerInstitution;
        r.price = price;
        r.status = status;
        r.labId = labId;
        r.start = start;
        r.end = start + 3600;
        r.puc = "";
        if (bytes(puc).length > 0) s.reservationPucHash[key] = keccak256(bytes(puc));
    }

    function setInstitutionRole(
        address inst
    ) external {
        AppStorage storage s = LibAppStorage.diamondStorage();
        EnumerableSet.add(s.roleMembers[INSTITUTION_ROLE], inst);
    }

    // helper to perform deny + actual cancellation in the harness (cannot override non-virtual internal function)
    function getReservationStatus(
        bytes32 key
    ) external view returns (uint8) {
        AppStorage storage s = LibAppStorage.diamondStorage();
        return s.reservations[key].status;
    }

    function ext_deny_and_cancel(
        address inst,
        string calldata puc,
        bytes32 key
    ) external {
        AppStorage storage s = LibAppStorage.diamondStorage();
        require(EnumerableSet.contains(s.roleMembers[INSTITUTION_ROLE], inst), "!i");
        address bk = s.institutionalBackends[inst];
        require(msg.sender == inst || (bk != address(0) && msg.sender == bk), "!a");
        Reservation storage r = s.reservations[key];
        require(r.labId != 0, "!r");
        address own = this.ownerOf(r.labId);
        bk = s.institutionalBackends[own];
        require(msg.sender == own || (bk != address(0) && msg.sender == bk), "!p");
        bytes32 storedHash = s.reservationPucHash[key];
        require(storedHash != bytes32(0) && storedHash == keccak256(bytes(puc)), "!puc");
        // perform cancellation
        LibReservationCancellation.cancelReservation(key);
        emit ReservationRequestDenied(key, s.reservations[key].labId);
    }
}

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
    DenialHarness public denialHarness;
    QueryHarness public queryHarness;

    uint8 internal constant _PENDING = 0;
    uint8 internal constant _CONFIRMED = 1;
    uint8 internal constant _CANCELLED = 5;

    function setUp() public override {
        super.setUp();
        confirmHarness = new ConfirmHarness();
        denialHarness = new DenialHarness();
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

    function test_deny_institutional_reservation_success() public {
        address inst = address(0xABCD);
        uint256 labId = 444;
        uint32 start = 7000;
        bytes32 key = keccak256(abi.encodePacked(labId, start));
        string memory puc = "deny@puc";

        denialHarness.setInstitutionRole(inst);
        denialHarness.setOwner(labId, inst);
        denialHarness.setReservation(key, user1, inst, 0, _PENDING, labId, start, puc);

        vm.prank(inst);
        denialHarness.ext_deny_and_cancel(inst, puc, key);

        // should be cancelled
        assertEq(denialHarness.getReservationStatus(key), _CANCELLED);
    }

    function test_deny_institutional_reservation_wrong_puc_reverts() public {
        address inst = address(0xBAAD);
        uint256 labId = 555;
        uint32 start = 8000;
        bytes32 key = keccak256(abi.encodePacked(labId, start));
        string memory puc = "right@puc";

        denialHarness.setInstitutionRole(inst);
        denialHarness.setOwner(labId, inst);
        denialHarness.setReservation(key, user1, inst, 0, _PENDING, labId, start, puc);

        vm.prank(inst);
        vm.expectRevert(bytes("!puc"));
        denialHarness.denyInstitutionalReservationRequest(inst, "wrong@puc", key);

        AppStorage storage s = LibAppStorage.diamondStorage();
        assertEq(uint256(s.reservations[key].status), uint256(_PENDING));
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
