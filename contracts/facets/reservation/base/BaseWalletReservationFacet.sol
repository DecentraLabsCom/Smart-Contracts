// SPDX-License-Identifier: GPL-3.0-or-later
pragma solidity ^0.8.31;

import {EnumerableSet} from "@openzeppelin/contracts/utils/structs/EnumerableSet.sol";
import {InstitutionalReservableTokenEnumerable} from "../../../abstracts/InstitutionalReservableTokenEnumerable.sol";
import {ProviderFacet} from "../../ProviderFacet.sol";
import {LibAccessControlEnumerable} from "../../../libraries/LibAccessControlEnumerable.sol";
import {AppStorage, Reservation} from "../../../libraries/LibAppStorage.sol";
import {LibRevenue} from "../../../libraries/LibRevenue.sol";
import {LibHeap} from "../../../libraries/LibHeap.sol";
import {LibReputation} from "../../../libraries/LibReputation.sol";

/// @dev Interface for StakingFacet to update reservation timestamps
interface IStakingFacetW {
    function updateLastReservation(
        address provider
    ) external;
}

/// @dev Interface for InstitutionalTreasuryFacet to spend from treasury
interface IInstitutionalTreasuryFacetW {
    function checkInstitutionalTreasuryAvailability(
        address provider,
        string calldata puc,
        uint256 amount
    ) external view;
    function spendFromInstitutionalTreasury(
        address provider,
        string calldata puc,
        uint256 amount
    ) external;
    function refundToInstitutionalTreasury(
        address provider,
        string calldata puc,
        uint256 amount
    ) external;
}

