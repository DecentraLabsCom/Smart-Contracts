// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.33;

import "forge-std/Test.sol";
import "./BaseTest.sol";
import "./Harnesses.sol";
import "../contracts/libraries/LibAppStorage.sol";
import "../contracts/libraries/LibWalletReservationCancellation.sol";

contract WalletReservationCancellationTest is BaseTest {
    WalletCancellationHarness public harness;
    uint8 internal constant _CONFIRMED = 1;

    function setUp() public override {
        super.setUp();
        harness = new WalletCancellationHarness();
    }

    function test_cancelBooking_institutional_reverts() public {
        uint256 labId = 55;
        uint32 start = 4000;
        bytes32 key = keccak256(abi.encodePacked(labId, start));
        string memory puc = "p@inst";

        harness.setReservation(key, user1, 0, _CONFIRMED, labId, start, address(0x0), puc);

        vm.prank(user1);
        vm.expectRevert(abi.encodeWithSelector(LibWalletReservationCancellation.UseInstitutionalCancel.selector));
        harness.ext_cancelBooking(key);
    }

    function test_cancelBooking_wallet_success() public {
        uint256 labId = 56;
        uint32 start = 5000;
        bytes32 key = keccak256(abi.encodePacked(labId, start));
        string memory puc = "";

        // no stored hash -> wallet cancellation path
        harness.setReservation(key, user1, 0, _CONFIRMED, labId, start, address(0x0), "");

        // set owner so ownerOf calls succeed in the harness
        harness.setOwner(labId, user1);
        // set token to harness so SafeERC20.safeTransfer succeeds
        harness.setLabTokenAddress(address(harness));

        vm.prank(user1);
        harness.ext_cancelBooking(key);

        // reservation should be cancelled
        assertEq(harness.getReservationStatus(key), uint8(5)); // _CANCELLED
    }
}
