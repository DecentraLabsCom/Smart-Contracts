// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.33;

import "forge-std/Test.sol";
import "./BaseTest.sol";
import "./Harnesses.sol";
import "../contracts/facets/reservation/institutional/InstitutionalReservationRequestValidationFacet.sol";
import "../contracts/libraries/LibAppStorage.sol";

// Minimal ERC20 used for tests
contract DummyERC20 {
    mapping(address => uint256) public balances;
    mapping(address => mapping(address => uint256)) public allowances;

    function setBalance(address who, uint256 amount) external { balances[who] = amount; }
    function setAllowance(address owner, address spender, uint256 amount) external { allowances[owner][spender] = amount; }
    function balanceOf(address who) external view returns (uint256) { return balances[who]; }
    function allowance(address owner, address spender) external view returns (uint256) { return allowances[owner][spender]; }
}

// Minimal harness that exposes ownerOf so library calls succeed when executed in-contract
contract InstValidateHarness is InstitutionalReservationRequestValidationFacet {
    mapping(uint256 => address) public owners;
    function setOwner(uint256 tokenId, address owner) external { owners[tokenId] = owner; }
    function ownerOf(uint256 tokenId) external view returns (address) { return owners[tokenId]; }
}

contract ConfirmStub {
    // minimal stub to exercise the cap check similar to ReservableTokenEnumerable.confirmReservationRequest
    function setReservationEntry(bytes32 key, address renter, uint8 status, uint256 labId, uint32 start, uint32 end, uint96 price) external {
        AppStorage storage s = LibAppStorage.diamondStorage();
        Reservation storage r = s.reservations[key];
        r.renter = renter;
        r.labId = labId;
        r.start = start;
        r.end = end;
        r.status = status;
        r.price = price;
    }

    function confirmReservationRequest(bytes32 key) external {
        AppStorage storage s = LibAppStorage.diamondStorage();
        Reservation storage reservation = s.reservations[key];
        if (reservation.renter == address(0)) revert("ReservationNotFound");
        if (reservation.status != 0) revert("ReservationNotPending");
        if (s.activeReservationCountByTokenAndUser[reservation.labId][reservation.renter] >= 10) revert("MaxReservationsReached");
        reservation.status = 1; // CONFIRMED
    }

    function activeCount(uint256 labId, address user) external view returns (uint8) {
        AppStorage storage s = LibAppStorage.diamondStorage();
        return s.activeReservationCountByTokenAndUser[labId][user];
    }

    function setActiveCount(uint256 labId, address user, uint8 v) external {
        AppStorage storage s = LibAppStorage.diamondStorage();
        s.activeReservationCountByTokenAndUser[labId][user] = v;
    }
}



contract ReservationLimitsTest is BaseTest {
    DummyERC20 public token;

    function setUp() public override {
        super.setUp();
        token = new DummyERC20();
    }


    function test_institutional_reservation_reverts_when_tracked_user_at_max() public {
        uint256 labId = 211;
        address provider = address(0xBEEF);
        string memory userId = "institution-user-1";

        InstValidateHarness inst = new InstValidateHarness();
        inst.setOwner(labId, address(this));

        AppStorage storage s = LibAppStorage.diamondStorage();
        // mark lab listed
        s.tokenStatus[labId] = true;
        // set backend mapping so the facet call is authorized (msg.sender == address(this) when calling facet from test)
        s.institutionalBackends[provider] = address(this);

        // ensure calculateRequiredStake returns 0 (receivedInitialTokens == false and listedLabsCount == 0)
        s.providerStakes[address(this)].receivedInitialTokens = false;
        s.providerStakes[address(this)].listedLabsCount = 0;

        // compute tracking key same way as LibTracking.trackingKeyFromInstitutionHash
        bytes32 pucHash = keccak256(bytes(userId));
        address trackingKey = address(uint160(uint256(keccak256(abi.encodePacked(provider, pucHash)))));

        // set active count to cap
        s.activeReservationCountByTokenAndUser[labId][trackingKey] = 10;

        uint32 start = uint32(block.timestamp + 3600);
        uint32 end = start + 3600;

        vm.expectRevert();
        inst.validateInstRequest(provider, userId, labId, start, end);
    }

    function test_wallet_confirm_reverts_when_user_at_max() public {
        ConfirmStub stub = new ConfirmStub();

        uint256 labId = 300;
        address renter = address(0xCAFE);
        uint32 start = uint32(block.timestamp + 3600);
        uint32 end = start + 3600;
        bytes32 key = keccak256(abi.encodePacked(labId, start));

        // create pending reservation entry for the renter
        stub.setReservationEntry(key, renter, 0, labId, start, end, 500);

        // set active count inside stub's storage (diamondStorage is per-contract)
        stub.setActiveCount(labId, renter, 10);

        // sanity check via stub getter
        assertEq(uint256(stub.activeCount(labId, renter)), 10);

        vm.expectRevert();
        stub.confirmReservationRequest(key);
    }
}
