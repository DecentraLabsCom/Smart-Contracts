// SPDX-License-Identifier: GPL-3.0-or-later
pragma solidity ^0.8.31;

import {EnumerableSet} from "@openzeppelin/contracts/utils/structs/EnumerableSet.sol";
import {AppStorage, LibAppStorage, RecentReservationBuffer, Reservation} from "../../../libraries/LibAppStorage.sol";
import {LibReservationConfig} from "../../../libraries/LibReservationConfig.sol";
import {LibReservationIdentity} from "../../../libraries/LibReservationIdentity.sol";

interface IInstitutionalTreasuryFacetLight {
    function checkInstitutionalTreasuryAvailability(
        address provider,
        bytes32 pucHash,
        uint256 amount
    ) external view;
}

contract InstitutionalReservationRequestCreationFacet {
    using EnumerableSet for EnumerableSet.Bytes32Set;

    uint8 private constant _PENDING = 0;
    uint8 private constant _SETTLED = 3;
    uint8 private constant _CANCELLED = 4;
    uint8 private constant _TOKEN_BUFFER_CAP = 10;
    uint8 private constant _USER_BUFFER_CAP = 5;

    error ReservationPriceOverflow();
    error OnlyDiamondSelfCall();

    event ReservationRequested(
        address indexed renter, uint256 indexed tokenId, uint256 start, uint256 end, bytes32 indexed reservationKey
    );
    event ReservationGenerationCreated(
        bytes32 indexed reservationId, bytes32 indexed reservationKey, uint256 indexed tokenId
    );

    modifier onlyDiamondSelfCall() {
        if (msg.sender != address(this)) revert OnlyDiamondSelfCall();
        _;
    }

    struct InstInput {
        address p;
        address o;
        uint256 l;
        uint32 s;
        uint32 e;
        bytes32 u;
        bytes32 k;
        address t;
    }

    function createInstReservation(
        InstInput calldata i
    ) external onlyDiamondSelfCall {
        AppStorage storage s = _s();
        Reservation storage existing = s.reservations[i.k];
        if (existing.renter != address(0) && existing.status != _SETTLED && existing.status != _CANCELLED) {
            revert("Reservation already active");
        }
        address hc = s.institutionalBackends[i.o];
        uint96 pr;
        if (hc != address(0) && i.p == i.o) {
            pr = 0;
        } else {
            uint96 pricePerSecond = s.labs[i.l].price;
            uint256 durationSeconds = uint256(i.e - i.s);
            uint256 totalPrice = uint256(pricePerSecond) * durationSeconds;
            if (totalPrice > type(uint96).max) revert ReservationPriceOverflow();
            pr = uint96(totalPrice);
        }

        if (pr > 0) {
            IInstitutionalTreasuryFacetLight(address(this)).checkInstitutionalTreasuryAvailability(i.p, i.u, pr);
        }

        // Preserve the terminal record of a pre-generation reservation before
        // the reusable slot key is pointed at the new generation.
        if (existing.renter != address(0)) {
            LibReservationIdentity.snapshotCurrentReservation(s, i.k);
        }

        // forge-lint: disable-next-line(unsafe-typecast)
        uint64 rs = uint64(block.timestamp);
        // forge-lint: disable-next-line(unsafe-typecast)
        uint64 period = uint64(LibReservationConfig.PENDING_REQUEST_TTL);

        require(s.reservationKeysByToken[i.l].add(i.k), "Reservation index mismatch");
        bytes32 reservationId = LibReservationIdentity.createReservationId(s, i.k);
        Reservation storage r = s.reservations[i.k];
        r.labId = i.l;
        r.renter = i.p;
        r.labProvider = i.o;
        r.price = pr;
        r.start = i.s;
        r.end = i.e;
        r.status = _PENDING;
        r.requestPeriodStart = rs;
        r.requestPeriodDuration = period;
        r.payerInstitution = i.p;
        r.collectorInstitution = hc != address(0) ? i.o : address(0);
        r.providerShare = 0;
        s.reservationPucHash[reservationId] = i.u;
        LibReservationIdentity.snapshotCurrentReservation(s, i.k);

        s.totalReservationsCount++;
        _addReservationIndex(s.renters[i.p], i.k);
        _addReservationIndex(s.renters[i.t], i.k);
        _addReservationIndex(s.reservationKeysByTokenAndUser[i.l][i.t], i.k);

        s.labPendingReservationCount[i.l]++;

        emit ReservationRequested(i.p, i.l, i.s, i.e, i.k);
        emit ReservationGenerationCreated(reservationId, i.k, i.l);
    }

    function recordRecentInstReservation(
        uint256 l,
        address t,
        bytes32 k,
        uint32 st
    ) external onlyDiamondSelfCall {
        AppStorage storage s = _s();
        _recordRecent(s, l, t, k, st);
    }

    /// @dev Secondary reservation indexes are intentionally idempotent because
    /// the renter and tracking addresses may be identical.
    function _addReservationIndex(
        EnumerableSet.Bytes32Set storage set,
        bytes32 key
    ) private {
        if (!set.add(key)) return;
    }

    function _recordRecent(
        AppStorage storage s,
        uint256 labId,
        address userTrackingKey,
        bytes32 reservationKey,
        uint32 startTime
    ) private {
        bytes32 reservationId = LibReservationIdentity.currentReservationId(s, reservationKey);
        _insertRecent(s.recentReservationsByToken[labId], reservationId, startTime, _TOKEN_BUFFER_CAP);
        _insertRecent(
            s.recentReservationsByTokenAndUser[labId][userTrackingKey], reservationId, startTime, _USER_BUFFER_CAP
        );
    }

    function _insertRecent(
        RecentReservationBuffer storage buffer,
        bytes32 key,
        uint32 startTime,
        uint8 capacity
    ) private {
        uint8 size = buffer.size;
        if (size >= capacity) {
            for (uint8 index; index < capacity - 1; index++) {
                buffer.keys[index] = buffer.keys[index + 1];
                buffer.starts[index] = buffer.starts[index + 1];
            }
            size = capacity - 1;
        }
        buffer.keys[size] = key;
        buffer.starts[size] = startTime;
        buffer.size = size + 1;
    }

    function _s() private pure returns (AppStorage storage s) {
        return LibAppStorage.diamondStorage();
    }
}
