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

    function removePayoutCandidates(
        uint256 labId,
        bytes32 key
    ) external {
        LibHeap.removePayoutCandidates(_s(), labId, key);
    }

    function rawPush(
        uint256 labId,
        bytes32 key,
        uint32 end
    ) external {
        AppStorage storage s = _s();
        s.payoutHeaps[labId].push(PayoutCandidate({end: end, key: key}));
        s.payoutHeapContains[key] = true;
        s.payoutHeapIndexPlusOne[key] = s.payoutHeaps[labId].length;
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

    function setReservationEnd(
        bytes32 key,
        uint32 end
    ) external {
        LibAppStorage.diamondStorage().reservations[key].end = end;
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

    function setSessionStarted(
        bytes32 key
    ) external {
        _s().reservationSessionStartedRecorded[key] = true;
    }

    function payoutHeapIndexPlusOne(
        bytes32 key
    ) external view returns (uint256) {
        return _s().payoutHeapIndexPlusOne[key];
    }

    function payoutHeapContains(
        bytes32 key
    ) external view returns (bool) {
        return _s().payoutHeapContains[key];
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
}
