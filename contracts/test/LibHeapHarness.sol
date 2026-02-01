// SPDX-License-Identifier: GPL-3.0-or-later
pragma solidity ^0.8.33;

import {LibAppStorage, AppStorage, Reservation, PayoutCandidate} from "../libraries/LibAppStorage.sol";
import {LibHeap} from "../libraries/LibHeap.sol";

contract LibHeapHarness {
    function _s() internal pure returns (AppStorage storage) {
        return LibAppStorage.diamondStorage();
    }

    function enqueueViaLib(
        uint256 labId,
        bytes32 key,
        uint32 end
    ) external {
        AppStorage storage s = _s();
        LibHeap.enqueuePayoutCandidate(s, labId, key, end);
    }

    function popEligible(
        uint256 labId,
        uint256 currentTime
    ) external returns (bytes32) {
        AppStorage storage s = _s();
        return LibHeap.popEligiblePayoutCandidate(s, labId, currentTime);
    }

    function rawPush(
        uint256 labId,
        bytes32 key,
        uint32 end
    ) external {
        AppStorage storage s = _s();
        s.payoutHeaps[labId].push(PayoutCandidate({end: end, key: key}));
        s.payoutHeapContains[key] = true;
    }

    function setReservation(
        bytes32 key,
        uint256 labId,
        uint8 status
    ) external {
        AppStorage storage s = _s();
        s.reservations[key].labId = labId;
        s.reservations[key].status = status;
    }

    function heapLength(
        uint256 labId
    ) external view returns (uint256) {
        AppStorage storage s = _s();
        return s.payoutHeaps[labId].length;
    }

    function rootEnd(
        uint256 labId
    ) external view returns (uint32) {
        AppStorage storage s = _s();
        if (s.payoutHeaps[labId].length == 0) return 0;
        return s.payoutHeaps[labId][0].end;
    }

    function setReservationStatus(
        bytes32 key,
        uint8 status
    ) external {
        AppStorage storage s = _s();
        s.reservations[key].status = status;
    }

    // Test helpers for stress/fuzz/gas tests
    function setInvalidCount(
        uint256 labId,
        uint256 count
    ) external {
        AppStorage storage s = _s();
        s.payoutHeapInvalidCount[labId] = count;
    }

    function invalidCount(
        uint256 labId
    ) external view returns (uint256) {
        AppStorage storage s = _s();
        return s.payoutHeapInvalidCount[labId];
    }

    // Expose prune/maintenance for tests: remove up to maxIterations invalid entries
    function pruneViaLib(
        uint256 labId,
        uint256 maxIterations
    ) external returns (uint256) {
        AppStorage storage s = _s();
        return LibHeap.prunePayoutHeap(s, labId, maxIterations);
    }
}
