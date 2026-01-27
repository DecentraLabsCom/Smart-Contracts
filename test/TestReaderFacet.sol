// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.33;

import "../contracts/libraries/LibAppStorage.sol";
import {EnumerableSet} from "@openzeppelin/contracts/utils/structs/EnumerableSet.sol";

contract TestReaderFacet {
    using EnumerableSet for EnumerableSet.AddressSet;

    function readLabTokenAddress() external view returns (address) {
        AppStorage storage s = LibAppStorage.diamondStorage();
        return s.labTokenAddress;
    }

    function isDefaultAdmin(
        address who
    ) external view returns (bool) {
        AppStorage storage s = LibAppStorage.diamondStorage();
        return s.roleMembers[s.DEFAULT_ADMIN_ROLE].contains(who);
    }
}
