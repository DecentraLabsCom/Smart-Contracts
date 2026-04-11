// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.33;

import {LibERC721Storage} from "../contracts/libraries/LibERC721Storage.sol";

/// @dev Test-only helpers that write directly to the ERC-721 namespaced storage slot.
///      MUST NOT be used in production deployments.
library LibERC721StorageTestHelper {
    function setOwnerForTest(
        uint256 tokenId,
        address owner
    ) internal {
        LibERC721Storage.ERC721Storage storage $ = LibERC721Storage.layout();
        address previousOwner = $._owners[tokenId];

        if (previousOwner == owner) {
            return;
        }

        if (previousOwner != address(0)) {
            unchecked {
                $._balances[previousOwner] -= 1;
            }
        }

        $._owners[tokenId] = owner;

        if (owner != address(0)) {
            unchecked {
                $._balances[owner] += 1;
            }
        }
    }
}
