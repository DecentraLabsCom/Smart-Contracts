// SPDX-License-Identifier: GPL-3.0-or-later
pragma solidity ^0.8.33;

import {LibAppStorage, AppStorage, LabReputation} from "./LibAppStorage.sol";

/// @notice Library with helpers to manage lab reputation
/// @dev Reputation is based on total points (completions - cancellations)
///      Rating is calculated as points / events for weighted score
library LibReputation {
    int32 internal constant MIN_SCORE = -10_000;
    int32 internal constant MAX_SCORE = 10_000;
    int32 internal constant CANCELLATION_PENALTY = -1;
    int32 internal constant COMPLETION_REWARD = 1;

    event LabReputationAdjusted(uint256 indexed labId, int32 delta, int32 newScore, uint32 totalEvents, string reason);

    event LabReputationSet(uint256 indexed labId, int32 newScore, string reason);

    function recordOwnerCancellation(
        uint256 labId
    ) internal returns (int32 newScore) {
        AppStorage storage s = LibAppStorage.diamondStorage();
        LabReputation storage rep = s.labReputation[labId];
        rep.ownerCancellations += 1;
        newScore = _applyDelta(rep, CANCELLATION_PENALTY);
        emit LabReputationAdjusted(labId, CANCELLATION_PENALTY, newScore, rep.totalEvents, "OWNER_CANCEL");
    }

    function recordInstitutionalCancellation(
        uint256 labId
    ) internal returns (int32 newScore) {
        AppStorage storage s = LibAppStorage.diamondStorage();
        LabReputation storage rep = s.labReputation[labId];
        rep.institutionalCancellations += 1;
        newScore = _applyDelta(rep, CANCELLATION_PENALTY);
        emit LabReputationAdjusted(labId, CANCELLATION_PENALTY, newScore, rep.totalEvents, "INSTITUTION_CANCEL");
    }

    function recordCompletion(
        uint256 labId
    ) internal returns (int32 newScore) {
        AppStorage storage s = LibAppStorage.diamondStorage();
        LabReputation storage rep = s.labReputation[labId];
        newScore = _applyDelta(rep, COMPLETION_REWARD);
        emit LabReputationAdjusted(labId, COMPLETION_REWARD, newScore, rep.totalEvents, "COMPLETED");
    }

    function adjustScore(
        uint256 labId,
        int32 delta,
        string memory reason
    ) internal returns (int32 newScore) {
        AppStorage storage s = LibAppStorage.diamondStorage();
        LabReputation storage rep = s.labReputation[labId];
        newScore = _applyDelta(rep, delta);
        emit LabReputationAdjusted(labId, delta, newScore, rep.totalEvents, reason);
    }

    function setScore(
        uint256 labId,
        int32 newScore,
        string memory reason
    ) internal {
        AppStorage storage s = LibAppStorage.diamondStorage();
        LabReputation storage rep = s.labReputation[labId];
        rep.score = _clampScore(newScore);
        rep.lastUpdated = uint64(block.timestamp);
        emit LabReputationSet(labId, rep.score, reason);
    }

    function _applyDelta(
        LabReputation storage rep,
        int32 delta
    ) private returns (int32 newScore) {
        int64 raw = int64(rep.score) + int64(delta);
        if (raw > int64(MAX_SCORE)) {
            raw = int64(MAX_SCORE);
        } else if (raw < int64(MIN_SCORE)) {
            raw = int64(MIN_SCORE);
        }
        newScore = int32(raw);
        // forge-lint: disable-next-line(unsafe-typecast)
        rep.score = newScore;
        rep.totalEvents += 1;
        rep.lastUpdated = uint64(block.timestamp);
    }

    function _clampScore(
        int32 score
    ) private pure returns (int32) {
        if (score > MAX_SCORE) return MAX_SCORE;
        if (score < MIN_SCORE) return MIN_SCORE;
        return score;
    }
}
