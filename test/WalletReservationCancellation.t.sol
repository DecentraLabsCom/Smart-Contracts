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

        vm.prank(user1);
        harness.ext_cancelBooking(key);

        // reservation should be cancelled
        assertEq(harness.getReservationStatus(key), uint8(5)); // _CANCELLED
        assertEq(harness.getServiceCreditBalance(user1), 0);
    }

    function test_cancelBooking_wallet_refunds_service_credit() public {
        uint256 labId = 57;
        uint32 start = 6000;
        bytes32 key = keccak256(abi.encodePacked(labId, start));

        harness.setReservation(key, user1, 1_000_000, _CONFIRMED, labId, start, address(0x0), "");
        harness.setOwner(labId, user1);
        // Simulate the lock that happens on confirmation in the new credit ledger model
        harness.setServiceCreditBalance(user1, 1_000_000);
        harness.setCreditLockedBalance(user1, 1_000_000);

        vm.prank(user1);
        harness.ext_cancelBooking(key);

        assertEq(harness.getReservationStatus(key), uint8(5));
        // Refund = 970_000 (97% of price), fee captured = 30_000 (3%)
        // Total balance = 1_000_000 - 30_000 (captured) = 970_000
        assertEq(harness.getServiceCreditBalance(user1), 970_000);
    }
}
