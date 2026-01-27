// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.33;

import "forge-std/Test.sol";
import "./LibDiamondInitializer.t.sol";

contract LibDiamondInitializerDecode is Test {
    DiamondHarness diamond;
    UnsafeExternalInitializer unsafeInit;

    event RevertSelector(bytes4 selector);
    event RevertReason(string reason);
    event RevertRaw(bytes data);

    function setUp() public {
        diamond = new DiamondHarness();
        unsafeInit = new UnsafeExternalInitializer();
    }

    function test_captureWithoutMarkerRevertData() public {
        IDiamond.FacetCut[] memory cut = new IDiamond.FacetCut[](0);
        bytes memory initData = abi.encodeWithSelector(UnsafeExternalInitializer.init.selector);

        (bool ok, bytes memory data) = address(diamond)
            .call(abi.encodeWithSelector(diamond.callInitializeDiamondCut.selector, address(unsafeInit), initData, cut));
        assertFalse(ok, "call should have reverted");

        // data is the revert payload. If it's a standard Error(string) it starts with 0x08c379a0
        if (data.length >= 4) {
            bytes4 sel;
            assembly { sel := mload(add(data, 32)) }
            if (sel == 0x08c379a0) {
                // decode Error(string)
                // skip selector (4) + offset (32) + length (32)
                // abi.decode(data[4:], (string)) won't work directly, so use abi.decode of slice
                bytes memory sliced = new bytes(data.length - 4);
                for (uint256 i = 0; i < sliced.length; i++) {
                    sliced[i] = data[i + 4];
                }
                // decode
                string memory reason = abi.decode(sliced, (string));
                emit RevertReason(reason);
                return;
            }
            // Check for known InitializationNotAllowed selector
            if (sel == InitializationNotAllowed.selector) {
                emit RevertSelector(sel);
                return;
            }
            // Unknown selector - emit raw
            emit RevertSelector(sel);
            emit RevertRaw(data);
            return;
        }
        emit RevertRaw(data);
    }
}
