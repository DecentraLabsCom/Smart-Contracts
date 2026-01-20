// SPDX-License-Identifier: GPL-3.0-or-later
pragma solidity ^0.8.31;

import {EnumerableSet} from "@openzeppelin/contracts/utils/structs/EnumerableSet.sol";
import {BaseLightReservationFacet} from "../base/BaseLightReservationFacet.sol";
import {AppStorage} from "../../../libraries/LibAppStorage.sol";

/// @title InstitutionalReservationFacet
/// @dev Facet for institutional reservation expired releases

contract InstitutionalReservationFacet is BaseLightReservationFacet {
    using EnumerableSet for EnumerableSet.Bytes32Set;
    using EnumerableSet for EnumerableSet.AddressSet;

    error EmptyPuc();
    error InvalidBatchSize();

    function releaseInstitutionalExpiredReservations(
        address institutionalProvider,
        string calldata puc,
        uint256 _labId,
        uint256 maxBatch
    ) external onlyInstitution(institutionalProvider) returns (uint256 processed) {
        AppStorage storage s = _s();

        require(s.institutionalBackends[institutionalProvider] != address(0), "No authorized backend");
        require(msg.sender == s.institutionalBackends[institutionalProvider], "Not authorized backend");
        require(bytes(puc).length > 0, "PUC cannot be empty");

        if (maxBatch == 0 || maxBatch > 50) revert InvalidBatchSize();
        if (bytes(puc).length == 0) revert EmptyPuc();
        bytes32 pucHash = keccak256(bytes(puc));
        address hashKey = _trackingKeyFromInstitutionHash(institutionalProvider, pucHash);
        return _releaseExpiredReservationsInternal(_labId, hashKey, maxBatch);
    }
}
