// SPDX-License-Identifier: MIT
pragma solidity ^0.8.33;

//*****************************************************************************\
//* Author: Nick Mudge <nick@perfectabstractions.com> (https://twitter.com/mudgen)
//* EIP-2535 Diamonds: https://eips.ethereum.org/EIPS/eip-2535
//******************************************************************************/

interface IDiamond {
    enum FacetCutAction {
        Add,
        Replace,
        Remove
    }
    // Add=0, Replace=1, Remove=2

    struct FacetCut {
        address facetAddress;
        FacetCutAction action;
        bytes4[] functionSelectors;
    }

    // EIP-2535 defines this event without indexed parameters; changing it would break event consumers.
    // slither-disable-next-line unindexed-event-address
    event DiamondCut(FacetCut[] _diamondCut, address _init, bytes _calldata);
}
