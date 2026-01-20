// SPDX-License-Identifier: GPL-3.0-or-later
pragma solidity ^0.8.31;

/// @title LibTracking - Institutional user tracking key computation
/// @dev Library for computing tracking keys to reduce facet bytecode
library LibTracking {
    function trackingKeyFromInstitutionHash(address provider, bytes32 pucHash) internal pure returns (address) {
        return address(uint160(uint256(keccak256(abi.encodePacked(provider, pucHash)))));
    }
}
