// SPDX-License-Identifier: GPL-3.0-or-later
pragma solidity ^0.8.31;

import {EnumerableSet} from "@openzeppelin/contracts/utils/structs/EnumerableSet.sol";
import {IERC721} from "@openzeppelin/contracts/token/ERC721/IERC721.sol";
import {RivalIntervalTreeLibrary, Tree} from "./RivalIntervalTreeLibrary.sol";
import {LibAppStorage, AppStorage, Reservation, UserActiveReservation, INSTITUTION_ROLE} from "./LibAppStorage.sol";
import {LibTracking} from "./LibTracking.sol";
import {LibRevenue} from "./LibRevenue.sol";
import {LibHeap} from "./LibHeap.sol";
import {LibReservationCancellation} from "./LibReservationCancellation.sol";

interface IStakingFacetConfirmLib {
    function updateLastReservation(
        address provider
    ) external;
}

interface IInstitutionalTreasuryFacetConfirmLib {
    function spendFromInstitutionalTreasury(
        address institution,
        string calldata puc,
        uint256 amount
    ) external;
}

interface IReservableTokenCalcI {
    function calculateRequiredStake(
        address provider,
        uint256 listedLabsCount
    ) external view returns (uint256);
}

library LibInstitutionalReservationConfirmation {
    using EnumerableSet for EnumerableSet.AddressSet;
    using RivalIntervalTreeLibrary for Tree;

    error InstitutionNotRegistered();
    error UnauthorizedInstitutionCall();
    error PucRequired();
    error PayerMismatch();
    error PucMissing();
    error PucMismatch();

    uint8 internal constant _PENDING = 0;
    uint8 internal constant _CONFIRMED = 1;
    uint8 internal constant _IN_USE = 2;

    event ReservationConfirmed(bytes32 indexed reservationKey, uint256 indexed tokenId);
    event ReservationRequestDenied(bytes32 indexed reservationKey, uint256 indexed tokenId);

    function confirmInstitutionalReservationRequestWithPuc(
        address institution,
        bytes32 key,
        string calldata puc
    ) external {
        AppStorage storage s = LibAppStorage.diamondStorage();
        if (!EnumerableSet.contains(s.roleMembers[INSTITUTION_ROLE], institution)) revert InstitutionNotRegistered();

        Reservation storage r = s.reservations[key];
        if (r.renter == address(0)) revert();
        if (r.status != _PENDING) revert();

        address labOwner = IERC721(address(this)).ownerOf(r.labId);
        address instBackend = s.institutionalBackends[institution];
        address providerBackend = s.institutionalBackends[labOwner];

        bool institutionCaller = msg.sender == institution || (instBackend != address(0) && msg.sender == instBackend);
        bool providerCaller = msg.sender == labOwner || (providerBackend != address(0) && msg.sender == providerBackend);
        if (!institutionCaller && !providerCaller) revert UnauthorizedInstitutionCall();

        _confirmInstitutionalReservationRequestWithPuc(s, institution, key, puc);
    }

    function _confirmInstitutionalReservationRequestWithPuc(
        AppStorage storage s,
        address institution,
        bytes32 key,
        string memory puc
    ) private {
        Reservation storage r = s.reservations[key];
        if (r.payerInstitution != institution) revert PayerMismatch();

        bytes32 storedHash = s.reservationPucHash[key];
        if (storedHash == bytes32(0)) revert PucMissing();
        if (bytes(puc).length == 0) revert PucRequired();
        if (storedHash != keccak256(bytes(puc))) revert PucMismatch();

        address trackingKey = LibTracking.trackingKeyFromInstitutionHash(institution, storedHash);
        address labProvider = IERC721(address(this)).ownerOf(r.labId);
        r.labProvider = labProvider;

        if (!_providerCanFulfill(s, labProvider, r.labId)) {
            LibReservationCancellation.cancelReservation(key);
            emit ReservationRequestDenied(key, r.labId);
            return;
        }

        r.collectorInstitution = s.institutionalBackends[labProvider] != address(0) ? labProvider : address(0);

        uint256 d = r.requestPeriodDuration;
        if (d == 0) d = s.institutionalSpendingPeriod[institution];
        if (d == 0) d = LibAppStorage.DEFAULT_SPENDING_PERIOD;
        if (block.timestamp >= r.requestPeriodStart + d) {
            LibReservationCancellation.cancelReservation(key);
            emit ReservationRequestDenied(key, r.labId);
            return;
        }

        if (r.price == 0) {
            _finalize(s, r, key, labProvider, trackingKey);
            return;
        }

        try IInstitutionalTreasuryFacetConfirmLib(address(this))
            .spendFromInstitutionalTreasury(r.payerInstitution, puc, r.price) {
            _finalize(s, r, key, labProvider, trackingKey);
        } catch {
            LibReservationCancellation.cancelReservation(key);
            emit ReservationRequestDenied(key, r.labId);
        }
    }

    function _finalize(
        AppStorage storage s,
        Reservation storage r,
        bytes32 key,
        address labProvider,
        address trackingKey
    ) private {
        _setReservationSplit(r);
        s.calendars[r.labId].insert(r.start, r.end);
        r.status = _CONFIRMED;
        _incrementActiveReservationCounters(s, r);
        s.activeReservationCountByTokenAndUser[r.labId][trackingKey]++;
        _enqueuePayoutCandidate(s, r.labId, key, r.end);
        _enqueueInstitutionalActiveReservation(s, r.labId, r, key);
        IStakingFacetConfirmLib(address(this)).updateLastReservation(labProvider);

        bytes32 currentKey = s.activeReservationByTokenAndUser[r.labId][trackingKey];
        if (currentKey == bytes32(0) || r.start < s.reservations[currentKey].start) {
            s.activeReservationByTokenAndUser[r.labId][trackingKey] = key;
        }

        emit ReservationConfirmed(key, r.labId);
    }

    function _providerCanFulfill(
        AppStorage storage s,
        address labProvider,
        uint256 labId
    ) private view returns (bool) {
        if (!s.tokenStatus[labId]) return false;
        uint256 listedLabsCount = s.providerStakes[labProvider].listedLabsCount;
        uint256 requiredStake =
            IReservableTokenCalcI(address(this)).calculateRequiredStake(labProvider, listedLabsCount);
        return s.providerStakes[labProvider].stakedAmount >= requiredStake;
    }

    function _setReservationSplit(
        Reservation storage reservation
    ) private {
        (uint96 prov, uint96 treas, uint96 subs, uint96 gov) = LibRevenue.calculateRevenueSplit(reservation.price);
        reservation.providerShare = prov;
        reservation.projectTreasuryShare = treas;
        reservation.subsidiesShare = subs;
        reservation.governanceShare = gov;
    }

    function _incrementActiveReservationCounters(
        AppStorage storage s,
        Reservation storage reservation
    ) private {
        s.labActiveReservationCount[reservation.labId]++;
        s.providerActiveReservationCount[reservation.labProvider]++;
    }

    function _enqueuePayoutCandidate(
        AppStorage storage s,
        uint256 labId,
        bytes32 key,
        uint32 end
    ) private {
        LibHeap.enqueuePayoutCandidate(s, labId, key, end);
    }

    function _enqueueInstitutionalActiveReservation(
        AppStorage storage s,
        uint256 labId,
        Reservation storage reservation,
        bytes32 reservationKey
    ) private {
        bytes32 storedHash = s.reservationPucHash[reservationKey];
        if (storedHash == bytes32(0)) return;
        address trackingKey = LibTracking.trackingKeyFromInstitutionHash(reservation.renter, storedHash);
        _enqueueActiveReservation(s, labId, trackingKey, reservationKey, reservation.start);
    }

    function _enqueueActiveReservation(
        AppStorage storage s,
        uint256 labId,
        address trackingKey,
        bytes32 reservationKey,
        uint32 start
    ) private {
        if (trackingKey == address(0) || s.activeReservationHeapContains[reservationKey]) return;
        UserActiveReservation[] storage heap = s.activeReservationHeaps[labId][trackingKey];
        heap.push(UserActiveReservation({start: start, key: reservationKey}));
        s.activeReservationHeapContains[reservationKey] = true;
        _activeHeapifyUp(heap, heap.length - 1);
    }

    function _activeHeapifyUp(
        UserActiveReservation[] storage heap,
        uint256 index
    ) private {
        while (index > 0) {
            uint256 parent = (index - 1) / 2;
            if (heap[index].start >= heap[parent].start) break;
            UserActiveReservation memory temp = heap[index];
            heap[index] = heap[parent];
            heap[parent] = temp;
            index = parent;
        }
    }
}