/// @title BaseWalletReservationFacet - Wallet-only base for reservation facets (no institutional hooks)
/// @notice Reduces bytecode by eliminating institutional abstract hooks from wallet facets
abstract contract BaseWalletReservationFacet is InstitutionalReservableTokenEnumerable {
    using LibAccessControlEnumerable for AppStorage;
    using EnumerableSet for EnumerableSet.Bytes32Set;
    using EnumerableSet for EnumerableSet.AddressSet;

    error NotImplemented();

    event FundsCollected(
        address indexed provider, uint256 indexed labId, uint256 amount, uint256 reservationsProcessed
    );

    uint256 internal constant _ORPHAN_PAYOUT_DELAY = 90 days;

    modifier onlyDefaultAdminRole() {
        _onlyDefaultAdminRole();
        _;
    }

    function _onlyDefaultAdminRole() internal view {
        if (!ProviderFacet(address(this)).hasRole(_s().DEFAULT_ADMIN_ROLE, msg.sender)) {
            revert("Only default admin");
        }
    }

    modifier isLabProvider() {
        _isLabProvider();
        _;
    }

    function _isLabProvider() internal view {
        if (!_s()._isLabProvider(msg.sender)) revert("Only LabProvider");
    }

    // ---------------------------------------------------------------------
    // Wallet-only abstract hooks (no institutional)
    // ---------------------------------------------------------------------

    function _reservationRequest(
        uint256,
        /* _labId */
        uint32,
        /* _start */
        uint32 /* _end */
    ) internal virtual {
        revert NotImplemented();
    }

    function _confirmReservationRequest(
        bytes32 /* _reservationKey */
    ) internal virtual {
        revert NotImplemented();
    }

    function _denyReservationRequest(
        bytes32 /* _reservationKey */
    ) internal virtual {
        revert NotImplemented();
    }

    function _cancelReservationRequest(
        bytes32 /* _reservationKey */
    ) internal virtual {
        revert NotImplemented();
    }

    function _cancelBooking(
        bytes32 /* _reservationKey */
    ) internal virtual {
        revert NotImplemented();
    }

    function _requestFunds(
        uint256,
        /* _labId */
        uint256 /* maxBatch */
    ) internal virtual {
        revert NotImplemented();
    }

    function _getLabTokenAddress() internal view virtual returns (address) {
        revert NotImplemented();
    }

    function _getSafeBalance() internal view virtual returns (uint256) {
        revert NotImplemented();
    }

    function _releaseExpiredReservations(
        uint256,
        /* _labId */
        address,
        /* _user */
        uint256 /* maxBatch */
    ) internal virtual returns (uint256) {
        revert NotImplemented();
    }

    // ---------------------------------------------------------------------
    // Shared helpers (copied from BaseReservationFacet)
    // ---------------------------------------------------------------------

    function _releaseExpiredReservationsInternal(
        uint256 _labId,
        address _user,
        uint256 maxBatch
    ) internal returns (uint256 processed) {
        AppStorage storage s = _s();
        EnumerableSet.Bytes32Set storage userReservations = s.reservationKeysByTokenAndUser[_labId][_user];
        uint256 len = userReservations.length();
        uint256 i;
        uint256 currentTime = block.timestamp;

        while (i < len && processed < maxBatch) {
            bytes32 key = userReservations.at(i);
            Reservation storage reservation = s.reservations[key];

            if (reservation.end < currentTime && reservation.status == _CONFIRMED) {
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

    function _providerCanFulfill(
        AppStorage storage s,
        address labProvider,
        uint256 labId
    ) internal view returns (bool) {
        if (!s.tokenStatus[labId]) return false;
        uint256 listedLabsCount = s.providerStakes[labProvider].listedLabsCount;
        uint256 requiredStake = calculateRequiredStake(labProvider, listedLabsCount);
        return s.providerStakes[labProvider].stakedAmount >= requiredStake;
    }

    function _finalizeReservationForPayout(
        AppStorage storage s,
        bytes32 key,
        Reservation storage reservation,
        uint256 labId
    ) internal returns (bool) {
        if (reservation.status == _COLLECTED || reservation.status == _CANCELLED) return false;

        address trackingKey = reservation.renter;
        uint256 reservationPrice = reservation.price;

        if (reservation.status == _CONFIRMED || reservation.status == _IN_USE) {
            _removeReservationFromCalendar(labId, reservation.start);
        }

        if (_isActiveReservationStatus(reservation.status)) {
            _decrementActiveReservationCounters(reservation);
        }

        uint8 previousStatus = reservation.status;
        reservation.status = _COLLECTED;
        if (previousStatus == _IN_USE) {
            LibReputation.recordCompletion(labId);
        }

        if (reservationPrice > 0) {
            _creditRevenueBuckets(s, reservation);
        }

        _recordPast(s, labId, trackingKey, key, reservation.end);

        s.reservationKeysByToken[labId].remove(key);
        s.renters[reservation.renter].remove(key);
        if (s.totalReservationsCount > 0) s.totalReservationsCount--;

        if (s.activeReservationCountByTokenAndUser[labId][trackingKey] > 0) {
            s.activeReservationCountByTokenAndUser[labId][trackingKey]--;
        }
        s.reservationKeysByTokenAndUser[labId][trackingKey].remove(key);

        if (s.activeReservationByTokenAndUser[labId][trackingKey] == key) {
            bytes32 nextKey = _findNextEarliestReservation(labId, trackingKey);
            s.activeReservationByTokenAndUser[labId][trackingKey] = nextKey;
        }

        if (s.payoutHeapContains[key]) s.payoutHeapContains[key] = false;

        return true;
    }

    function _updatePendingProviderTimestamp(
        AppStorage storage s,
        uint256 labId,
        uint256 timestamp
    ) internal {
        if (timestamp > s.pendingProviderLastUpdated[labId]) {
            s.pendingProviderLastUpdated[labId] = timestamp;
        }
    }

    function _creditRevenueBuckets(
        AppStorage storage s,
        Reservation storage reservation
    ) internal {
        uint96 providerShare = reservation.providerShare;
        uint96 treasuryShare = reservation.projectTreasuryShare;
        uint96 subsidiesShare = reservation.subsidiesShare;
        uint96 governanceShare = reservation.governanceShare;

        if (providerShare > 0) {
            s.pendingProviderPayout[reservation.labId] += providerShare;
            _updatePendingProviderTimestamp(s, reservation.labId, reservation.end);
        }
        if (treasuryShare > 0) s.pendingProjectTreasury += treasuryShare;
        if (subsidiesShare > 0) s.pendingSubsidies += subsidiesShare;
        if (governanceShare > 0) s.pendingGovernance += governanceShare;
    }

    function _calculateRevenueSplit(
        uint96 price
    )
        internal
        pure
        returns (uint96 providerShare, uint96 treasuryShare, uint96 subsidiesShare, uint96 governanceShare)
    {
        return LibRevenue.calculateRevenueSplit(price);
    }

    function _setReservationSplit(
        Reservation storage reservation
    ) internal {
        (uint96 providerShare, uint96 treasuryShare, uint96 subsidiesShare, uint96 governanceShare) =
            LibRevenue.calculateRevenueSplit(reservation.price);
        reservation.providerShare = providerShare;
        reservation.projectTreasuryShare = treasuryShare;
        reservation.subsidiesShare = subsidiesShare;
        reservation.governanceShare = governanceShare;
    }

    function _computeCancellationFee(
        uint96 price
    ) internal pure returns (uint96 providerFee, uint96 treasuryFee, uint96 governanceFee, uint96 refundAmount) {
        return LibRevenue.computeCancellationFee(price);
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
            _updatePendingProviderTimestamp(s, labId, block.timestamp);
        }
        if (treasuryFee > 0) s.pendingProjectTreasury += treasuryFee;
        if (governanceFee > 0) s.pendingGovernance += governanceFee;
    }

    function _enqueuePayoutCandidate(
        AppStorage storage s,
        uint256 labId,
        bytes32 key,
        uint32 end
    ) internal {
        LibHeap.enqueuePayoutCandidate(s, labId, key, end);
    }

    function _popEligiblePayoutCandidate(
        AppStorage storage s,
        uint256 labId,
        uint256 currentTime
    ) internal returns (bytes32) {
        return LibHeap.popEligiblePayoutCandidate(s, labId, currentTime);
    }
}
