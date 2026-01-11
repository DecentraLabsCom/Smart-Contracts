// SPDX-License-Identifier: GPL-3.0-or-later
pragma solidity ^0.8.31;

import {Initializable} from "@openzeppelin/contracts-upgradeable/proxy/utils/Initializable.sol";
import {LibDiamond} from "../libraries/LibDiamond.sol";

/// @notice Single entrypoint to initialize diamond state across facets.
contract InitFacet is Initializable {
    function initializeDiamond(
        string calldata adminName,
        string calldata adminEmail,
        string calldata adminCountry,
        address labToken,
        string calldata labName,
        string calldata labSymbol
    ) external reinitializer(2) {
        LibDiamond.enforceIsContractOwner();
        _delegateInit(
            abi.encodeWithSignature(
                "initialize(string,string,string,address)",
                adminName,
                adminEmail,
                adminCountry,
                labToken
            )
        );
        _delegateInit(
            abi.encodeWithSignature(
                "initialize(string,string)",
                labName,
                labSymbol
            )
        );
    }

    function _delegateInit(bytes memory data) private {
        // Delegate to the diamond so msg.sender stays the external caller (owner).
        (bool success, bytes memory error) = address(this).delegatecall(data);
        if (!success) {
            if (error.length > 0) {
                assembly {
                    revert(add(32, error), mload(error))
                }
            }
            revert("InitFacet: delegatecall failed");
        }
    }
}
