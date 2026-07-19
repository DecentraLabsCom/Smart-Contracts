// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.33;

import "forge-std/Test.sol";
import "../contracts/facets/reservation/ReservationSessionFacet.sol";
import "../contracts/libraries/LibAppStorage.sol";
import "./LibERC721StorageTestHelper.sol";

contract ReservationSessionHarness is ReservationSessionFacet {
    function setOwner(
        uint256 tokenId,
        address owner
    ) external {
        LibERC721StorageTestHelper.setOwnerForTest(tokenId, owner);
    }

    function setReservation(
        bytes32 key,
        address renter,
        uint8 status,
        uint256 labId,
        uint32 start,
        uint32 end,
        bytes32 pucHash
    ) external {
        AppStorage storage s = LibAppStorage.diamondStorage();
        Reservation storage reservation = s.reservations[key];
        reservation.renter = renter;
        reservation.status = status;
        reservation.labId = labId;
        reservation.start = start;
        reservation.end = end;
        s.reservationPucHash[key] = pucHash;
    }
}

contract ReservationSessionFacetTest is Test {
    uint8 internal constant _CONFIRMED = 1;
    uint8 internal constant _ACCESS_AUTHORIZED = 2;

    uint256 internal constant PROVIDER_PK = 0xA11CE;
    uint256 internal constant OTHER_PK = 0xB0B;
    uint256 internal constant LAB_ID = 42;

    bytes32 private constant EIP712_DOMAIN_TYPEHASH =
        keccak256("EIP712Domain(string name,string version,uint256 chainId,address verifyingContract)");
    bytes32 private constant SESSION_STARTED_TYPEHASH = keccak256(
        "SessionStarted(address signer,bytes32 reservationKey,bytes32 labIdHash,bytes32 pucHash,bytes32 gatewayIdHash,bytes32 sessionIdHash,bytes32 accessTypeHash,uint64 startedAt,bytes32 nonce,bytes32 credentialHash,bytes32 clientProofHash)"
    );
    bytes32 private constant NAME_HASH = keccak256("DecentraLabsSession");
    bytes32 private constant VERSION_HASH = keccak256("1");

    ReservationSessionHarness private harness;
    address private provider;
    address private otherSigner;
    bytes32 private reservationKey;
    bytes32 private pucHash;
    bytes32 private nonce;
    bytes32 private credentialHash;
    uint64 private startedAt;
    uint32 private reservationStart;
    uint32 private reservationEnd;

    event ReservationSessionStarted(
        bytes32 indexed reservationKey,
        uint256 indexed labId,
        address indexed signer,
        bytes32 gatewayIdHash,
        bytes32 sessionIdHash,
        bytes32 accessTypeHash,
        uint64 startedAt,
        bytes32 nonce,
        bytes32 credentialHash,
        bytes32 clientProofHash
    );

    function setUp() public {
        harness = new ReservationSessionHarness();
        provider = vm.addr(PROVIDER_PK);
        otherSigner = vm.addr(OTHER_PK);
        reservationKey = keccak256("reservation");
        pucHash = keccak256("puc");
        nonce = keccak256("nonce");
        credentialHash = keccak256("credential");
        startedAt = 1_700_010_000;
        reservationStart = 1_700_009_940;
        reservationEnd = 1_700_013_600;

        vm.warp(startedAt + 30);
        harness.setOwner(LAB_ID, provider);
        harness.setReservation(
            reservationKey, address(0xCAFE), _ACCESS_AUTHORIZED, LAB_ID, reservationStart, reservationEnd, pucHash
        );
    }

    function test_markSessionStarted_acceptsProviderSignedAttestation() public {
        ReservationSessionFacet.SessionStartedInput memory input =
            _input(provider, PROVIDER_PK, nonce, "guac-session-1");

        vm.expectEmit(true, true, true, true);
        emit ReservationSessionStarted(
            reservationKey,
            LAB_ID,
            provider,
            keccak256(bytes("gateway-a")),
            keccak256(bytes("guac-session-1")),
            keccak256(bytes("guacamole")),
            startedAt,
            nonce,
            credentialHash,
            bytes32(0)
        );

        harness.markSessionStarted(input);

        ReservationSession memory session = harness.getReservationSessionStarted(reservationKey);
        assertEq(session.signer, provider);
        assertEq(session.gatewayIdHash, keccak256(bytes("gateway-a")));
        assertEq(session.sessionIdHash, keccak256(bytes("guac-session-1")));
        assertEq(session.accessTypeHash, keccak256(bytes("guacamole")));
        assertEq(session.startedAt, startedAt);
        assertEq(session.nonce, nonce);
        assertEq(session.credentialHash, credentialHash);
    }

    function test_markSessionStarted_acceptsAttestation_atGraceBoundary() public {
        vm.warp(uint256(startedAt) + 1 days);
        ReservationSessionFacet.SessionStartedInput memory input =
            _input(provider, PROVIDER_PK, nonce, "guac-session-boundary");

        harness.markSessionStarted(input);
        assertTrue(harness.hasReservationSessionStarted(reservationKey));
    }

    function test_markSessionStarted_rejectsAttestation_afterGraceBoundary() public {
        vm.warp(uint256(startedAt) + 1 days + 1);
        ReservationSessionFacet.SessionStartedInput memory input =
            _input(provider, PROVIDER_PK, nonce, "guac-session-too-late");

        vm.expectRevert("Attestation too old");
        harness.markSessionStarted(input);
    }

    function test_markSessionStarted_requiresAccessAuthorizedState() public {
        harness.setReservation(
            reservationKey, address(0xCAFE), _CONFIRMED, LAB_ID, reservationStart, reservationEnd, pucHash
        );
        ReservationSessionFacet.SessionStartedInput memory input =
            _input(provider, PROVIDER_PK, nonce, "guac-session-1");

        vm.expectRevert("Access not authorized");
        harness.markSessionStarted(input);
    }

    function test_markSessionStarted_rejectsNonProviderSigner() public {
        ReservationSessionFacet.SessionStartedInput memory input =
            _input(otherSigner, OTHER_PK, nonce, "guac-session-1");

        vm.expectRevert("Signer not provider");
        harness.markSessionStarted(input);
    }

    function test_markSessionStarted_rejectsNonceReplay() public {
        ReservationSessionFacet.SessionStartedInput memory input =
            _input(provider, PROVIDER_PK, nonce, "guac-session-1");

        harness.markSessionStarted(input);

        _switchToSecondAuthorizedReservation();
        ReservationSessionFacet.SessionStartedInput memory replay =
            _input(provider, PROVIDER_PK, nonce, "guac-session-2");
        vm.expectRevert("Nonce already used");
        harness.markSessionStarted(replay);
    }

    function test_markSessionStarted_rejectsSessionReplay() public {
        ReservationSessionFacet.SessionStartedInput memory input =
            _input(provider, PROVIDER_PK, nonce, "guac-session-1");

        harness.markSessionStarted(input);

        _switchToSecondAuthorizedReservation();
        ReservationSessionFacet.SessionStartedInput memory replay =
            _input(provider, PROVIDER_PK, keccak256("nonce-2"), "guac-session-1");
        vm.expectRevert("Session already used");
        harness.markSessionStarted(replay);
    }

    function _switchToSecondAuthorizedReservation() private {
        reservationKey = keccak256("reservation-2");
        harness.setReservation(
            reservationKey, address(0xBEEF), _ACCESS_AUTHORIZED, LAB_ID, reservationStart, reservationEnd, pucHash
        );
    }

    function _input(
        address signer,
        uint256 signerPk,
        bytes32 inputNonce,
        string memory sessionId
    ) private view returns (ReservationSessionFacet.SessionStartedInput memory input) {
        input = ReservationSessionFacet.SessionStartedInput({
            signer: signer,
            reservationKey: reservationKey,
            labId: "42",
            pucHash: pucHash,
            gatewayId: "gateway-a",
            sessionId: sessionId,
            accessType: "guacamole",
            startedAt: startedAt,
            nonce: inputNonce,
            credentialHash: credentialHash,
            clientProofHash: bytes32(0),
            signature: ""
        });
        input.signature = _sign(input, signerPk);
    }

    function _sign(
        ReservationSessionFacet.SessionStartedInput memory input,
        uint256 signerPk
    ) private view returns (bytes memory) {
        bytes32 structHash = keccak256(
            abi.encode(
                SESSION_STARTED_TYPEHASH,
                input.signer,
                input.reservationKey,
                keccak256(bytes(input.labId)),
                input.pucHash,
                keccak256(bytes(input.gatewayId)),
                keccak256(bytes(input.sessionId)),
                keccak256(bytes(input.accessType)),
                input.startedAt,
                input.nonce,
                input.credentialHash,
                input.clientProofHash
            )
        );
        bytes32 digest = keccak256(abi.encodePacked("\x19\x01", _domainSeparator(), structHash));
        (uint8 v, bytes32 r, bytes32 s) = vm.sign(signerPk, digest);
        return abi.encodePacked(r, s, v);
    }

    function _domainSeparator() private view returns (bytes32) {
        return keccak256(abi.encode(EIP712_DOMAIN_TYPEHASH, NAME_HASH, VERSION_HASH, block.chainid, address(harness)));
    }
}
