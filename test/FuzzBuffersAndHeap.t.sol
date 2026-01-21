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

    // cancel an arbitrary active reservation by key
    function cancelActiveReservationByKey(bytes32 key) external {
        LibReservationCancellation.cancelReservation(key);
    }

    // get info about heap root and length
    function getActiveHeapRootInfo(uint256 labId, address trackingKey)
        external
        view
        returns (bool hasRoot, uint32 start, bytes32 key, uint256 len)
    {
        AppStorage storage s = LibAppStorage.diamondStorage();
        UserActiveReservation[] storage heap = s.activeReservationHeaps[labId][trackingKey];
        uint256 n = heap.length;
        if (n == 0) return (false, 0, bytes32(0), 0);
        return (true, heap[0].start, heap[0].key, n);
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

    // longer heap sequences stress test: construct up to 128 items and perform multiple removals
    function test_fuzz_active_heap_long_sequences(bytes32 seed) public {
        vm.assume(seed != bytes32(0));
        uint16 count = uint16(uint16(uint8(seed[0])) % 128) + 1; // 1..128
        uint256 labId = 9999;
        address tracking = makeAddr("track_long");

        uint32[] memory raw = new uint32[](count);
        bytes32[] memory rawKeys = new bytes32[](count);
        for (uint256 i = 0; i < count; ++i) {
            raw[i] = uint32(uint256(keccak256(abi.encodePacked(seed, i))) % 1000000);
            rawKeys[i] = keccak256(abi.encodePacked(seed, "k", i, raw[i]));
        }

        // build heap by percolating-up in memory (same algorithm as tested earlier)
        uint32[] memory startsHeap = new uint32[](count);
        bytes32[] memory keysHeap = new bytes32[](count);
        uint256 heapLen = 0;
        for (uint256 i = 0; i < count; ++i) {
            startsHeap[heapLen] = raw[i];
            keysHeap[heapLen] = rawKeys[i];
            uint256 j = heapLen;
            while (j > 0) {
                uint256 parent = (j - 1) / 2;
                if (startsHeap[parent] > startsHeap[j]) {
                    (startsHeap[parent], startsHeap[j]) = (startsHeap[j], startsHeap[parent]);
                    (keysHeap[parent], keysHeap[j]) = (keysHeap[j], keysHeap[parent]);
                    j = parent;
                } else break;
            }
            heapLen++;
        }

        harness.seedActiveHeap(labId, tracking, startsHeap, keysHeap);

        // perform several random removals and check invariant
        uint16 removals = uint16(uint16(uint8(seed[1])) % uint16(count)) + 1;
        for (uint16 r = 0; r < removals; ++r) {
            vm.prank(address(this));
            try harness.cancelRootActiveReservation(labId, tracking) returns (bytes32) {
                // ok
            } catch {
                // ignore
            }
            assert(harness.checkHeapInvariant(labId, tracking));
        }
    }

    // past buffer saturation test: create many cancellations to overflow cap and verify cap respected and ordering
    function test_fuzz_past_buffer_saturation(bytes32 seed) public {
        vm.assume(seed != bytes32(0));
        address user = makeAddr("saturate");
        uint256 labId = uint256(uint160(address(this))) & 0xFFFF;
        uint16 count = uint16(uint16(uint8(seed[2])) % 120) + 1; // 1..120 cancellations

        for (uint16 i = 0; i < count; ++i) {
            uint32 end = uint32(uint256(keccak256(abi.encodePacked(seed, i))) % 1_000_000);
            uint32 start = end > 3600 ? end - 3600 : 0;
            bytes32 key = keccak256(abi.encodePacked(labId, start, i));
            harness.createReservationAndCancel(key, user, labId, start, end);
        }

        (uint8 sizeT, uint32[50] memory endsT) = harness.getPastEndsByToken(labId);
        assert(sizeT <= 50);
        for (uint256 j = 0; j + 1 < sizeT; ++j) assert(endsT[j] >= endsT[j + 1]);
    }

    // repeatedly remove root until heap empty; ensure heap invariant holds after each removal
    function test_fuzz_heap_multiple_removals(bytes32 seed) public {
        vm.assume(seed != bytes32(0));
        uint8 count = uint8(uint8(seed[0]) % 20) + 1; // 1..20
        uint256 labId = uint256(uint160(address(this))) & 0xFFFF;
        address tracking = makeAddr("track2");

        // generate raw values then build a valid heap representation in memory via insertion/percolate-up
        uint32[] memory raw = new uint32[](count);
        bytes32[] memory rawKeys = new bytes32[](count);
        for (uint8 i = 0; i < count; ++i) {
            raw[i] = uint32(uint256(keccak256(abi.encodePacked(seed, "s", i))) % 100000);
            rawKeys[i] = keccak256(abi.encodePacked(seed, "k", i, raw[i]));
        }

        // build heap arrays
        uint32[] memory startsHeap = new uint32[](count);
        bytes32[] memory keysHeap = new bytes32[](count);
        uint256 heapLen = 0;
        for (uint8 i = 0; i < count; ++i) {
            startsHeap[heapLen] = raw[i];
            keysHeap[heapLen] = rawKeys[i];
            uint256 j = heapLen;
            while (j > 0) {
                uint256 parent = (j - 1) / 2;
                if (startsHeap[parent] > startsHeap[j]) {
                    // swap start
                    uint32 tmpStart = startsHeap[parent];
                    startsHeap[parent] = startsHeap[j];
                    startsHeap[j] = tmpStart;
                    // swap key
                    bytes32 tmpKey = keysHeap[parent];
                    keysHeap[parent] = keysHeap[j];
                    keysHeap[j] = tmpKey;
                    j = parent;
                } else break;
            }
            heapLen++;
        }

        harness.seedActiveHeap(labId, tracking, startsHeap, keysHeap);

        for (uint8 i = 0; i < count; ++i) {
            vm.prank(address(this));
            harness.cancelRootActiveReservation(labId, tracking);
            bool ok2 = harness.checkHeapInvariant(labId, tracking);
            assert(ok2);
        }
    }

    // fuzz past buffer with deliberate duplicates to check ordering and collision behavior
    function test_fuzz_past_buffer_duplicates(bytes32 seed) public {
        vm.assume(seed != bytes32(0));
        address user = makeAddr("dup");
        uint256 labId = uint256(uint160(address(this))) & 0xFFFF;
        uint8 count = uint8(uint8(seed[0]) % 40) + 1; // up to 40 cancellations

        for (uint8 i = 0; i < count; ++i) {
            // repeat the base end every 3 iterations to create duplicates
            uint32 base = uint32(uint256(keccak256(abi.encodePacked(seed, i / 3))) % 1_000_000);
            uint32 end = base;
            uint32 start = end > 3600 ? end - 3600 : 0;
            bytes32 key = keccak256(abi.encodePacked(labId, start, i));
            harness.createReservationAndCancel(key, user, labId, start, end);
        }

        (uint8 sizeT, uint32[50] memory endsT) = harness.getPastEndsByToken(labId);
        assert(sizeT <= 50);
        for (uint256 j = 0; j + 1 < sizeT; ++j) assert(endsT[j] >= endsT[j + 1]);
    }

    // test heapify-up and heapify-down behavior by creating a small heap where the last element is the smallest
    function test_heapify_up_and_down_deterministic() public {
        uint256 labId = 4444;
        address tracking = makeAddr("track3");

        uint32[] memory starts = new uint32[](7);
        bytes32[] memory keys = new bytes32[](7);

        // build a valid heap array by hand: [1,10,5,20,21,8,9]
        starts[0] = 1;
        starts[1] = 10;
        starts[2] = 5;
        starts[3] = 20;
        starts[4] = 21;
        starts[5] = 8;
        starts[6] = 9;

        for (uint8 i = 0; i < 7; ++i) keys[i] = keccak256(abi.encodePacked("det", i, starts[i]));

        harness.seedActiveHeap(labId, tracking, starts, keys);

        // cancel node at index 3 (value 20) so last entry (9) is swapped into that position
        vm.prank(address(this));
        harness.cancelActiveReservationByKey(keys[3]);

        (bool has, uint32 rootStart, bytes32 rootKey, uint256 len) = harness.getActiveHeapRootInfo(labId, tracking);
        assert(has);
        // root should remain the minimal value (1) and heap invariant should hold
        assert(rootStart == 1);
        assert(harness.checkHeapInvariant(labId, tracking));
    }
}
