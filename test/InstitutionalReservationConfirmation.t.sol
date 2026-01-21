// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.33;

import "forge-std/Test.sol";
import "./BaseTest.sol";
import "./Harnesses.sol";
import "../contracts/libraries/LibAppStorage.sol";

contract InstitutionalReservationConfirmationTest is BaseTest {
    ConfirmHarness public harness;

    uint8 internal constant _PENDING = 0;
    uint8 internal constant _CONFIRMED = 1;

    function setUp() public override {
        super.setUp();
        harness = new ConfirmHarness();
    }

    function test_confirm_with_puc_success() public {
        address inst = address(0x2222);
        uint256 labId = 99;
        uint32 start = 1234;
        bytes32 key = keccak256(abi.encodePacked(labId, start));
        string memory puc = "charlie@inst";
        uint96 price = 50;

        harness.setReservation(key, user1, inst, price, _PENDING, labId, start, puc);
        harness.setOwner(labId, provider);
        harness.setInstitutionRole(inst);
        harness.setBackend(inst, address(0x0));

        // make sure provider can fulfill
        harness.setTokenStatus(labId, true);
        harness.setProviderStake(provider, type(uint256).max);

        vm.prank(inst);
        harness.confirmInstitutionalReservationRequestWithPuc(inst, key, puc);

        assertEq(harness.getReservationStatus(key), _CONFIRMED);
        assertEq(harness.lastSpentAmount(), uint256(price));
    }
}
