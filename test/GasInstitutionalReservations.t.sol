// SPDX-License-Identifier: MIT
pragma solidity ^0.8.33;

import {Test} from "forge-std/Test.sol";
import {EnumerableSet} from "@openzeppelin/contracts/utils/structs/EnumerableSet.sol";

import {InstitutionalReservationRequestCreationFacet} from "../contracts/facets/reservation/institutional/InstitutionalReservationRequestCreationFacet.sol";
import {InstitutionalReservationRequestValidationFacet} from "../contracts/facets/reservation/institutional/InstitutionalReservationRequestValidationFacet.sol";
import {LibInstitutionalReservation} from "../contracts/libraries/LibInstitutionalReservation.sol";
import {ReservationDenialFacet} from "../contracts/facets/reservation/ReservationDenialFacet.sol";
import {AppStorage, LabBase, LibAppStorage, Reservation, INSTITUTION_ROLE, ProviderNetworkStatus} from "../contracts/libraries/LibAppStorage.sol";
import {ConfirmHarness, InstReservationHarness} from "./Harnesses.sol";

contract InstitutionalRequestGasHarness is
    InstitutionalReservationRequestCreationFacet,
    InstitutionalReservationRequestValidationFacet
{
    using EnumerableSet for EnumerableSet.AddressSet;

    mapping(uint256 => address) public owners;

    function ownerOf(
        uint256 tokenId
    ) external view returns (address) {
        return owners[tokenId];
    }

    function seedInstitution(
        address institution,
        address backend
    ) external {
        AppStorage storage s = LibAppStorage.diamondStorage();
        s.roleMembers[INSTITUTION_ROLE].add(institution);
        s.institutionalBackends[institution] = backend;
    }

    function seedProvider(
        address provider
    ) external {
        AppStorage storage s = LibAppStorage.diamondStorage();
        s.providerNetworkStatus[provider] = ProviderNetworkStatus.ACTIVE;
        s.providerStakes[provider].stakedAmount = type(uint256).max;
        s.providerStakes[provider].listedLabsCount = 1;
    }

    function seedLab(
        uint256 labId,
        address provider,
        uint96 pricePerSecond
    ) external {
        AppStorage storage s = LibAppStorage.diamondStorage();
        owners[labId] = provider;
        s.tokenStatus[labId] = true;
        s.labs[labId] = LabBase({
            uri: "uri",
            price: pricePerSecond,
            accessURI: "access-uri",
            accessKey: "access-key",
            createdAt: uint32(block.timestamp),
            resourceType: 0
        });
    }

    function institutionalReservationRequest(
        address institution,
        string calldata puc,
        uint256 labId,
        uint32 start,
        uint32 end
    ) external {
        AppStorage storage s = LibAppStorage.diamondStorage();
        if (!s.roleMembers[INSTITUTION_ROLE].contains(institution)) revert("UnknownInstitution");
        address backend = s.institutionalBackends[institution];
        if (!(msg.sender == institution || (backend != address(0) && msg.sender == backend))) {
            revert("UnauthorizedInstitution");
        }
        if (owners[labId] == address(0)) revert("TokenNotFound");
        LibInstitutionalReservation.requestReservation(institution, puc, labId, start, end);
    }

    function checkInstitutionalTreasuryAvailability(
        address,
        string calldata,
        uint256
    ) external pure {}
}

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
    InstitutionalRequestGasHarness requestHarness;
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
        requestHarness = new InstitutionalRequestGasHarness();
        requestHarness.seedInstitution(institution, institutionBackend);
        requestHarness.seedProvider(provider);
        requestHarness.seedLab(labId, provider, pricePerSecond);

        confirmHarness = new ConfirmHarness();
        confirmHarness.setInstitutionRole(institution);
        confirmHarness.setBackend(institution, institutionBackend);
        confirmHarness.setOwner(labId, provider);
        confirmHarness.setTokenStatus(labId, true);
        confirmHarness.setProviderStake(provider, type(uint256).max);

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

    function testGas_InstitutionalReservationRequest() public {
        (uint32 start, uint32 end) = _requestWindow(3600);

        vm.prank(institutionBackend);
        requestHarness.institutionalReservationRequest(institution, "alice@inst", labId, start, end);
    }

    function testGas_ConfirmInstitutionalReservationRequestWithPuc() public {
        (uint32 start,) = _requestWindow(7200);
        bytes32 key = _reservationKey(start);
        uint96 totalPrice = pricePerSecond * 3600;

        confirmHarness.setReservation(key, address(0xABCD), institution, totalPrice, _PENDING, labId, start, "bob@inst");

        vm.prank(provider);
        confirmHarness.confirmInstitutionalReservationRequestWithPuc(institution, key, "bob@inst");
    }

    function testGas_DenyInstitutionalReservationRequest() public {
        (uint32 start,) = _requestWindow(10800);
        bytes32 key = _reservationKey(start);

        denialHarness.setReservation(key, address(0xABCD), institution, 360000, _PENDING, labId, start, "carol@inst");

        vm.prank(provider);
        denialHarness.denyReservationRequest(key);
    }

    function testGas_CancelInstitutionalReservationRequest() public {
        (uint32 start,) = _requestWindow(14400);
        bytes32 key = _reservationKey(start);

        cancellationHarness.setReservation(key, address(0xABCD), institution, 360000, _PENDING, labId, start, "dave@inst");

        vm.prank(institutionBackend);
        cancellationHarness.cancelReservationRequestWrapper(institution, "dave@inst", key);
    }

    function testGas_CancelInstitutionalBookingWithPuc() public {
        (uint32 start,) = _requestWindow(18000);
        bytes32 key = _reservationKey(start);

        cancellationHarness.setReservation(key, address(0xABCD), institution, 360000, _CONFIRMED, labId, start, "erin@inst");

        vm.prank(institutionBackend);
        cancellationHarness.cancelBookingWrapper(institution, "erin@inst", key);
    }
}
