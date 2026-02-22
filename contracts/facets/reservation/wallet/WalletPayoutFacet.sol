// SPDX-License-Identifier: GPL-3.0-or-later
pragma solidity ^0.8.31;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {IERC721} from "@openzeppelin/contracts/token/ERC721/IERC721.sol";
import {EnumerableSet} from "@openzeppelin/contracts/utils/structs/EnumerableSet.sol";
import {ReentrancyGuardTransient} from "@openzeppelin/contracts/utils/ReentrancyGuardTransient.sol";
import {AppStorage, Reservation, PayoutCandidate, LibAppStorage} from "../../../libraries/LibAppStorage.sol";
import {LibAccessControlEnumerable} from "../../../libraries/LibAccessControlEnumerable.sol";
import {ActionIntentPayload} from "../../../libraries/IntentTypes.sol";
import {LibIntent} from "../../../libraries/LibIntent.sol";
import {LibReputation} from "../../../libraries/LibReputation.sol";

interface IStakingFacet {
    function updateLastReservation(
        address provider
    ) external;
}

/// @title WalletPayoutFacet
/// @author
/// - Luis de la Torre Cubillo
/// - Juan Luis Ramos Villalón
/// @dev Facet contract to manage fund collection and payouts for lab providers.
/// Provides functions for collecting reservation funds, withdrawing revenue shares,
/// and administrative recovery of orphaned payouts.

