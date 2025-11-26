// SPDX-License-Identifier: GPL-3.0-or-later
pragma solidity ^0.8.23;

import {EnumerableSet} from "@openzeppelin/contracts/utils/structs/EnumerableSet.sol";
import "../abstracts/InstitutionalReservableTokenEnumerable.sol";
import "./ProviderFacet.sol";
import "../libraries/LibAppStorage.sol";

/// @dev Interface for StakingFacet to update reservation timestamps
interface IStakingFacet {
    function updateLastReservation(address provider) external;
}

/// @dev Interface for InstitutionalTreasuryFacet to spend from treasury
interface IInstitutionalTreasuryFacet {
    function checkInstitutionalTreasuryAvailability(address provider, string calldata puc, uint256 amount) external view;
    function spendFromInstitutionalTreasury(address provider, string calldata puc, uint256 amount) external;
    function refundToInstitutionalTreasury(address provider, string calldata puc, uint256 amount) external;
}

/// @title BaseReservationFacet - Shared internal logic for wallet and institutional reservation facets
/// @author
/// - Juan Luis Ramos Villalón
/// - Luis de la Torre Cubillo
/// @notice Exposes modifiers, shared helpers and storage utilities for reservation facets
abstract contract BaseReservationFacet is InstitutionalReservableTokenEnumerable {
    using LibAccessControlEnumerable for AppStorage;
    using EnumerableSet for EnumerableSet.Bytes32Set;
    using EnumerableSet for EnumerableSet.AddressSet;

    /// @notice Emitted when a provider successfully collects funds from completed reservations
    /// @param provider The address of the lab provider
    /// @param labId The ID of the lab from which funds were collected
    /// @param amount Total amount of tokens collected
    /// @param reservationsProcessed Number of reservations that were processed
    event FundsCollected(address indexed provider, uint256 indexed labId, uint256 amount, uint256 reservationsProcessed);

    uint256 internal constant REVENUE_DENOMINATOR = 100;
    uint256 internal constant REVENUE_PROVIDER = 70;
    uint256 internal constant REVENUE_TREASURY = 15;
    uint256 internal constant REVENUE_SUBSIDIES = 10;
    uint256 internal constant REVENUE_GOVERNANCE = 5;

    uint256 internal constant CANCEL_FEE_TOTAL = 3;
    uint256 internal constant CANCEL_FEE_PROVIDER = 1;
    uint256 internal constant CANCEL_FEE_TREASURY = 1;
    uint256 internal constant CANCEL_FEE_GOVERNANCE = 1;

    /// @dev Modifier to restrict access to functions callable only by accounts with DEFAULT_ADMIN_ROLE
    modifier defaultAdminRole() {
        if (!ProviderFacet(address(this)).hasRole(_s().DEFAULT_ADMIN_ROLE, msg.sender)) {
            revert("Only default admin");
        }
        _;
    }

    /// @dev Modifier that restricts function access to registered lab providers
    modifier isLabProvider() {
        if (!_s()._isLabProvider(msg.sender)) revert("Only LabProvider");
        _;
    }

    // ---------------------------------------------------------------------
    // Abstract hooks implemented by WalletReservationFacet / InstitutionalReservationFacet
    // ---------------------------------------------------------------------

    function _reservationRequest(
        uint256 _labId,
        uint32 _start,
        uint32 _end
    ) internal virtual;

    function _institutionalReservationRequest(
        address institutionalProvider,
        string calldata puc,
        uint256 _labId,
        uint32 _start,
        uint32 _end
    ) internal virtual;

    function _confirmReservationRequest(bytes32 _reservationKey) internal virtual;

    function _confirmInstitutionalReservationRequest(
        address institutionalProvider,
        bytes32 _reservationKey
    ) internal virtual;

    function _denyReservationRequest(bytes32 _reservationKey) internal virtual;

    function _denyInstitutionalReservationRequest(
        address institutionalProvider,
        string calldata puc,
        bytes32 _reservationKey
    ) internal virtual;

    function _cancelReservationRequest(bytes32 _reservationKey) internal virtual;

    function _cancelBooking(bytes32 _reservationKey) internal virtual;

    function _cancelInstitutionalReservationRequest(
        address institutionalProvider,
        string calldata puc,
        bytes32 _reservationKey
    ) internal virtual;

    function _cancelInstitutionalBooking(address institutionalProvider, bytes32 _reservationKey) internal virtual;

    function _requestFunds(uint256 _labId, uint256 maxBatch) internal virtual;

    function _getLabTokenAddress() internal view virtual returns (address);

    function _getSafeBalance() internal view virtual returns (uint256);

    function _releaseExpiredReservations(
        uint256 _labId,
        address _user,
        uint256 maxBatch
    ) internal virtual returns (uint256);

    function _releaseInstitutionalExpiredReservations(
        address institutionalProvider,
        string calldata puc,
        uint256 _labId,
        uint256 maxBatch
    ) internal virtual returns (uint256);

    function _getInstitutionalUserReservationCount(
        address institutionalProvider,
        string calldata puc
    ) internal view virtual returns (uint256);

    function _getInstitutionalUserReservationByIndex(
        address institutionalProvider,
        string calldata puc,
        uint256 index
    ) internal view virtual returns (bytes32);

    function _hasInstitutionalUserActiveBooking(
        address institutionalProvider,
        string calldata puc,
        uint256 labId
    ) internal virtual returns (bool);

    function _getInstitutionalUserActiveReservationKey(
        address institutionalProvider,
        string calldata puc,
        uint256 labId
    ) internal virtual returns (bytes32);

    // ---------------------------------------------------------------------
    // Shared helpers
    // ---------------------------------------------------------------------

    /// @dev Internal helper to release expired reservations without access control checks
    function _releaseExpiredReservationsInternal(uint256 _labId, address _user, uint256 maxBatch)
        internal
        returns (uint256 processed)
    {
        AppStorage storage s = _s();
        EnumerableSet.Bytes32Set storage userReservations = s.reservationKeysByTokenAndUser[_labId][_user];
        uint256 len = userReservations.length();
        uint256 i;
        uint256 currentTime = block.timestamp;

        while (i < len && processed < maxBatch) {
            bytes32 key = userReservations.at(i);
            Reservation storage reservation = s.reservations[key];

            // Only process expired reservations that are still CONFIRMED
            if (reservation.end < currentTime && reservation.status == CONFIRMED) {
                _finalizeReservationForPayout(s, key, reservation, _labId);
                len = userReservations.length();
                unchecked {
                    ++processed;
                }
                continue;
            }

            unchecked {
                ++i;
            }
        }

        if (processed > 0) {
            emit ReservationsReleased(_user, _labId, processed);
        }

        return processed;
    }

    /// @dev Checks whether the current lab owner still satisfies stake and listing requirements.
    function _providerCanFulfill(AppStorage storage s, address labProvider, uint256 labId)
        internal
        view
        returns (bool)
    {
        if (!s.tokenStatus[labId]) {
            return false;
        }

        uint256 listedLabsCount = s.providerStakes[labProvider].listedLabsCount;
        uint256 requiredStake = calculateRequiredStake(labProvider, listedLabsCount);
        return s.providerStakes[labProvider].stakedAmount >= requiredStake;
    }

    /// @dev Finalizes a reservation by crediting the lab payout balance and cleaning indexes
    function _finalizeReservationForPayout(
        AppStorage storage s,
        bytes32 key,
        Reservation storage reservation,
        uint256 labId
    ) internal returns (bool) {
        if (reservation.status == COLLECTED || reservation.status == CANCELLED) {
            return false;
        }

        address trackingKey = _computeTrackingKey(reservation);
        address labProvider = reservation.labProvider;
        uint256 reservationPrice = reservation.price;

        if (reservation.status == CONFIRMED || reservation.status == IN_USE) {
            _removeReservationFromCalendar(labId, reservation.start);
        }

        if (_isActiveReservationStatus(reservation.status)) {
            _decrementActiveReservationCounters(reservation);
        }

        reservation.status = COLLECTED;

        if (reservationPrice > 0) {
            _creditRevenueBuckets(s, reservation);
        }

        s.reservationsProvider[labProvider].remove(key);
        s.reservationsByLabId[labId].remove(key);
        s.reservationKeys.remove(key);
        s.reservationKeysByToken[labId].remove(key);
        s.renters[reservation.renter].remove(key);

        if (s.activeReservationCountByTokenAndUser[labId][trackingKey] > 0) {
            s.activeReservationCountByTokenAndUser[labId][trackingKey]--;
        }
        s.reservationKeysByTokenAndUser[labId][trackingKey].remove(key);

        if (s.activeReservationByTokenAndUser[labId][trackingKey] == key) {
            bytes32 nextKey = _findNextEarliestReservation(labId, trackingKey);
            s.activeReservationByTokenAndUser[labId][trackingKey] = nextKey;
        }

        if (_isInstitutionalReservation(reservation)) {
            s.renters[trackingKey].remove(key);
            _invalidateInstitutionalActiveReservation(s, labId, reservation, key);
        }

        if (s.payoutHeapContains[key]) {
            s.payoutHeapContains[key] = false;
        }

        return true;
    }

    function _creditRevenueBuckets(AppStorage storage s, Reservation storage reservation) internal {
        uint96 providerShare = reservation.providerShare;
        uint96 treasuryShare = reservation.projectTreasuryShare;
        uint96 subsidiesShare = reservation.subsidiesShare;
        uint96 governanceShare = reservation.governanceShare;

        if (providerShare > 0) {
            s.pendingProviderPayout[reservation.labId] += providerShare;
        }
        if (treasuryShare > 0) {
            s.pendingProjectTreasury += treasuryShare;
        }
        if (subsidiesShare > 0) {
            s.pendingSubsidies += subsidiesShare;
        }
        if (governanceShare > 0) {
            s.pendingGovernance += governanceShare;
        }
    }

    function _calculateRevenueSplit(uint96 price)
        internal
        pure
        returns (uint96 providerShare, uint96 treasuryShare, uint96 subsidiesShare, uint96 governanceShare)
    {
        if (price == 0) {
            return (0, 0, 0, 0);
        }

        providerShare = uint96((uint256(price) * REVENUE_PROVIDER) / REVENUE_DENOMINATOR);
        treasuryShare = uint96((uint256(price) * REVENUE_TREASURY) / REVENUE_DENOMINATOR);
        subsidiesShare = uint96((uint256(price) * REVENUE_SUBSIDIES) / REVENUE_DENOMINATOR);
        governanceShare = uint96((uint256(price) * REVENUE_GOVERNANCE) / REVENUE_DENOMINATOR);

        uint96 allocated = providerShare + treasuryShare + subsidiesShare + governanceShare;
        uint96 remainder = price - allocated;
        treasuryShare += remainder; // round remainder to treasury as agreed
    }

    function _setReservationSplit(Reservation storage reservation) internal {
        (
            uint96 providerShare,
            uint96 treasuryShare,
            uint96 subsidiesShare,
            uint96 governanceShare
        ) = _calculateRevenueSplit(reservation.price);

        reservation.providerShare = providerShare;
        reservation.projectTreasuryShare = treasuryShare;
        reservation.subsidiesShare = subsidiesShare;
        reservation.governanceShare = governanceShare;
    }

    function _computeCancellationFee(uint96 price)
        internal
        pure
        returns (uint96 providerFee, uint96 treasuryFee, uint96 governanceFee, uint96 refundAmount)
    {
        if (price == 0) {
            return (0, 0, 0, 0);
        }

        uint96 totalFee = uint96((uint256(price) * CANCEL_FEE_TOTAL) / REVENUE_DENOMINATOR);
        providerFee = uint96((uint256(price) * CANCEL_FEE_PROVIDER) / REVENUE_DENOMINATOR);
        treasuryFee = uint96((uint256(price) * CANCEL_FEE_TREASURY) / REVENUE_DENOMINATOR);
        governanceFee = uint96((uint256(price) * CANCEL_FEE_GOVERNANCE) / REVENUE_DENOMINATOR);

        uint96 allocated = providerFee + treasuryFee + governanceFee;
        if (allocated < totalFee) {
            uint96 remainder = totalFee - allocated;
            treasuryFee += remainder; // round fee remainder to treasury bucket
        }

        refundAmount = price - totalFee;
    }

    function _applyCancellationFees(
        AppStorage storage s,
        uint256 labId,
        uint96 providerFee,
        uint96 treasuryFee,
        uint96 governanceFee
    ) internal {
        if (providerFee > 0) {
            s.pendingProviderPayout[labId] += providerFee;
        }
        if (treasuryFee > 0) {
            s.pendingProjectTreasury += treasuryFee;
        }
        if (governanceFee > 0) {
            s.pendingGovernance += governanceFee;
        }
    }

    function _enqueuePayoutCandidate(
        AppStorage storage s,
        uint256 labId,
        bytes32 key,
        uint32 end
    ) internal {
        LibAppStorage.PayoutCandidate[] storage heap = s.payoutHeaps[labId];
        if (s.payoutHeapContains[key]) {
            return;
        }
        heap.push(LibAppStorage.PayoutCandidate(end, key));
        s.payoutHeapContains[key] = true;
        _heapifyUp(heap, heap.length - 1);
    }

    function _popEligiblePayoutCandidate(
        AppStorage storage s,
        uint256 labId,
        uint256 currentTime
    ) internal returns (bytes32) {
        LibAppStorage.PayoutCandidate[] storage heap = s.payoutHeaps[labId];

        // Lazy cleanup optimization: if >20% of heap is invalid entries, rebuild heap
        uint256 heapSize = heap.length;
        uint256 invalidCount = s.payoutHeapInvalidCount[labId];
        if (heapSize > 0 && invalidCount > heapSize / 5) {
            _compactHeap(s, labId);
            heapSize = heap.length;
        }

        while (heapSize > 0) {
            LibAppStorage.PayoutCandidate memory root = heap[0];
            if (root.end > currentTime) {
                return bytes32(0);
            }
            _removeHeapRoot(heap);
            s.payoutHeapContains[root.key] = false;
            Reservation storage reservation = s.reservations[root.key];
            if (
                reservation.labId == labId
                    && (reservation.status == CONFIRMED || reservation.status == IN_USE || reservation.status == COMPLETED)
            ) {
                return root.key;
            }
            if (invalidCount > 0) {
                s.payoutHeapInvalidCount[labId]--;
                invalidCount--;
            }
            heapSize--;
        }
        return bytes32(0);
    }

    function _heapifyUp(
        LibAppStorage.PayoutCandidate[] storage heap,
        uint256 index
    ) internal {
        while (index > 0) {
            uint256 parent = (index - 1) / 2;
            if (heap[index].end >= heap[parent].end) {
                break;
            }
            (heap[index], heap[parent]) = (heap[parent], heap[index]);
            index = parent;
        }
    }

    function _removeHeapRoot(LibAppStorage.PayoutCandidate[] storage heap) internal {
        uint256 lastIndex = heap.length - 1;
        if (lastIndex == 0) {
            heap.pop();
            return;
        }
        heap[0] = heap[lastIndex];
        heap.pop();
        _heapifyDown(heap, 0);
    }

    function _heapifyDown(
        LibAppStorage.PayoutCandidate[] storage heap,
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
            if (right < length && heap[right].end < heap[left].end) {
                smallest = right;
            }
            if (heap[index].end <= heap[smallest].end) {
                break;
            }
            (heap[index], heap[smallest]) = (heap[smallest], heap[index]);
            index = smallest;
        }
    }

    /// @dev Compacts the heap by removing all invalid entries (cancelled/collected reservations)
    /// @notice Optimized version using in-place compaction to reduce gas costs
    function _compactHeap(AppStorage storage s, uint256 labId) internal {
        LibAppStorage.PayoutCandidate[] storage heap = s.payoutHeaps[labId];
        uint256 originalLength = heap.length; // Preserve original length for safe iteration
        uint256 writeIndex = 0;

        // In-place compaction: iterate through original heap, keeping only valid entries
        for (uint256 readIndex = 0; readIndex < originalLength; readIndex++) {
            bytes32 key = heap[readIndex].key;
            Reservation storage reservation = s.reservations[key];

            if (
                reservation.labId == labId
                    && (reservation.status == CONFIRMED || reservation.status == IN_USE || reservation.status == COMPLETED)
            ) {
                // Keep valid entry: move to write position if different from read position
                if (writeIndex != readIndex) {
                    heap[writeIndex] = heap[readIndex]; // Copies both end and key
                }
                writeIndex++;
            } else {
                // Remove invalid entry: reset containment flag
                s.payoutHeapContains[key] = false;
            }
        }

        // Truncate heap to new valid size
        while (heap.length > writeIndex) {
            heap.pop();
        }

        // Rebuild heap using efficient bottom-up construction (O(n) vs O(n log n))
        if (writeIndex > 1) {
            for (uint256 i = (writeIndex - 1) / 2 + 1; i > 0; i--) {
                _heapifyDown(heap, i - 1);
            }
        }

        s.payoutHeapInvalidCount[labId] = 0;
    }
}
