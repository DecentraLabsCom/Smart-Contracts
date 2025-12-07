// SPDX-License-Identifier: GPL-3.0-or-later
pragma solidity ^0.8.31;

import {ReservableTokenEnumerable} from "./ReservableTokenEnumerable.sol";
import {EnumerableSet} from "@openzeppelin/contracts/utils/structs/EnumerableSet.sol";
import {AppStorage, Reservation, UserActiveReservation} from "../libraries/LibAppStorage.sol";

/// @title InstitutionalReservableTokenEnumerable
/// @author
/// - Luis de la Torre Cubillo
/// - Juan Luis Ramos Villalón
/// @dev Abstract contract by design (prevents direct deployment in Diamond pattern)
/// @notice Extends ReservableTokenEnumerable with institutional user support (SAML2 schacPersonalUniqueCode)
///
/// @dev This contract is marked abstract to enforce inheritance-only usage, even though it has
///      no pending abstract functions. It extends wallet reservation logic with institutional features.
///      Should only be inherited by facets like InstitutionalReservationFacet.
abstract contract InstitutionalReservableTokenEnumerable is ReservableTokenEnumerable {
    using EnumerableSet for EnumerableSet.Bytes32Set;

    function _isInstitutionalReservation(Reservation storage reservation) internal view returns (bool) {
        return bytes(reservation.puc).length > 0;
    }

    function _computeTrackingKey(Reservation storage reservation) internal view returns (address) {
        if (_isInstitutionalReservation(reservation)) {
            return _trackingKeyFromInstitution(reservation.renter, reservation.puc);
        }
        return reservation.renter;
    }

    function _trackingKeyFromInstitution(address provider, string memory puc) internal pure returns (address) {
        return address(uint160(uint256(keccak256(abi.encodePacked(provider, puc)))));
    }

    function _enqueueInstitutionalActiveReservation(
        AppStorage storage s,
        uint256 labId,
        Reservation storage reservation,
        bytes32 reservationKey
    ) internal {
        if (!_isInstitutionalReservation(reservation)) {
            return;
        }
        address trackingKey = _computeTrackingKey(reservation);
        _enqueueActiveReservation(s, labId, trackingKey, reservationKey, reservation.start);
    }

    function _invalidateInstitutionalActiveReservation(
        AppStorage storage s,
        uint256 labId,
        Reservation storage reservation,
        bytes32 reservationKey
    ) internal {
        if (!_isInstitutionalReservation(reservation)) {
            return;
        }
        address trackingKey = _computeTrackingKey(reservation);
        _invalidateActiveReservationEntry(s, labId, trackingKey, reservationKey);
        if (s.activeReservationHeapContains[reservationKey]) {
            s.activeReservationHeapContains[reservationKey] = false;
        }
    }


    function _cancelReservation(bytes32 _reservationKey) internal virtual override {
        AppStorage storage s = _s();
        Reservation storage reservation = s.reservations[_reservationKey];

        if (!_isInstitutionalReservation(reservation)) {
            super._cancelReservation(_reservationKey);
            return;
        }

        address trackingKey = _computeTrackingKey(reservation);
        uint256 labId = reservation.labId;

        super._cancelReservation(_reservationKey);

        if (s.activeReservationCountByTokenAndUser[labId][trackingKey] > 0) {
            s.activeReservationCountByTokenAndUser[labId][trackingKey]--;
        }
        s.reservationKeysByTokenAndUser[labId][trackingKey].remove(_reservationKey);

        if (s.activeReservationByTokenAndUser[labId][trackingKey] == _reservationKey) {
            bytes32 nextKey = _findNextEarliestReservation(labId, trackingKey);
            s.activeReservationByTokenAndUser[labId][trackingKey] = nextKey;
        }

        s.renters[trackingKey].remove(_reservationKey);
        _invalidateInstitutionalActiveReservation(s, labId, reservation, _reservationKey);
    }

    /// @dev Override to track past reservations using institutional tracking key
    function _recordPastOnCancel(
        AppStorage storage s,
        Reservation storage reservation,
        bytes32 reservationKey
    ) internal virtual override {
        if (_isInstitutionalReservation(reservation)) {
            _recordPast(s, reservation.labId, _computeTrackingKey(reservation), reservationKey, uint32(block.timestamp));
            return;
        }
        super._recordPastOnCancel(s, reservation, reservationKey);
    }
    function _peekActiveReservation(
        AppStorage storage s,
        uint256 labId,
        address trackingKey
    ) internal returns (bytes32) {
        UserActiveReservation[] storage heap = s.activeReservationHeaps[labId][trackingKey];
        while (heap.length > 0) {
            UserActiveReservation storage root = heap[0];
            bytes32 key = root.key;

            if (!s.activeReservationHeapContains[key]) {
                _removeActiveReservationRoot(heap);
                continue;
            }

            Reservation storage reservation = s.reservations[key];
            if (
                reservation.labId != labId ||
                !_isInstitutionalReservation(reservation) ||
                _computeTrackingKey(reservation) != trackingKey
            ) {
                s.activeReservationHeapContains[key] = false;
                _removeActiveReservationRoot(heap);
                continue;
            }

            if (reservation.status == _CANCELLED || reservation.status == _COLLECTED || reservation.status == _COMPLETED) {
                s.activeReservationHeapContains[key] = false;
                _removeActiveReservationRoot(heap);
                continue;
            }

            if (reservation.end < block.timestamp) {
                s.activeReservationHeapContains[key] = false;
                _removeActiveReservationRoot(heap);
                continue;
            }

            return key;
        }
        return bytes32(0);
    }

    function _enqueueActiveReservation(
        AppStorage storage s,
        uint256 labId,
        address trackingKey,
        bytes32 reservationKey,
        uint32 start
    ) internal {
        if (trackingKey == address(0) || s.activeReservationHeapContains[reservationKey]) {
            return;
        }
        UserActiveReservation[] storage heap = s.activeReservationHeaps[labId][trackingKey];
        heap.push(UserActiveReservation({start: start, key: reservationKey}));
        s.activeReservationHeapContains[reservationKey] = true;
        _activeHeapifyUp(heap, heap.length - 1);
    }

    function _invalidateActiveReservationEntry(
        AppStorage storage s,
        uint256 labId,
        address trackingKey,
        bytes32 reservationKey
    ) internal {
        if (trackingKey == address(0)) {
            return;
        }
        if (!s.activeReservationHeapContains[reservationKey]) {
            return;
        }
        s.activeReservationHeapContains[reservationKey] = false;
        UserActiveReservation[] storage heap = s.activeReservationHeaps[labId][trackingKey];
        if (heap.length > 0 && heap[0].key == reservationKey) {
            _removeActiveReservationRoot(heap);
        }
    }

    function _removeActiveReservationRoot(
        UserActiveReservation[] storage heap
    ) internal {
        uint256 lastIndex = heap.length - 1;
        if (lastIndex == 0) {
            heap.pop();
            return;
        }
        heap[0] = heap[lastIndex];
        heap.pop();
        _activeHeapifyDown(heap, 0);
    }

    function _activeHeapifyUp(
        UserActiveReservation[] storage heap,
        uint256 index
    ) internal {
        while (index > 0) {
            uint256 parent = (index - 1) / 2;
            if (heap[index].start >= heap[parent].start) {
                break;
            }
            UserActiveReservation memory temp = heap[index];
            heap[index] = heap[parent];
            heap[parent] = temp;
            index = parent;
        }
    }

    function _activeHeapifyDown(
        UserActiveReservation[] storage heap,
        uint256 index
    ) internal {
        uint256 length = heap.length;
        while (true) {
            uint256 left = index * 2 + 1;
            if (left >= length) {
                break;
            }
            uint256 right = left + 1;
            uint256 smallest = left;
            if (right < length && heap[right].start < heap[left].start) {
                smallest = right;
            }
            if (heap[index].start <= heap[smallest].start) {
                break;
            }
            UserActiveReservation memory temp = heap[index];
            heap[index] = heap[smallest];
            heap[smallest] = temp;
            index = smallest;
        }
    }
}