contract WalletPayoutFacet is ReentrancyGuardTransient {
    using SafeERC20 for IERC20;
    using EnumerableSet for EnumerableSet.Bytes32Set;
    using EnumerableSet for EnumerableSet.AddressSet;
    using LibAccessControlEnumerable for AppStorage;

    /// @dev Reservation status constants (must match reservation facets)
    uint8 internal constant _PENDING = 0;
    uint8 internal constant _CONFIRMED = 1;
    uint8 internal constant _IN_USE = 2;
    uint8 internal constant _COMPLETED = 3;
    uint8 internal constant _COLLECTED = 4;
    uint8 internal constant _CANCELLED = 5;

    /// @dev Delay before admin can recover orphaned payouts (30 days)
    uint256 internal constant _ORPHAN_PAYOUT_DELAY = 30 days;

    /// @notice Event emitted when a lab intent is processed
    event LabIntentProcessed(
        bytes32 indexed requestId, uint256 labId, string action, address provider, bool success, string reason
    );

    /// @notice Emitted when funds are collected for a lab
    event FundsCollected(
        address indexed provider, uint256 indexed labId, uint256 amount, uint256 reservationsProcessed
    );

    /// @notice Emitted when default admin recovers stale payouts for a lab
    event OrphanedLabPayoutRecovered(
        uint256 indexed labId, address indexed recipient, uint256 providerPayout, uint256 reservationsProcessed
    );

    /// @notice Emitted when stale/invalid payout heap entries are pruned incrementally
    event PayoutHeapPruned(uint256 indexed labId, uint256 removed, uint256 remaining);

    /// @dev Returns the AppStorage struct from the diamond storage slot.
    function _s() internal pure returns (AppStorage storage s) {
        s = LibAppStorage.diamondStorage();
    }

    /// @dev Modifier to restrict access to functions that can only be executed by the LabProvider.
    modifier isLabProvider() {
        _isLabProvider();
        _;
    }

    function _isLabProvider() internal view {
        require(_s()._isLabProvider(msg.sender), "Only one LabProvider can perform this action");
    }

    /// @dev Modifier to restrict access to functions that can only be executed by the DEFAULT_ADMIN_ROLE.
    modifier onlyDefaultAdminRole() {
        _onlyDefaultAdminRole();
        _;
    }

    function _onlyDefaultAdminRole() internal view {
        AppStorage storage s = _s();
        require(s.roleMembers[s.DEFAULT_ADMIN_ROLE].contains(msg.sender), "Only admin");
    }

    function requestFunds(
        uint256 _labId,
        uint256 maxBatch
    ) external isLabProvider nonReentrant {
        _requestFunds(_labId, maxBatch);
    }

    /// @notice Collects funds via intent (institutional flow) while keeping direct call available
    function requestFundsWithIntent(
        bytes32 requestId,
        ActionIntentPayload calldata payload
    ) external isLabProvider nonReentrant {
        require(payload.labId != 0, "REQUEST_FUNDS: labId required");
        require(payload.executor == msg.sender, "Executor must be caller");
        uint256 maxBatch = uint256(payload.maxBatch);
        if (maxBatch == 0 || maxBatch > 100) revert("Invalid batch size");

        bytes32 payloadHash = LibIntent.hashActionPayload(payload);
        LibIntent.consumeIntent(requestId, LibIntent.ACTION_REQUEST_FUNDS, payloadHash, msg.sender);

        _requestFunds(payload.labId, maxBatch);
        emit LabIntentProcessed(requestId, payload.labId, "REQUEST_FUNDS", msg.sender, true, "");
    }

    function getLabTokenAddress() external view returns (address) {
        return _s().labTokenAddress;
    }

    function getSafeBalance() external view returns (uint256) {
        return IERC20(_s().labTokenAddress).balanceOf(address(this));
    }

    /// @notice Returns the total pending payout amount for a lab (wallet + institutional)
    /// @dev Useful for backends/frontends to decide when to call requestFunds()
    ///      and to display total collectable funds in provider dashboard
    /// @param _labId The ID of the lab to query
    /// @return walletPayout Amount pending for direct wallet payout to lab owner
    /// @return institutionalPayout Total amount pending for institutional treasury payouts
    /// @return totalPayout Sum of wallet and institutional payouts
    /// @return institutionalCollectorCount Number of pending closeable reservations
    function getPendingLabPayout(
        uint256 _labId
    )
        external
        view
        returns (
            uint256 walletPayout,
            uint256 institutionalPayout,
            uint256 totalPayout,
            uint256 institutionalCollectorCount
        )
    {
        AppStorage storage s = _s();

        // Already finalized payouts waiting to be withdrawn.
        walletPayout = s.pendingProviderPayout[_labId];

        // Keep the output shape stable even though institutional payout buckets are unused.
        institutionalPayout = 0;
        institutionalCollectorCount = 0;

        uint256 currentTime = block.timestamp;
        PayoutCandidate[] storage heap = s.payoutHeaps[_labId];
        uint256 heapLength = heap.length;

        // Include not-yet-finalized reservations that are already eligible for collection.
        if (heapLength > 0) {
            (uint256 pendingProviderPayout, uint256 pendingClosures) = _accumulateEligiblePayoutFromHeap(
                s,
                heap,
                heapLength,
                0,
                currentTime,
                _labId
            );
            walletPayout += pendingProviderPayout;
            institutionalCollectorCount = pendingClosures;
        }

        totalPayout = walletPayout + institutionalPayout;
    }

    /// @notice Bounded/paginated variant of getPendingLabPayout to avoid large eth_call executions.
    /// @dev Scans payout heap entries in [offset, offset+limit). To aggregate full pending values,
    ///      callers should iterate until hasMore=false, summing chunk outputs.
    ///      The already-accrued provider bucket (pendingProviderPayout) is included only when offset == 0.
    ///      NOTE: this function intentionally uses linear index scanning (instead of heap branch pruning)
    ///      so offset pagination remains deterministic and easy to compose off-chain.
    /// @param _labId The lab to query
    /// @param offset Heap index offset to start scanning from
    /// @param limit Max heap entries to scan in this call (1-1000)
    /// @return walletPayoutChunk Provider payout found in this chunk (+pendingProviderPayout if offset==0)
    /// @return institutionalPayoutChunk Reserved for compatibility (currently always 0)
    /// @return totalPayoutChunk Sum of wallet and institutional chunk outputs
    /// @return institutionalCollectorCountChunk Number of closeable reservations found in this chunk
    /// @return nextOffset Offset to use in next page call
    /// @return hasMore True when more heap entries remain after this chunk
    function getPendingLabPayoutPaginated(
        uint256 _labId,
        uint256 offset,
        uint256 limit
    )
        external
        view
        returns (
            uint256 walletPayoutChunk,
            uint256 institutionalPayoutChunk,
            uint256 totalPayoutChunk,
            uint256 institutionalCollectorCountChunk,
            uint256 nextOffset,
            bool hasMore
        )
    {
        require(limit > 0 && limit <= 1000, "Invalid limit");

        AppStorage storage s = _s();
        institutionalPayoutChunk = 0;

        if (offset == 0) {
            walletPayoutChunk = s.pendingProviderPayout[_labId];
        }

        PayoutCandidate[] storage heap = s.payoutHeaps[_labId];
        uint256 heapLength = heap.length;
        if (offset >= heapLength) {
            nextOffset = heapLength;
            totalPayoutChunk = walletPayoutChunk;
            return (
                walletPayoutChunk,
                institutionalPayoutChunk,
                totalPayoutChunk,
                institutionalCollectorCountChunk,
                nextOffset,
                false
            );
        }

        uint256 end = offset + limit;
        if (end > heapLength) {
            end = heapLength;
        }

        uint256 currentTime = block.timestamp;
        for (uint256 i = offset; i < end;) {
            PayoutCandidate storage candidate = heap[i];
            if (candidate.end <= currentTime) {
                Reservation storage reservation = s.reservations[candidate.key];
                if (
                    reservation.labId == _labId
                        && (reservation.status == _CONFIRMED
                            || reservation.status == _IN_USE
                            || reservation.status == _COMPLETED)
                ) {
                    walletPayoutChunk += reservation.providerShare;
                    institutionalCollectorCountChunk++;
                }
            }
            unchecked {
                ++i;
            }
        }

        nextOffset = end;
        hasMore = end < heapLength;
        totalPayoutChunk = walletPayoutChunk + institutionalPayoutChunk;
    }

    /// @dev Traverses payout heap with pruning:
    ///      if node.end > currentTime, all descendants are also ineligible.
    function _accumulateEligiblePayoutFromHeap(
        AppStorage storage s,
        PayoutCandidate[] storage heap,
        uint256 heapLength,
        uint256 nodeIndex,
        uint256 currentTime,
        uint256 labId
    ) internal view returns (uint256 providerPayout, uint256 pendingClosures) {
        if (nodeIndex >= heapLength) {
            return (0, 0);
        }

        PayoutCandidate storage candidate = heap[nodeIndex];
        if (candidate.end > currentTime) {
            return (0, 0);
        }

        Reservation storage reservation = s.reservations[candidate.key];
        if (
            reservation.labId == labId
                && (reservation.status == _CONFIRMED
                    || reservation.status == _IN_USE
                    || reservation.status == _COMPLETED)
        ) {
            providerPayout = reservation.providerShare;
            pendingClosures = 1;
        }

        uint256 left = nodeIndex * 2 + 1;
        if (left < heapLength) {
            (uint256 leftPayout, uint256 leftClosures) = _accumulateEligiblePayoutFromHeap(
                s,
                heap,
                heapLength,
                left,
                currentTime,
                labId
            );
            providerPayout += leftPayout;
            pendingClosures += leftClosures;
        }

        uint256 right = left + 1;
        if (right < heapLength) {
            (uint256 rightPayout, uint256 rightClosures) = _accumulateEligiblePayoutFromHeap(
                s,
                heap,
                heapLength,
                right,
                currentTime,
                labId
            );
            providerPayout += rightPayout;
            pendingClosures += rightClosures;
        }
    }

    /// @notice One-time initializer to set revenue recipient wallets (15% treasury, 10% subsidies, 5% governance)
    /// @dev Can only be called once by default admin. Addresses are immutable afterwards.
    function initializeRevenueRecipients(
        address projectTreasury,
        address subsidies,
        address governance
    ) external onlyDefaultAdminRole {
        AppStorage storage s = _s();
        require(s.projectTreasuryWallet == address(0), "Revenue recipients already set");
        require(projectTreasury != address(0) && subsidies != address(0) && governance != address(0), "Invalid address");

        s.projectTreasuryWallet = projectTreasury;
        s.subsidiesWallet = subsidies;
        s.governanceWallet = governance;
    }

    /// @notice Withdraw accumulated project treasury share
    function withdrawProjectTreasury() external {
        AppStorage storage s = _s();
        require(msg.sender == s.projectTreasuryWallet, "Not treasury wallet");
        uint256 amount = s.pendingProjectTreasury;
        require(amount > 0, "No funds");
        s.pendingProjectTreasury = 0;
        IERC20(s.labTokenAddress).safeTransfer(msg.sender, amount);
    }

    /// @notice Withdraw accumulated subsidies share
    function withdrawSubsidies() external {
        AppStorage storage s = _s();
        require(msg.sender == s.subsidiesWallet, "Not subsidies wallet");
        uint256 amount = s.pendingSubsidies;
        require(amount > 0, "No funds");
        s.pendingSubsidies = 0;
        IERC20(s.labTokenAddress).safeTransfer(msg.sender, amount);
    }

    /// @notice Withdraw accumulated governance incentives share
    function withdrawGovernance() external {
        AppStorage storage s = _s();
        require(msg.sender == s.governanceWallet, "Not governance wallet");
        uint256 amount = s.pendingGovernance;
        require(amount > 0, "No funds");
        s.pendingGovernance = 0;
        IERC20(s.labTokenAddress).safeTransfer(msg.sender, amount);
    }

    /// @notice Admin path to recover stale lab payouts when the provider is inactive or lost access
    /// @dev Processes only reservations whose end time passed the timelock and withdraws matured provider bucket
    /// @param _labId Lab whose payouts should be recovered
    /// @param maxBatch Maximum reservations to process in this call (1-100)
    /// @param recipient Address that will receive the provider share once unlocked
    function adminRecoverOrphanedPayouts(
        uint256 _labId,
        uint256 maxBatch,
        address recipient
    ) external onlyDefaultAdminRole nonReentrant {
        if (recipient == address(0)) revert("Invalid recipient");
        if (maxBatch == 0 || maxBatch > 100) revert("Invalid batch size");

        AppStorage storage s = _s();
        uint256 processed;
        uint256 cutoffTime = block.timestamp - _ORPHAN_PAYOUT_DELAY;

        // Only finalize reservations that ended before cutoffTime
        while (processed < maxBatch) {
            bytes32 key = _popEligiblePayoutCandidate(s, _labId, cutoffTime);
            if (key == bytes32(0)) {
                break;
            }
            Reservation storage reservation = s.reservations[key];
            if (_finalizeReservationForPayout(s, key, reservation, _labId)) {
                unchecked {
                    ++processed;
                }
            }
        }

        uint256 providerPayout = s.pendingProviderPayout[_labId];
        bool payoutUnlocked = providerPayout > 0 && s.pendingProviderLastUpdated[_labId] > 0
            && block.timestamp >= s.pendingProviderLastUpdated[_labId] + _ORPHAN_PAYOUT_DELAY;

        if (payoutUnlocked) {
            s.pendingProviderPayout[_labId] = 0;
            IERC20(s.labTokenAddress).safeTransfer(recipient, providerPayout);
        } else {
            providerPayout = 0;
        }

        if (providerPayout == 0 && processed == 0) revert("Nothing to recover");

        emit OrphanedLabPayoutRecovered(_labId, recipient, providerPayout, processed);
    }

    /// @notice Incrementally prune invalid payout heap entries to keep requestFunds gas predictable.
    /// @dev Useful as a maintenance action when a lab accumulated many cancelled/collected heap entries.
    ///      Complexity is O(k log n), where k is the number of removals in this call.
    ///      Prefer this function for small/regular cleanups; large rebuilds are handled by _compactHeap.
    /// @param _labId Lab whose payout heap should be pruned
    /// @param maxIterations Maximum heap slots to inspect in this call (1-1000)
    /// @return removed Number of invalid entries removed from the heap
    function prunePayoutHeap(
        uint256 _labId,
        uint256 maxIterations
    ) external nonReentrant returns (uint256 removed) {
        if (maxIterations == 0 || maxIterations > 1000) revert("Invalid iteration limit");

        AppStorage storage s = _s();
        bool isAdmin = s.roleMembers[s.DEFAULT_ADMIN_ROLE].contains(msg.sender);
        if (!isAdmin) {
            address labOwner = IERC721(address(this)).ownerOf(_labId);
            address backend = s.institutionalBackends[labOwner];
            if (msg.sender != labOwner && msg.sender != backend) revert("Not authorized");
        }

        removed = _prunePayoutHeap(s, _labId, maxIterations);
        emit PayoutHeapPruned(_labId, removed, s.payoutHeaps[_labId].length);
    }

    // -------------------------------------------------------------------------
    // Internal helpers
    // -------------------------------------------------------------------------

    /// @dev Max heap entries to compact in a single call
    uint256 internal constant _MAX_COMPACTION_SIZE = 200;

    function _requestFunds(
        uint256 _labId,
        uint256 maxBatch
    ) internal {
        if (maxBatch == 0 || maxBatch > 100) revert("Invalid batch size");

        AppStorage storage s = _s();

        address labOwner = IERC721(address(this)).ownerOf(_labId);
        address backend = s.institutionalBackends[labOwner];
        if (msg.sender != labOwner && msg.sender != backend) {
            revert("Not authorized");
        }

        uint256 processed;
        uint256 currentTime = block.timestamp;

        while (processed < maxBatch) {
            bytes32 key = _popEligiblePayoutCandidate(s, _labId, currentTime);
            if (key == bytes32(0)) {
                break;
            }
            Reservation storage reservation = s.reservations[key];
            if (_finalizeReservationForPayout(s, key, reservation, _labId)) {
                unchecked {
                    ++processed;
                }
            }
        }

        uint256 providerPayout = s.pendingProviderPayout[_labId];
        if (providerPayout == 0 && processed == 0) revert("No completed reservations");

        if (providerPayout > 0) {
            IERC20(s.labTokenAddress).safeTransfer(labOwner, providerPayout);
            s.pendingProviderPayout[_labId] = 0;
        }

        if (processed > 0) {
            IStakingFacet(address(this)).updateLastReservation(labOwner);
        }

        emit FundsCollected(labOwner, _labId, providerPayout, processed);
    }

    /// @dev Pops the first eligible reservation from the heap if its end <= cutoff
    function _popEligiblePayoutCandidate(
        AppStorage storage s,
        uint256 labId,
        uint256 currentTime
    ) internal returns (bytes32) {
        PayoutCandidate[] storage heap = s.payoutHeaps[labId];

        // Lazy cleanup optimization: if >20% of heap is invalid entries, rebuild heap
        uint256 heapSize = heap.length;
        uint256 invalidCount = s.payoutHeapInvalidCount[labId];
        if (heapSize > 0 && invalidCount > heapSize / 5) {
            _compactHeap(s, labId);
            heapSize = heap.length;
        }

        while (heapSize > 0) {
            PayoutCandidate memory root = heap[0];
            if (root.end > currentTime) {
                return bytes32(0);
            }
            _removeHeapRoot(heap);
            s.payoutHeapContains[root.key] = false;
            Reservation storage reservation = s.reservations[root.key];
            if (
                reservation.labId == labId
                    && (reservation.status == _CONFIRMED
                        || reservation.status == _IN_USE
                        || reservation.status == _COMPLETED)
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

    function _removeHeapRoot(
        PayoutCandidate[] storage heap
    ) internal {
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
        PayoutCandidate[] storage heap,
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
            PayoutCandidate memory temp = heap[index];
            heap[index] = heap[smallest];
            heap[smallest] = temp;
            index = smallest;
        }
    }

    function _heapifyUp(
        PayoutCandidate[] storage heap,
        uint256 index
    ) internal {
        while (index > 0) {
            uint256 parent = (index - 1) / 2;
            if (heap[index].end >= heap[parent].end) {
                break;
            }
            PayoutCandidate memory temp = heap[index];
            heap[index] = heap[parent];
            heap[parent] = temp;
            index = parent;
        }
    }

    function _removeHeapAt(
        PayoutCandidate[] storage heap,
        uint256 index
    ) internal {
        uint256 lastIndex = heap.length - 1;
        if (index == lastIndex) {
            heap.pop();
            return;
        }

        heap[index] = heap[lastIndex];
        heap.pop();
        _heapifyDown(heap, index);
        if (index < heap.length) {
            _heapifyUp(heap, index);
        }
    }

    function _prunePayoutHeap(
        AppStorage storage s,
        uint256 labId,
        uint256 maxIterations
    ) internal returns (uint256 removed) {
        PayoutCandidate[] storage heap = s.payoutHeaps[labId];
        uint256 iterations;
        uint256 index;

        while (index < heap.length && iterations < maxIterations) {
            bytes32 key = heap[index].key;
            Reservation storage reservation = s.reservations[key];
            bool valid = reservation.labId == labId
                && (reservation.status == _CONFIRMED || reservation.status == _IN_USE || reservation.status == _COMPLETED);

            if (!valid) {
                s.payoutHeapContains[key] = false;
                _removeHeapAt(heap, index);
                if (s.payoutHeapInvalidCount[labId] > 0) {
                    s.payoutHeapInvalidCount[labId]--;
                }
                removed++;
            } else {
                index++;
            }

            iterations++;
        }
    }

    /// @dev Compacts the heap by removing all invalid entries in one pass.
    ///      This is O(n) for the compaction + heap rebuild and is triggered lazily
    ///      when invalid density is high, with a size guard (_MAX_COMPACTION_SIZE).
    function _compactHeap(
        AppStorage storage s,
        uint256 labId
    ) internal {
        PayoutCandidate[] storage heap = s.payoutHeaps[labId];
        uint256 originalLength = heap.length;
        if (originalLength > _MAX_COMPACTION_SIZE) {
            return;
        }
        uint256 writeIndex = 0;

        for (uint256 readIndex = 0; readIndex < originalLength; readIndex++) {
            bytes32 key = heap[readIndex].key;
            Reservation storage reservation = s.reservations[key];

            if (
                reservation.labId == labId
                    && (reservation.status == _CONFIRMED
                        || reservation.status == _IN_USE
                        || reservation.status == _COMPLETED)
            ) {
                if (writeIndex != readIndex) {
                    heap[writeIndex] = heap[readIndex];
                }
                writeIndex++;
            } else {
                s.payoutHeapContains[key] = false;
            }
        }

        while (heap.length > writeIndex) {
            heap.pop();
        }

        if (writeIndex > 1) {
            for (uint256 i = (writeIndex - 1) / 2 + 1; i > 0; i--) {
                _heapifyDown(heap, i - 1);
            }
        }

        s.payoutHeapInvalidCount[labId] = 0;
    }

    /// @dev Finalizes a reservation for payout: marks as _COLLECTED, updates counters, accrues shares
    function _finalizeReservationForPayout(
        AppStorage storage s,
        bytes32,
        /* key */
        Reservation storage reservation,
        uint256 labId
    ) internal returns (bool) {
        // Skip if wrong lab or already finalized
        if (reservation.labId != labId) return false;
        if (reservation.status != _CONFIRMED && reservation.status != _IN_USE && reservation.status != _COMPLETED) {
            return false;
        }

        // Mark as collected
        uint8 previousStatus = reservation.status;
        reservation.status = _COLLECTED;
        if (previousStatus == _IN_USE) {
            LibReputation.recordCompletion(labId);
        }

        // Decrement active reservation counter
        if (s.labActiveReservationCount[labId] > 0) {
            s.labActiveReservationCount[labId]--;
        }

        address labProvider = reservation.labProvider;
        if (s.providerActiveReservationCount[labProvider] > 0) {
            s.providerActiveReservationCount[labProvider]--;
        }

        // Accrue shares to pending buckets
        s.pendingProviderPayout[labId] += reservation.providerShare;
        s.pendingProviderLastUpdated[labId] = block.timestamp;
        s.pendingProjectTreasury += reservation.projectTreasuryShare;
        s.pendingSubsidies += reservation.subsidiesShare;
        s.pendingGovernance += reservation.governanceShare;

        return true;
    }
}
