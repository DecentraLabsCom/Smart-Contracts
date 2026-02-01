// SPDX-License-Identifier: MIT
pragma solidity ^0.8.33;

import {Test} from "forge-std/Test.sol";
import {WalletReservationCoreFacet} from "../contracts/facets/reservation/wallet/WalletReservationCoreFacet.sol";
import {WalletReservationReleaseFacet} from "../contracts/facets/reservation/wallet/WalletReservationReleaseFacet.sol";
import {
    WalletReservationConfirmationFacet
} from "../contracts/facets/reservation/wallet/WalletReservationConfirmationFacet.sol";
import {AppStorage, LabBase, LibAppStorage} from "../contracts/libraries/LibAppStorage.sol";
import {LibWalletReservationConfirmation} from "../contracts/libraries/LibWalletReservationConfirmation.sol";
import {ReservableTokenEnumerable} from "../contracts/abstracts/ReservableTokenEnumerable.sol";
import {LibAccessControlEnumerable} from "../contracts/libraries/LibAccessControlEnumerable.sol";
import {EnumerableSet} from "@openzeppelin/contracts/utils/structs/EnumerableSet.sol";
import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import {ERC721} from "@openzeppelin/contracts/token/ERC721/ERC721.sol";
import {ERC721Enumerable} from "@openzeppelin/contracts/token/ERC721/extensions/ERC721Enumerable.sol";

contract MockERC20 is ERC20 {
    constructor() ERC20("MockLabToken", "MLAB") {}

    function mint(
        address to,
        uint256 amount
    ) external {
        _mint(to, amount);
    }
}

/// @dev Minimal harness combining ERC721 and wallet reservation logic in a single contract
contract ReservationHarness is ERC721Enumerable, WalletReservationCoreFacet, WalletReservationReleaseFacet {
    using LibAccessControlEnumerable for AppStorage;
    using EnumerableSet for EnumerableSet.Bytes32Set;

    constructor() ERC721("Labs", "LAB") {}

    function initializeHarness(
        address labToken
    ) external {
        AppStorage storage s = LibAppStorage.diamondStorage();
        s.labTokenAddress = labToken;
        s.DEFAULT_ADMIN_ROLE = keccak256("DEFAULT_ADMIN_ROLE");
        s._addProviderRole(msg.sender, "provider", "provider@example.com", "ES", "");
        s.providerStakes[msg.sender].stakedAmount = type(uint256).max;
    }

    function mintAndList(
        uint96 price
    ) external returns (uint256 id) {
        AppStorage storage s = LibAppStorage.diamondStorage();
        id = s.labId + 1;
        _mint(msg.sender, id);
        s.labId = id;
        s.labs[id] = LabBase({
            uri: "uri", price: price, accessURI: "accessURI", accessKey: "accessKey", createdAt: uint32(block.timestamp)
        });
        s.providerStakes[msg.sender].listedLabsCount += 1;
        s.tokenStatus[id] = true;
    }

    // Staking facet stub to satisfy internal call
    function updateLastReservation(
        address
    ) external {}

    // Test helper: set activeReservationCountByTokenAndUser for harness storage
    function setActiveCount(
        uint256 labId,
        address user,
        uint8 v
    ) external {
        AppStorage storage s = LibAppStorage.diamondStorage();
        s.activeReservationCountByTokenAndUser[labId][user] = v;
    }

    // Test helper: get activeReservationCountByTokenAndUser from harness storage
    function getActiveCount(
        uint256 labId,
        address user
    ) external view returns (uint8) {
        AppStorage storage s = LibAppStorage.diamondStorage();
        return s.activeReservationCountByTokenAndUser[labId][user];
    }

    // Test helper: get per-user reservation keys length for a token
    function getReservationKeysByTokenAndUserLength(
        uint256 labId,
        address user
    ) external view returns (uint256) {
        AppStorage storage s = LibAppStorage.diamondStorage();
        return s.reservationKeysByTokenAndUser[labId][user].length();
    }

    // Test helper: get total reservation keys length for a token
    function getReservationKeysByTokenLength(
        uint256 labId
    ) external view returns (uint256) {
        AppStorage storage s = LibAppStorage.diamondStorage();
        return s.reservationKeysByToken[labId].length();
    }

    // Test helper: get number of reservation entries for a renter
    function getRentersLength(
        address renter
    ) external view returns (uint256) {
        AppStorage storage s = LibAppStorage.diamondStorage();
        return s.renters[renter].length();
    }

    // Resolve conflicting confirmReservationRequest implementations by routing to the library implementation
    function confirmReservationRequest(
        bytes32 _reservationKey
    ) public override(ReservableTokenEnumerable) {
        LibWalletReservationConfirmation.confirmReservationRequest(_reservationKey);
    }

    // ERC165 override
    function supportsInterface(
        bytes4 interfaceId
    ) public view override(ERC721Enumerable) returns (bool) {
        return super.supportsInterface(interfaceId);
    }
}

contract GasReservationsTest is Test {
    ReservationHarness harness;
    MockERC20 token;
    address user = address(0xBEEF);
    uint256 labId;
    uint96 price = 1e6;

    function setUp() public {
        token = new MockERC20();
        harness = new ReservationHarness();
        harness.initializeHarness(address(token));

        labId = harness.mintAndList(price);

        // Give user funds and approval
        token.mint(user, 10 ether);
        vm.prank(user);
        token.approve(address(harness), type(uint256).max);
    }

    function _reservationKey(
        uint32 start
    ) internal view returns (bytes32) {
        return keccak256(abi.encodePacked(labId, start));
    }

    function testGas_ReservationRequest() public {
        uint32 start = uint32(block.timestamp + 1000);
        uint32 end = start + 1000;
        vm.prank(user);
        harness.reservationRequest(labId, start, end);
    }

    function testGas_DenyReservationRequest() public {
        uint32 start = uint32(block.timestamp + 2000);
        uint32 end = start + 1000;
        vm.prank(user);
        harness.reservationRequest(labId, start, end);

        bytes32 key = _reservationKey(start);
        vm.prank(address(this));
        harness.denyReservationRequest(key);
    }

    function testGas_ConfirmReservationRequest() public {
        uint32 start = uint32(block.timestamp + 3000);
        uint32 end = start + 1000;
        vm.prank(user);
        harness.reservationRequest(labId, start, end);

        bytes32 key = _reservationKey(start);
        vm.prank(address(this));
        harness.confirmReservationRequest(key);
    }

    function testGas_CancelBooking() public {
        uint32 start = uint32(block.timestamp + 4000);
        uint32 end = start + 1000;
        vm.prank(user);
        harness.reservationRequest(labId, start, end);

        bytes32 key = _reservationKey(start);
        vm.prank(address(this));
        harness.confirmReservationRequest(key);

        vm.prank(user);
        harness.cancelBooking(key);
    }
}
