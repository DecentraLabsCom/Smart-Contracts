// SPDX-License-Identifier: MIT
pragma solidity ^0.8.33;

import {Test} from "forge-std/Test.sol";
import {ReservationHarness, MockERC20} from "./GasReservations.t.sol";

contract GasReservationsScalingTest is Test {
    uint96 price = 1e6;

    function testGas_ConfirmScaling() public {
        uint32 startBase = uint32(block.timestamp + 1000);
        uint256[8] memory sizes = [uint256(1), 2, 5, 10, 20, 50, 100, 200];

        for (uint256 si = 0; si < sizes.length; ++si) {
            uint256 n = sizes[si];

            // Deploy fresh harness + token for isolation
            MockERC20 token = new MockERC20();
            ReservationHarness harness = new ReservationHarness();
            harness.initializeHarness(address(token));
            uint256 labId = harness.mintAndList(price);

            // create n distinct pending reservations (distinct users to avoid user caps)
            for (uint256 i = 0; i < n; ++i) {
                address u = address(uint160(0x100 + i));
                token.mint(u, 1 ether);
                vm.prank(u);
                token.approve(address(harness), type(uint256).max);

                uint32 s = startBase + uint32(i + 1);
                vm.prank(u);
                harness.reservationRequest(labId, s, s + 1000);
            }

            // confirm the first reservation and measure gas
            bytes32 key = keccak256(abi.encodePacked(labId, startBase + 1));
            vm.prank(address(this));
            uint256 gasBefore = gasleft();
            harness.confirmReservationRequest(key);
            uint256 gasUsed = gasBefore - gasleft();

            emit log_named_uint("num_reservations", n);
            emit log_named_uint("confirm_gas_used", gasUsed);
        }
    }
}
