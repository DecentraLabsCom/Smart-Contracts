// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.33;

import "forge-std/Test.sol";
import "../contracts/abstracts/ReservableToken.sol";
import "../contracts/libraries/LibAppStorage.sol";
import "../contracts/libraries/RivalIntervalTreeLibrary.sol";
import "./LibERC721StorageTestHelper.sol";

contract ReservableTokenAvailabilityHarness is ReservableToken {
    using RivalIntervalTreeLibrary for Tree;

    function setTokenOwner(
        uint256 tokenId,
        address owner
    ) external {
        LibERC721StorageTestHelper.setOwnerForTest(tokenId, owner);
    }

    function addBookedSlot(
        uint256 tokenId,
        uint32 start,
        uint32 end
    ) external {
        LibAppStorage.diamondStorage().calendars[tokenId].insert(start, end);
    }
}

contract ReservableTokenAvailabilityTest is Test {
    ReservableTokenAvailabilityHarness internal harness;

    function setUp() public {
        harness = new ReservableTokenAvailabilityHarness();
        harness.setTokenOwner(1, address(this));
    }

    function test_getBookedSlotsPaginated_reports_more_results_explicitly() public {
        harness.addBookedSlot(1, 1000, 1100);
        harness.addBookedSlot(1, 2000, 2100);
        harness.addBookedSlot(1, 3000, 3100);

        (uint32[] memory starts, uint32[] memory ends, bool hasMore) = harness.getBookedSlotsPaginated(1, 1, 1);

        assertEq(starts.length, 1);
        assertEq(starts[0], 2000);
        assertEq(ends[0], 2100);
        assertTrue(hasMore);
    }

    function test_getBookedSlots_reverts_instead_of_returning_incomplete_calendar() public {
        for (uint32 i = 0; i < 101; i++) {
            uint32 start = 1000 + i * 10;
            harness.addBookedSlot(1, start, start + 5);
        }

        vm.expectRevert(ReservableToken.AvailabilityResultTruncated.selector);
        harness.getBookedSlots(1);
    }

    function test_findAvailableSlots_reverts_instead_of_false_final_gap() public {
        for (uint32 i = 0; i < 101; i++) {
            uint32 start = 1000 + i * 10;
            harness.addBookedSlot(1, start, start + 5);
        }

        vm.expectRevert(ReservableToken.AvailabilityResultTruncated.selector);
        harness.findAvailableSlots(1, 1000, 3000, 1);
    }

    function test_getNextAvailableSlot_detects_query_inside_existing_booking() public {
        harness.addBookedSlot(1, 1000, 2000);

        (uint32 nextStart, uint32 blockedUntil) = harness.getNextAvailableSlot(1, 1500);

        assertEq(nextStart, 1500);
        assertEq(blockedUntil, 2000);
    }
}
