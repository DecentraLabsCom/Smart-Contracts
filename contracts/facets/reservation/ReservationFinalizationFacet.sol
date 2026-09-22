// SPDX-License-Identifier: GPL-3.0-or-later
pragma solidity ^0.8.33;

import {ReentrancyGuardTransient} from "@openzeppelin/contracts/utils/ReentrancyGuardTransient.sol";
import {AppStorage, LibAppStorage, PayoutCandidate} from "../../libraries/LibAppStorage.sol";
import {LibReservationFinalization} from "../../libraries/LibReservationFinalization.sol";

/// @title ReservationFinalizationFacet
/// @notice Permissionless bounded maintenance for economically expired reservations.
contract ReservationFinalizationFacet is ReentrancyGuardTransient {
    uint256 internal constant _MAX_BATCH = 10;

    /// @notice Emitted after a permissionless finalization sweep.
    /// @dev The caller is only the gas payer. Economic and reputational effects
    ///      are determined by the shared settlement libraries.
    event ReservationFinalizationBatchProcessed(
        address indexed caller,
        uint256 indexed labId,
        uint256 finalizedCount,
        uint256 maxBatch,
        uint64 oldestCandidateEnd,
        uint64 processedAt,
        bool pendingGraceEncountered,
        bool scanLimitReached
    );

    /// @notice Finalizes eligible reservations without queuing provider receivable.
    function finalizeEligibleReservations(
        uint256 labId,
        uint256 maxBatch
    ) external nonReentrant returns (uint256 finalizedCount) {
        if (maxBatch == 0 || maxBatch > _MAX_BATCH) revert("Invalid batch size");

        AppStorage storage s = LibAppStorage.diamondStorage();
        PayoutCandidate[] storage heap = s.payoutHeaps[labId];
        uint64 oldestCandidateEnd = heap.length == 0 ? 0 : uint64(heap[0].end);
        bool pendingGraceEncountered;
        bool scanLimitReached;
        (finalizedCount, pendingGraceEncountered, scanLimitReached) =
            LibReservationFinalization.finalizeEligibleBatch(s, labId, maxBatch, block.timestamp);

        emit ReservationFinalizationBatchProcessed(
            msg.sender,
            labId,
            finalizedCount,
            maxBatch,
            oldestCandidateEnd,
            uint64(block.timestamp),
            pendingGraceEncountered,
            scanLimitReached
        );
    }
}
