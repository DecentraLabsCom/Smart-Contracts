// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.33;

import "forge-std/Test.sol";
import {IERC1271} from "@openzeppelin/contracts/interfaces/IERC1271.sol";
import {ReservationCheckInFacet} from "../contracts/facets/reservation/ReservationCheckInFacet.sol";
import {AppStorage, LibAppStorage, Reservation} from "../contracts/libraries/LibAppStorage.sol";

contract ReservationCheckInHarness is ReservationCheckInFacet {
    function setReservation(
        bytes32 key,
        address renter,
        address payerInstitution,
        uint8 status,
        uint256 labId,
        uint32 start,
        uint32 end,
        bytes32 pucHash
    ) external {
        AppStorage storage s = LibAppStorage.diamondStorage();
        Reservation storage reservation = s.reservations[key];
        reservation.renter = renter;
        reservation.payerInstitution = payerInstitution;
        reservation.status = status;
        reservation.labId = labId;
        reservation.start = start;
        reservation.end = end;
        s.reservationPucHash[key] = pucHash;
    }

    function reservationStatus(
        bytes32 key
    ) external view returns (uint8) {
        return LibAppStorage.diamondStorage().reservations[key].status;
    }
}

contract ERC1271WalletMock is IERC1271 {
    bytes4 private constant _MAGIC_VALUE = IERC1271.isValidSignature.selector;
    bytes32 private validDigest;

    function setValidDigest(
        bytes32 digest
    ) external {
        validDigest = digest;
    }

    function isValidSignature(
        bytes32 digest,
        bytes calldata
    ) external view returns (bytes4) {
        return digest == validDigest ? _MAGIC_VALUE : bytes4(0);
    }
}

contract ReservationCheckInFacetTest is Test {
    uint8 internal constant _CONFIRMED = 1;
    uint8 internal constant _ACCESS_AUTHORIZED = 2;
    uint256 internal constant LAB_ID = 42;

    bytes32 private constant EIP712_DOMAIN_TYPEHASH =
        keccak256("EIP712Domain(string name,string version,uint256 chainId,address verifyingContract)");
    bytes32 private constant CHECKIN_TYPEHASH =
        keccak256("CheckIn(address signer,bytes32 reservationKey,bytes32 pucHash,uint64 timestamp)");
    bytes32 private constant NAME_HASH = keccak256("DecentraLabsIntent");
    bytes32 private constant VERSION_HASH = keccak256("1");

    ReservationCheckInHarness private harness;
    ERC1271WalletMock private wallet;
    bytes32 private reservationKey;
    uint64 private checkInTimestamp;
    uint32 private reservationStart;
    uint32 private reservationEnd;
    bytes32 private pucHash;

    function setUp() public {
        harness = new ReservationCheckInHarness();
        wallet = new ERC1271WalletMock();
        reservationKey = keccak256("reservation");
        pucHash = keccak256("puc");
        checkInTimestamp = 1_700_010_000;
        reservationStart = 1_700_009_940;
        reservationEnd = 1_700_013_600;

        vm.warp(checkInTimestamp + 30);
        harness.setReservation(
            reservationKey,
            address(0xCAFE),
            address(wallet),
            _CONFIRMED,
            LAB_ID,
            reservationStart,
            reservationEnd,
            pucHash
        );
    }

    function test_checkInReservationWithSignature_acceptsErc1271Signer() public {
        bytes32 digest = _checkInDigest(address(wallet), pucHash, checkInTimestamp);
        wallet.setValidDigest(digest);

        harness.checkInReservationWithSignature(reservationKey, address(wallet), pucHash, checkInTimestamp, hex"01");

        assertEq(harness.reservationStatus(reservationKey), _ACCESS_AUTHORIZED);
    }

    function _checkInDigest(
        address signer,
        bytes32 pucHashValue,
        uint64 timestamp
    ) private view returns (bytes32) {
        bytes32 structHash = keccak256(abi.encode(CHECKIN_TYPEHASH, signer, reservationKey, pucHashValue, timestamp));
        bytes32 domainSeparator =
            keccak256(abi.encode(EIP712_DOMAIN_TYPEHASH, NAME_HASH, VERSION_HASH, block.chainid, address(harness)));
        return keccak256(abi.encodePacked("\x19\x01", domainSeparator, structHash));
    }
}
