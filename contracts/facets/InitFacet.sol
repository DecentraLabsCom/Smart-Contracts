// SPDX-License-Identifier: GPL-3.0-or-later
pragma solidity ^0.8.31;

import {Initializable} from "@openzeppelin/contracts-upgradeable/proxy/utils/Initializable.sol";
import {LibDiamond} from "../libraries/LibDiamond.sol";

interface IProviderFacetInit {
    function initialize(
        string calldata name,
        string calldata email,
        string calldata country,
        address labErc20
    ) external;
}

interface ILabFacetInit {
    function initialize(string calldata name, string calldata symbol) external;
}

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
        IProviderFacetInit(address(this)).initialize(adminName, adminEmail, adminCountry, labToken);
        ILabFacetInit(address(this)).initialize(labName, labSymbol);
    }
}
