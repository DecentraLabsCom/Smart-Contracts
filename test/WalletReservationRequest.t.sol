// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.33;

import "forge-std/Test.sol";
import "./BaseTest.sol";
import "./Harnesses.sol";
import "../contracts/facets/reservation/wallet/WalletReservationCoreFacet.sol";
import "../contracts/libraries/LibAppStorage.sol";

// Minimal ERC20 used for tests
contract DummyERC20 {
    mapping(address => uint256) public balances;
    mapping(address => mapping(address => uint256)) public allowances;

    function setBalance(
        address who,
        uint256 amount
    ) external {
        balances[who] = amount;
    }

    function setAllowance(
        address owner,
        address spender,
        uint256 amount
    ) external {
        allowances[owner][spender] = amount;
    }

    function balanceOf(
        address who
    ) external view returns (uint256) {
        return balances[who];
    }

    function allowance(
        address owner,
        address spender
    ) external view returns (uint256) {
        return allowances[owner][spender];
    }
}

contract WalletRequestHarness is WalletReservationCoreFacet {
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

    function setTokenStatus(
        uint256 tokenId,
        bool status
    ) external {
        AppStorage storage s = LibAppStorage.diamondStorage();
        s.tokenStatus[tokenId] = status;
    }

    function setLabPrice(
        uint256 tokenId,
        uint96 price
    ) external {
        AppStorage storage s = LibAppStorage.diamondStorage();
        s.labs[tokenId].price = price;
    }

    function setLabTokenAddress(
        address addr
    ) external {
        AppStorage storage s = LibAppStorage.diamondStorage();
        s.labTokenAddress = addr;
    }

    function setProviderStake(
        address p,
        uint256 v
    ) external {
        AppStorage storage s = LibAppStorage.diamondStorage();
        s.providerStakes[p].stakedAmount = v;
    }

    function request(
        uint256 labId,
        uint32 start,
        uint32 end
    ) external {
        this.reservationRequest(labId, start, end);
    }

    function getReservationRenter(
        bytes32 key
    ) external view returns (address) {
        AppStorage storage s = LibAppStorage.diamondStorage();
        return s.reservations[key].renter;
    }

    function getReservationStatus(
        bytes32 key
    ) external view returns (uint8) {
        AppStorage storage s = LibAppStorage.diamondStorage();
        return s.reservations[key].status;
    }
}

contract WalletReservationRequestTest is BaseTest {
    WalletRequestHarness public harness;
    DummyERC20 public token;

    function setUp() public override {
        super.setUp();
        harness = new WalletRequestHarness();
        token = new DummyERC20();
    }

    function test_reservationRequest_reverts_when_lab_not_listed() public {
        uint256 labId = 11;
        harness.setOwner(labId, address(this));
        harness.setTokenStatus(labId, false);

        vm.expectRevert();
        harness.request(labId, uint32(block.timestamp + 100), uint32(block.timestamp + 200));
    }

    function test_reservationRequest_insufficient_funds() public {
        uint256 labId = 12;
        harness.setOwner(labId, address(this));
        harness.setTokenStatus(labId, true);
        harness.setProviderStake(address(this), 1_000_000); // keep stake high enough

        harness.setLabPrice(labId, 1000);
        harness.setLabTokenAddress(address(token));

        // set balance lower than price
        token.setBalance(address(this), 10);
        token.setAllowance(address(this), address(harness), 1000);

        vm.expectRevert();
        harness.request(labId, uint32(block.timestamp + 100), uint32(block.timestamp + 200));
    }

    function test_reservationRequest_low_allowance_reverts() public {
        uint256 labId = 13;
        harness.setOwner(labId, address(this));
        harness.setTokenStatus(labId, true);
        harness.setProviderStake(address(this), 1_000_000);

        harness.setLabPrice(labId, 1000);
        harness.setLabTokenAddress(address(token));

        token.setBalance(address(this), 2000);
        token.setAllowance(address(this), address(harness), 10); // too low

        vm.expectRevert();
        harness.request(labId, uint32(block.timestamp + 100), uint32(block.timestamp + 200));
    }

    function test_reservationRequest_success_creates_reservation() public {
        uint256 labId = 14;
        harness.setOwner(labId, address(this));
        harness.setTokenStatus(labId, true);
        harness.setProviderStake(address(this), 1_000_000);

        harness.setLabPrice(labId, 500);
        harness.setLabTokenAddress(address(token));

        token.setBalance(address(harness), 1000);
        token.setAllowance(address(harness), address(harness), 1000);

        uint32 start = uint32(block.timestamp + 3600);
        uint32 end = start + 3600;

        vm.expectEmit(true, true, false, true);
        emit ReservationRequested(address(harness), labId, start, end, keccak256(abi.encodePacked(labId, start)));

        harness.request(labId, start, end);

        // verify that reservation exists
        bytes32 key = keccak256(abi.encodePacked(labId, start));
        assertEq(harness.getReservationRenter(key), address(harness));
        assertEq(harness.getReservationStatus(key), 0);
    }

    // duplicate event signature placer
    event ReservationRequested(
        address indexed renter, uint256 indexed lab, uint256 start, uint256 end, bytes32 indexed reservationKey
    );
}
