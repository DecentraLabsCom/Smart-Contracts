// SPDX-License-Identifier: MIT
pragma solidity ^0.8.33;

import {Test} from "forge-std/Test.sol";
import {ReservationDenialFacet} from "../contracts/facets/reservation/ReservationDenialFacet.sol";
import {AppStorage, LibAppStorage, Reservation} from "../contracts/libraries/LibAppStorage.sol";
import {LibERC721StorageTestHelper} from "./LibERC721StorageTestHelper.sol";
import {ConfirmHarness, InstReservationHarness} from "./Harnesses.sol";

contract InstitutionalDenialGasHarness is ReservationDenialFacet {
    mapping(uint256 => address) public owners;

    function ownerOf(
        uint256 tokenId
    ) external view returns (address) {
        return owners[tokenId];
    }

    function setOwner(
        uint256 tokenId,
        address owner
    ) external {
        owners[tokenId] = owner;
        LibERC721StorageTestHelper.setOwnerForTest(tokenId, owner);
    }

    function setBackend(
        address provider,
        address backend
    ) external {
        AppStorage storage s = LibAppStorage.diamondStorage();
        s.institutionalBackends[provider] = backend;
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
        if (bytes(puc).length > 0) {
            s.reservationPucHash[key] = keccak256(bytes(puc));
        }
    }
}

contract GasInstitutionalReservationsTest is Test {
    ConfirmHarness confirmHarness;
    InstitutionalDenialGasHarness denialHarness;
    InstReservationHarness cancellationHarness;

    address institution = address(0xBEEF);
    address institutionBackend = address(0xBEE1);
    address provider = address(0xCAFE);
    uint256 labId = 77;
    uint96 pricePerSecond = 100;

    uint8 internal constant _PENDING = 0;
    uint8 internal constant _CONFIRMED = 1;

    function setUp() public {
        confirmHarness = new ConfirmHarness();
        confirmHarness.setInstitutionRole(institution);
        confirmHarness.setBackend(institution, institutionBackend);
        confirmHarness.setOwner(labId, provider);
        confirmHarness.setTokenStatus(labId, true);
        confirmHarness.setProviderActive(provider);

        denialHarness = new InstitutionalDenialGasHarness();
        denialHarness.setOwner(labId, provider);

        cancellationHarness = new InstReservationHarness();
        cancellationHarness.setBackend(institution, institutionBackend);
    }

    function _requestWindow(
        uint32 offset
    ) internal view returns (uint32 start, uint32 end) {
        start = uint32(block.timestamp + offset);
        end = start + 1000;
    }

    function _reservationKey(
        uint32 start
    ) internal view returns (bytes32) {
        return keccak256(abi.encodePacked(labId, start));
    }

    function testGas_ConfirmInstitutionalReservationRequestWithPucHash() public {
        (uint32 start,) = _requestWindow(7200);
        bytes32 key = _reservationKey(start);
        uint96 totalPrice = pricePerSecond * 3600;

        confirmHarness.setReservation(key, address(0xABCD), institution, totalPrice, _PENDING, labId, start, "bob@inst");

        vm.prank(provider);
        confirmHarness.confirmInstitutionalReservationRequestWithPucHash(institution, key, keccak256(bytes("bob@inst")));
    }

    function testGas_DenyInstitutionalReservationRequest() public {
        (uint32 start,) = _requestWindow(10_800);
        bytes32 key = _reservationKey(start);

        denialHarness.setReservation(key, address(0xABCD), institution, 360_000, _PENDING, labId, start, "carol@inst");

        vm.prank(provider);
        denialHarness.denyReservationRequest(key);
    }

    function testGas_CancelInstitutionalReservationRequest() public {
        (uint32 start,) = _requestWindow(14_400);
        bytes32 key = _reservationKey(start);

        cancellationHarness.setReservation(
            key, address(0xABCD), institution, 360_000, _PENDING, labId, start, "dave@inst"
        );

        vm.prank(institutionBackend);
        cancellationHarness.cancelReservationRequestWrapper(institution, keccak256(bytes("dave@inst")), key);
    }

    function testGas_CancelInstitutionalBookingWithPucHash() public {
        (uint32 start,) = _requestWindow(18_000);
        bytes32 key = _reservationKey(start);

        cancellationHarness.setReservation(
            key, address(0xABCD), institution, 360_000, _CONFIRMED, labId, start, "erin@inst"
        );

        vm.prank(institutionBackend);
        cancellationHarness.cancelBookingWrapper(institution, keccak256(bytes("erin@inst")), key);
    }
}
