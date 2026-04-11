// SPDX-License-Identifier: GPL-3.0-or-later
pragma solidity ^0.8.33;

import {IERC721Errors} from "@openzeppelin/contracts/interfaces/draft-IERC6093.sol";

library LibERC721Storage {
    struct ERC721Storage {
        string _name;
        string _symbol;
        mapping(uint256 tokenId => address) _owners;
        mapping(address owner => uint256) _balances;
        mapping(uint256 tokenId => address) _tokenApprovals;
        mapping(address owner => mapping(address operator => bool)) _operatorApprovals;
    }

    // keccak256(abi.encode(uint256(keccak256("openzeppelin.storage.ERC721")) - 1)) & ~bytes32(uint256(0xff))
    bytes32 internal constant ERC721_STORAGE_LOCATION =
        0x80bb2b638cc20bc4d0a60d66940f3ab4a00c1d7b313497ca82fb0b4ab0079300;

    function ownerOf(
        uint256 tokenId
    ) internal view returns (address owner) {
        owner = ownerOfOptional(tokenId);
        if (owner == address(0)) {
            revert IERC721Errors.ERC721NonexistentToken(tokenId);
        }
    }

    function ownerOfOptional(
        uint256 tokenId
    ) internal view returns (address) {
        return layout()._owners[tokenId];
    }

    function balanceOf(
        address owner
    ) internal view returns (uint256) {
        return layout()._balances[owner];
    }

    function setOwnerForTest(
        uint256 tokenId,
        address owner
    ) internal {
        ERC721Storage storage $ = layout();
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

    function layout() internal pure returns (ERC721Storage storage $) {
        bytes32 position = ERC721_STORAGE_LOCATION;
        assembly {
            $.slot := position
        }
    }
}
