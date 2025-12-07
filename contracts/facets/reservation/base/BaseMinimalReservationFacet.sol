// SPDX-License-Identifier: GPL-3.0-or-later
pragma solidity ^0.8.31;

import {EnumerableSet} from "@openzeppelin/contracts/utils/structs/EnumerableSet.sol";
import {ReservableToken} from "../../../abstracts/ReservableToken.sol";
import {AppStorage, RecentReservationBuffer} from "../../../libraries/LibAppStorage.sol";

/// @title BaseMinimalReservationFacet - Ultra-minimal base for the most size-constrained facets
/// @notice Inherits directly from ReservableToken (not ReservableTokenEnumerable)
abstract contract BaseMinimalReservationFacet is ReservableToken {
    using EnumerableSet for EnumerableSet.Bytes32Set;
    using EnumerableSet for EnumerableSet.AddressSet;

    uint8 internal constant _TOKEN_BUFFER_CAP = 10;
    uint8 internal constant _USER_BUFFER_CAP = 5;

    function _recordRecent(
        AppStorage storage s,
        uint256 labId,
        address userTrackingKey,
        bytes32 reservationKey,
        uint32 startTime
    ) internal {
        _insertRecentSimple(s, labId, reservationKey, startTime);
        _insertRecentUserSimple(s, labId, userTrackingKey, reservationKey, startTime);
    }

    function _insertRecentSimple(AppStorage storage s, uint256 labId, bytes32 key, uint32 startTime) private {
        RecentReservationBuffer storage buf = s.recentReservationsByToken[labId];
        uint8 size = buf.size;
        if (size >= _TOKEN_BUFFER_CAP) {
            for (uint8 j = 0; j < _TOKEN_BUFFER_CAP - 1; j++) {
                buf.keys[j] = buf.keys[j + 1];
                buf.starts[j] = buf.starts[j + 1];
            }
            size = _TOKEN_BUFFER_CAP - 1;
        }
        buf.keys[size] = key;
        buf.starts[size] = startTime;
        buf.size = size + 1;
    }

    function _insertRecentUserSimple(AppStorage storage s, uint256 labId, address user, bytes32 key, uint32 startTime) private {
        RecentReservationBuffer storage buf = s.recentReservationsByTokenAndUser[labId][user];
        uint8 size = buf.size;
        if (size >= _USER_BUFFER_CAP) {
            for (uint8 j = 0; j < _USER_BUFFER_CAP - 1; j++) {
                buf.keys[j] = buf.keys[j + 1];
                buf.starts[j] = buf.starts[j + 1];
            }
            size = _USER_BUFFER_CAP - 1;
        }
        buf.keys[size] = key;
        buf.starts[size] = startTime;
        buf.size = size + 1;
    }
}
