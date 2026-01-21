// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.33;

import "forge-std/Test.sol";
import "./BaseTest.sol";
import "./Harnesses.sol";
import "../contracts/libraries/LibReservationCancellation.sol";
import "../contracts/libraries/LibAppStorage.sol";

contract BufferHeapHarness {
    // expose helpers to seed reservations and perform cancellations
    function createReservationAndCancel(
        bytes32 key,
        address renter,
        uint256 labId,
        uint32 start,
        uint32 end
    ) external {
        AppStorage storage s = LibAppStorage.diamondStorage();
        Reservation storage r = s.reservations[key];
        r.renter = renter;
        r.labId = labId;
        r.start = start;
        r.end = end;
        r.status = 1; // _CONFIRMED
        // ensure active reservation counters/sets are empty to avoid side-effects in unit tests
        // call cancellation which will record past reservation (exercise _insertPast)
        LibReservationCancellation.cancelReservation(key);
    }

    function seedActiveHeap(
        uint256 labId,
        address trackingKey,
        uint32[] calldata starts,
        bytes32[] calldata keys
    ) external {
        require(starts.length == keys.length, "len");
        AppStorage storage s = LibAppStorage.diamondStorage();

        // reset any existing heap
        delete s.activeReservationHeaps[labId][trackingKey];

        for (uint256 i = 0; i < starts.length; ++i) {
            s.activeReservationHeapContains[keys[i]] = true;
            s.activeReservationHeaps[labId][trackingKey].push(UserActiveReservation({start: starts[i], key: keys[i]}));
            // also set reservation entries so cancel path sees them as active
            Reservation storage r = s.reservations[keys[i]];
            r.renter = trackingKey;
            r.labId = labId;
            r.start = starts[i];
            r.end = starts[i] + 3600;
            r.status = 1; // _CONFIRMED
        }
    }

    // call cancel on the root key (heap[0].key)
    function cancelRootActiveReservation(
        uint256 labId,
        address trackingKey
    ) external returns (bytes32) {
        AppStorage storage s = LibAppStorage.diamondStorage();
        UserActiveReservation[] storage heap = s.activeReservationHeaps[labId][trackingKey];
        require(heap.length > 0, "empty");
        bytes32 rootKey = heap[0].key;
        LibReservationCancellation.cancelReservation(rootKey);
        return rootKey;
    }

    // verify heap invariant: for all i, parent.start <= child.start
    function checkHeapInvariant(
        uint256 labId,
        address trackingKey
    ) external view returns (bool) {
        AppStorage storage s = LibAppStorage.diamondStorage();
        UserActiveReservation[] storage heap = s.activeReservationHeaps[labId][trackingKey];
        uint256 n = heap.length;
        for (uint256 i = 0; i < n; ++i) {
            uint256 left = i * 2 + 1;
            uint256 right = left + 1;
            if (left < n) {
                if (!(heap[i].start <= heap[left].start)) return false;
            }
            if (right < n) {
                if (!(heap[i].start <= heap[right].start)) return false;
            }
        }
        return true;
    }

    // helpers to read past buffer
    function getPastEndsByToken(
        uint256 labId
    ) external view returns (uint8 size, uint32[50] memory ends) {
        AppStorage storage s = LibAppStorage.diamondStorage();
        PastReservationBuffer storage buf = s.pastReservationsByToken[labId];
        return (buf.size, buf.ends);
    }

    function getPastEndsByTokenAndUser(
        uint256 labId,
        address user
    ) external view returns (uint8 size, uint32[50] memory ends) {
        AppStorage storage s = LibAppStorage.diamondStorage();
        PastReservationBuffer storage buf = s.pastReservationsByTokenAndUser[labId][user];
        return (buf.size, buf.ends);
    }
}

contract FuzzBuffersAndHeapTest is BaseTest {
    BufferHeapHarness public harness;

    function setUp() public override {
        super.setUp();
        harness = new BufferHeapHarness();
    }

    // fuzz past buffer invariant by creating and cancelling many reservations with various end times
    function test_fuzz_past_buffer_invariant(
        bytes32 seed
    ) public {
        vm.assume(seed != bytes32(0));
        address user = makeAddr("fuzzuser");
        uint256 labId = uint256(uint160(address(this))) & 0xFFFF;
        uint8 count = uint8(uint8(seed[0]) % 40) + 1; // up to 40 cancellations

        for (uint8 i = 0; i < count; ++i) {
            uint32 end = uint32(uint256(keccak256(abi.encodePacked(seed, i))) % 1_000_000);
            uint32 start = end > 3600 ? end - 3600 : 0;
            bytes32 key = keccak256(abi.encodePacked(labId, start, i));
            harness.createReservationAndCancel(key, user, labId, start, end);
        }

        (uint8 sizeT, uint32[50] memory endsT) = harness.getPastEndsByToken(labId);
        (uint8 sizeU, uint32[50] memory endsU) = harness.getPastEndsByTokenAndUser(labId, user);

        // invariants: size <= 50 and ends in non-increasing order (biggest first)
        assert(sizeT <= 50);
        for (uint256 j = 0; j + 1 < sizeT; ++j) {
            assert(endsT[j] >= endsT[j + 1]);
        }

        assert(sizeU <= 50);
        for (uint256 j = 0; j + 1 < sizeU; ++j) {
            assert(endsU[j] >= endsU[j + 1]);
        }
    }

    // fuzz heap invariant: seed a valid heap and cancel root, ensure heap property holds after removal
    function test_fuzz_active_heap_invariant(
        bytes32 seed
    ) public {
        vm.assume(seed != bytes32(0));
        uint8 count = uint8(uint8(seed[0]) % 10) + 1; // 1..10
        uint256 labId = 7777;
        address tracking = makeAddr("track");

        uint32[] memory starts = new uint32[](count);
        bytes32[] memory keys = new bytes32[](count);
        for (uint8 i = 0; i < count; ++i) {
            starts[i] = uint32(i + 1000); // ascending ensures min-heap property
            keys[i] = keccak256(abi.encodePacked(seed, i, starts[i]));
        }

        harness.seedActiveHeap(labId, tracking, starts, keys);

        // cancel the root and verify heap invariant holds
        vm.prank(address(this));
        harness.cancelRootActiveReservation(labId, tracking);

        bool ok = harness.checkHeapInvariant(labId, tracking);
        assert(ok);
    }
}
