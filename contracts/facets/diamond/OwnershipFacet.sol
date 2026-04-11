// SPDX-License-Identifier: MIT
pragma solidity ^0.8.31;

import {LibDiamond} from "../../libraries/LibDiamond.sol";
import {IERC173} from "../../interfaces/IERC173.sol";

contract OwnershipFacet is IERC173 {
    /// @notice Propose a new owner (two-step transfer). Call acceptOwnership() from the new owner to complete.
    function transferOwnership(
        address _newOwner
    ) external override {
        LibDiamond.enforceIsContractOwner();
        LibDiamond.setPendingOwner(_newOwner);
    }

    /// @notice Accept pending ownership transfer. Must be called by the pending owner.
    function acceptOwnership() external {
        LibDiamond.acceptOwnership();
    }

    /// @notice Returns the pending owner address (address(0) if none).
    function pendingOwner() external view returns (address) {
        return LibDiamond.pendingOwner();
    }

    function owner() external view override returns (address owner_) {
        owner_ = LibDiamond.contractOwner();
    }
}
