// SPDX-License-Identifier: MIT
pragma solidity ^0.8.31;
//******************************************************************************\
//* Author: Nick Mudge <nick@perfectabstractions.com> (https://twitter.com/mudgen)
//* EIP-2535 Diamonds: https://eips.ethereum.org/EIPS/eip-2535
//******************************************************************************/

// The functions in DiamondLoupeFacet MUST be added to a diamond.
// The EIP-2535 Diamond standard requires these functions.

import {LibDiamond} from "../../libraries/LibDiamond.sol";
import {IDiamondLoupe} from "../../interfaces/IDiamondLoupe.sol";
import {IERC165} from "../../interfaces/IERC165.sol";

contract DiamondLoupeFacet is IDiamondLoupe, IERC165 {
    // Diamond Loupe Functions
    ////////////////////////////////////////////////////////////////////
    /// These functions are expected to be called frequently by tools.
    //
    // struct Facet {
    //     address facetAddress;
    //     bytes4[] functionSelectors;
    // }
    /// @notice Gets all facets and their selectors.
    /// @return facets_ Facet
    function facets() external view override returns (Facet[] memory facets_) {
        LibDiamond.DiamondStorage storage ds = LibDiamond.diamondStorage();
        uint256 facetCount = ds.facetAddresses.length;
        facets_ = new Facet[](facetCount);

        for (uint256 facetIndex; facetIndex < facetCount; ) {
            address facetAddress_ = ds.facetAddresses[facetIndex];
            facets_[facetIndex].facetAddress = facetAddress_;
            facets_[facetIndex].functionSelectors = _copySelectors(ds.facetFunctionSelectors[facetAddress_]);
            unchecked {
                ++facetIndex;
            }
        }
    }

    /// @notice Gets all the function selectors supported by a specific facet.
    /// @param _facet The facet address.
    /// @return _facetFunctionSelectors The selectors associated with a facet address.
    function facetFunctionSelectors(
        address _facet
    ) external view override returns (bytes4[] memory _facetFunctionSelectors) {
        LibDiamond.DiamondStorage storage ds = LibDiamond.diamondStorage();
        _facetFunctionSelectors = _copySelectors(ds.facetFunctionSelectors[_facet]);
    }

    /// @notice Get all the facet addresses used by a diamond.
    /// @return facetAddresses_
    function facetAddresses() external view override returns (address[] memory facetAddresses_) {
        LibDiamond.DiamondStorage storage ds = LibDiamond.diamondStorage();
        uint256 facetCount = ds.facetAddresses.length;
        facetAddresses_ = new address[](facetCount);
        for (uint256 facetIndex; facetIndex < facetCount; ) {
            facetAddresses_[facetIndex] = ds.facetAddresses[facetIndex];
            unchecked {
                ++facetIndex;
            }
        }
    }

    /// @notice Gets the facet address that supports the given selector.
    /// @dev If facet is not found return address(0).
    /// @param _functionSelector The function selector.
    /// @return facetAddress_ The facet address.
    function facetAddress(
        bytes4 _functionSelector
    ) external view override returns (address facetAddress_) {
        LibDiamond.DiamondStorage storage ds = LibDiamond.diamondStorage();
        facetAddress_ = ds.facetAddressAndSelectorPosition[_functionSelector].facetAddress;
    }

    // This implements ERC-165.
    function supportsInterface(
        bytes4 _interfaceId
    ) external view override returns (bool) {
        LibDiamond.DiamondStorage storage ds = LibDiamond.diamondStorage();
        return ds.supportedInterfaces[_interfaceId];
    }

    function _copySelectors(
        bytes4[] storage storageSelectors
    ) internal view returns (bytes4[] memory selectors) {
        uint256 selectorCount = storageSelectors.length;
        selectors = new bytes4[](selectorCount);
        for (uint256 selectorIndex; selectorIndex < selectorCount; ) {
            selectors[selectorIndex] = storageSelectors[selectorIndex];
            unchecked {
                ++selectorIndex;
            }
        }
    }
}
