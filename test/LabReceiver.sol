// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.33;

import {IERC721Receiver} from "@openzeppelin/contracts/token/ERC721/IERC721Receiver.sol";
import {LabAdminFacet} from "../contracts/facets/lab/LabAdminFacet.sol";
import {LabFacet} from "../contracts/facets/lab/LabFacet.sol";
import {LabIntentFacet} from "../contracts/facets/lab/LabIntentFacet.sol";
import {LabQueryFacet} from "../contracts/facets/lab/LabQueryFacet.sol";
import {ActionIntentPayload} from "../contracts/libraries/IntentTypes.sol";

contract LabReceiver is IERC721Receiver {
    address private immutable diamond;
    address private immutable transferRecipient;
    bool private immutable createNested;
    bool private immutable rejectMint;

    bool public listedDuringCallback;
    bytes32 public creatorDuringCallback;
    string public uriDuringCallback;

    constructor(
        address diamond_,
        address transferRecipient_,
        bool createNested_,
        bool rejectMint_
    ) {
        diamond = diamond_;
        transferRecipient = transferRecipient_;
        createNested = createNested_;
        rejectMint = rejectMint_;
    }

    function createListed(
        bytes32 creatorHash
    ) external {
        LabAdminFacet(diamond).addAndListLabWithPucHash("outer", 100, "access", "key", 0, creatorHash);
    }

    function createWithIntent(
        bytes32 requestId,
        ActionIntentPayload calldata payload
    ) external {
        LabIntentFacet(diamond).addLabWithIntent(requestId, payload);
    }

    function onERC721Received(
        address,
        address,
        uint256 tokenId,
        bytes calldata
    ) external returns (bytes4) {
        require(msg.sender == diamond);
        if (rejectMint) revert("receiver rejects mint");
        if (tokenId == 1) {
            listedDuringCallback = LabQueryFacet(diamond).isLabListed(tokenId);
            creatorDuringCallback = LabQueryFacet(diamond).getPucHash(tokenId);
            uriDuringCallback = LabFacet(diamond).tokenURI(tokenId);
            if (transferRecipient != address(0)) {
                LabFacet(diamond).transferFrom(address(this), transferRecipient, tokenId);
            }
            if (createNested) {
                LabAdminFacet(diamond).addLabWithPucHash("nested", 200, "access", "key", 0, keccak256("nested"));
            }
        }
        return IERC721Receiver.onERC721Received.selector;
    }
}
