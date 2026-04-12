// SPDX-License-Identifier: GPL-3.0-or-later
pragma solidity ^0.8.31;

import {EnumerableSet} from "@openzeppelin/contracts/utils/structs/EnumerableSet.sol";
import {AppStorage, Reservation, LibAppStorage} from "../../libraries/LibAppStorage.sol";
import {LibERC721Storage} from "../../libraries/LibERC721Storage.sol";
import {RivalIntervalTreeLibrary, Tree} from "../../libraries/RivalIntervalTreeLibrary.sol";

/// @title ReservationStatsFacet
/// @notice Dedicated facet for reservation statistics selectors to keep core reservation facets below EIP-170 size limit.
contract ReservationStatsFacet {
    using EnumerableSet for EnumerableSet.AddressSet;
    using EnumerableSet for EnumerableSet.Bytes32Set;
    using RivalIntervalTreeLibrary for Tree;

    struct StatsResult {
        uint32 count;
        uint256 duration;
        uint32 minStart;
        uint32 maxEnd;
    }

    uint256 internal constant _MAX_STATS_PAGE_SIZE = 500;

    error TokenNotFound();

    modifier exists(
        uint256 tokenId
    ) {
        _checkExists(tokenId);
        _;
    }

    modifier onlyAdmin() {
        _onlyAdmin();
        _;
    }

    function _s() internal pure returns (AppStorage storage s) {
        s = LibAppStorage.diamondStorage();
    }

    function _checkExists(
        uint256 tokenId
    ) internal view {
        if (LibERC721Storage.ownerOfOptional(tokenId) == address(0)) revert TokenNotFound();
    }

    function _onlyAdmin() internal view {
        AppStorage storage s = _s();
        require(s.roleMembers[s.DEFAULT_ADMIN_ROLE].contains(msg.sender), "Only admin can call this function");
    }

    function getReservationStats(
        uint256 tokenId,
        uint32 startTime,
        uint32 endTime
    )
        external
        view
        exists(tokenId)
        onlyAdmin
        returns (uint32 count, uint32 firstStart, uint32 lastEnd, uint256 totalDuration)
    {
        require(startTime < endTime, "Invalid time range");

        Tree storage calendar = _s().calendars[tokenId];
        if (calendar.root == 0) {
            return (0, 0, 0, 0);
        }

        (StatsResult memory stats,, bool hasMore) =
            _getReservationStatsPage(calendar, startTime, endTime, startTime, _MAX_STATS_PAGE_SIZE);
        require(!hasMore, "Use getReservationStatsPaginated");

        count = stats.count;
        totalDuration = stats.duration;
        firstStart = stats.minStart;
        lastEnd = stats.maxEnd;

        if (count == 0) {
            return (0, 0, 0, 0);
        }
        return (count, firstStart, lastEnd, totalDuration);
    }

    function getReservationStatsPaginated(
        uint256 tokenId,
        uint32 startTime,
        uint32 endTime,
        uint32 cursorStartInput,
        uint256 limit
    )
        external
        view
        exists(tokenId)
        onlyAdmin
        returns (
            uint32 count,
            uint32 firstStart,
            uint32 lastEnd,
            uint256 totalDuration,
            uint32 nextCursorStart,
            bool hasMore
        )
    {
        require(startTime < endTime, "Invalid time range");
        require(limit > 0 && limit <= _MAX_STATS_PAGE_SIZE, "Invalid limit");

        uint32 cursorStart = cursorStartInput == 0 ? startTime : cursorStartInput;
        require(cursorStart >= startTime, "Invalid cursor");

        Tree storage calendar = _s().calendars[tokenId];
        if (calendar.root == 0 || cursorStart >= endTime) {
            return (0, 0, 0, 0, 0, false);
        }

        (StatsResult memory stats, uint32 nextCursor, bool pageHasMore) =
            _getReservationStatsPage(calendar, startTime, endTime, cursorStart, limit);
        count = stats.count;
        totalDuration = stats.duration;
        hasMore = pageHasMore;
        nextCursorStart = nextCursor;

        if (count == 0) {
            return (0, 0, 0, totalDuration, nextCursorStart, hasMore);
        }

        firstStart = stats.minStart;
        lastEnd = stats.maxEnd;
        return (count, firstStart, lastEnd, totalDuration, nextCursorStart, hasMore);
    }

    function _getReservationStatsPage(
        Tree storage calendar,
        uint32 startTime,
        uint32 endTime,
        uint32 cursorStart,
        uint256 limit
    ) private view returns (StatsResult memory stats, uint32 nextCursorStart, bool hasMore) {
        stats.minStart = type(uint32).max;
        if (cursorStart >= endTime || limit == 0 || calendar.root == 0) {
            return (stats, 0, false);
        }

        uint256 cursor = _findFirstNodeAtOrAfter(calendar, cursorStart);
        bool includeBoundarySpanningNode = cursorStart == startTime;
        uint256 processed;

        if (includeBoundarySpanningNode) {
            uint256 predecessor = _findPredecessorNode(calendar, cursor, cursorStart);
            if (predecessor != 0) {
                uint32 predecessorStart = uint32(predecessor);
                uint32 predecessorEnd = uint32(calendar.nodes[predecessor].end);
                if (predecessorStart < endTime && predecessorEnd > startTime) {
                    _appendStatsInterval(stats, predecessorStart, predecessorEnd, startTime, endTime);
                    processed = 1;
                    if (processed >= limit) {
                        hasMore = cursor != 0 && cursor < endTime;
                        if (hasMore) {
                            nextCursorStart = uint32(cursor);
                        }
                        return (stats, nextCursorStart, hasMore);
                    }
                }
            }
        }

        while (cursor != 0 && cursor < endTime && processed < limit) {
            uint32 currentStart = uint32(cursor);
            uint32 currentEnd = uint32(calendar.nodes[cursor].end);
            if (currentEnd > startTime) {
                _appendStatsInterval(stats, currentStart, currentEnd, startTime, endTime);
            }
            processed++;
            cursor = calendar.next(cursor);
        }

        hasMore = cursor != 0 && cursor < endTime;
        if (hasMore) {
            nextCursorStart = uint32(cursor);
        }
    }

    function _appendStatsInterval(
        StatsResult memory stats,
        uint32 intervalStart,
        uint32 intervalEnd,
        uint32 rangeStart,
        uint32 rangeEnd
    ) private pure {
        stats.count += 1;
        if (intervalStart < stats.minStart) {
            stats.minStart = intervalStart;
        }
        if (intervalEnd > stats.maxEnd) {
            stats.maxEnd = intervalEnd;
        }

        uint32 effectiveStart = intervalStart > rangeStart ? intervalStart : rangeStart;
        uint32 effectiveEnd = intervalEnd < rangeEnd ? intervalEnd : rangeEnd;
        if (effectiveEnd > effectiveStart) {
            stats.duration += effectiveEnd - effectiveStart;
        }
    }

    function _findFirstNodeAtOrAfter(
        Tree storage calendar,
        uint32 target
    ) private view returns (uint256 candidate) {
        uint256 cursor = calendar.root;
        while (cursor != 0) {
            if (cursor >= target) {
                candidate = cursor;
                cursor = calendar.nodes[cursor].left;
            } else {
                cursor = calendar.nodes[cursor].right;
            }
        }
    }

    function _findPredecessorNode(
        Tree storage calendar,
        uint256 firstAtOrAfter,
        uint32 target
    ) private view returns (uint256 predecessor) {
        if (firstAtOrAfter == 0) {
            predecessor = calendar.last();
        } else {
            predecessor = calendar.prev(firstAtOrAfter);
        }

        if (predecessor != 0 && predecessor >= target) {
            predecessor = 0;
        }
    }

    // -------------------------------------------------------------------------
    // Wallet-user reservation query functions
    // These functions are defined in the abstract ReservableTokenEnumerable but
    // were never cut into the Diamond selector table.  Adding them here (a
    // concrete, already-deployed facet) is the minimal upgrade path: one
    // diamondCut transaction to register the three selectors pointing at the
    // upgraded ReservationStatsFacet bytecode.
    // -------------------------------------------------------------------------

    /// @notice Returns the total number of reservations held by a wallet address.
    /// @dev Reads s.renters[_user] — the per-wallet EnumerableSet maintained by the
    ///      base reservation logic.  Zero address is rejected.
    /// @param _user The wallet address to query.
    function reservationsOf(address _user) external view returns (uint256) {
        require(_user != address(0), "Invalid address");
        return _s().renters[_user].length();
    }

    /// @notice Returns the reservation key at position _index in the caller's set.
    /// @dev Order is NOT stable across mutations (EnumerableSet).  Use for snapshot
    ///      iteration only, never for stateful cursor-based pagination.
    /// @param _user  The wallet address whose reservation set is queried.
    /// @param _index Zero-based index.
    function reservationKeyOfUserByIndex(address _user, uint256 _index) external view returns (bytes32) {
        AppStorage storage s = _s();
        require(_index < s.renters[_user].length(), "Index out of bounds");
        return s.renters[_user].at(_index);
    }

    /// @notice Returns the active reservation key for a (lab token, wallet) pair.
    /// @dev Fast path: O(1) via the dedicated activeReservationByTokenAndUser index.
    ///      Slow path: O(≤10) scan over reservationKeysByTokenAndUser when the index
    ///      is stale.  Returns bytes32(0) when no active reservation exists.
    ///      Both _CONFIRMED and _IN_USE are treated as active.
    /// @param _tokenId The lab NFT token ID.
    /// @param _user    The renter wallet address.
    function getActiveReservationKeyForUser(uint256 _tokenId, address _user) external view returns (bytes32) {
        require(_user != address(0), "Invalid address");
        _checkExists(_tokenId);

        AppStorage storage s = _s();
        bytes32 key = s.activeReservationByTokenAndUser[_tokenId][_user];
        if (key == bytes32(0)) return bytes32(0);

        Reservation memory res = s.reservations[key];
        uint32 t = uint32(block.timestamp);
        if ((res.status == 1 || res.status == 2) && res.start <= t && res.end >= t) {
            return key;
        }

        // Slow-path: index stale — scan per-(token,user) set (capped at 10)
        EnumerableSet.Bytes32Set storage set = s.reservationKeysByTokenAndUser[_tokenId][_user];
        uint256 len = set.length();
        uint256 cap = len < 10 ? len : 10;
        for (uint256 i; i < cap;) {
            bytes32 candidate = set.at(i);
            Reservation storage r = s.reservations[candidate];
            if ((r.status == 1 || r.status == 2) && r.start <= t && r.end >= t) {
                return candidate;
            }
            unchecked { ++i; }
        }
        return bytes32(0);
    }
}
