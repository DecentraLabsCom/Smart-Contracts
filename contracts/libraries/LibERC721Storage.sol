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

    // Derived from: keccak256(abi.encode(uint256(keccak256("openzeppelin.storage.ERC721")) - 1)) & ~bytes32(uint256(0xff))
    // Verified against @openzeppelin/contracts-upgradeable v5.x (ERC721Upgradeable, EIP-7201 namespaced storage).
    // IMPORTANT: Re-verify this slot before upgrading OpenZeppelin. Run:
    //   cast keccak "openzeppelin.storage.ERC721" | cast to-uint256 | python3 -c "import sys; v=int(sys.stdin.read())-1; print(hex(v & ~0xff))"
    // Expected: 0x80bb2b638cc20bc4d0a60d66940f3ab4a00c1d7b313497ca82fb0b4ab0079300
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

    function layout() internal pure returns (ERC721Storage storage $) {
        bytes32 position = ERC721_STORAGE_LOCATION;
        assembly {
            $.slot := position
        }
    }
}
