// SPDX-License-Identifier: GPL-3.0-or-later
pragma solidity ^0.8.23;

import {EnumerableSet} from "@openzeppelin/contracts/utils/structs/EnumerableSet.sol";
import {IERC721} from "@openzeppelin/contracts/token/ERC721/IERC721.sol";
import {ReentrancyGuard} from "@openzeppelin/contracts/security/ReentrancyGuard.sol";
import "./ReservationFacet.sol";
import "../libraries/LibAppStorage.sol";

/// @title InstitutionalReservationFacet
/// @author
/// - Luis de la Torre Cubillo
/// - Juan Luis Ramos Villalón
/// @dev Facet contract to manage institutional reservations
/// @notice Provides functions to handle institutional reservation requests, 
/// confirmations, denials, cancellations, and expired reservation releases.

contract InstitutionalReservationFacet is BaseReservationFacet, ReentrancyGuard {
    using EnumerableSet for EnumerableSet.Bytes32Set;

    /// @notice Event of institutional intents (creation/cancellation)
    event ReservationIntentProcessed(bytes32 indexed requestId, bytes32 reservationKey, string action, address institution, bool success, string reason);

    /// @notice Institutional reservation request via intent (emits ReservationIntentProcessed)
    function institutionalReservationRequestWithIntent(
        bytes32 requestId,
        address institutionalProvider,
        string calldata puc,
        uint256 _labId,
        uint32 _start,
        uint32 _end
    ) external exists(_labId) onlyInstitution(institutionalProvider) {
        bytes32 reservationKey = _getReservationKey(_labId, _start);
        _institutionalReservationRequest(institutionalProvider, puc, _labId, _start, _end);
        emit ReservationIntentProcessed(requestId, reservationKey, "RESERVATION_REQUEST", institutionalProvider, true, "");
    }
    
    function institutionalReservationRequest(
        address institutionalProvider,
        string calldata puc,
        uint256 _labId,
        uint32 _start,
        uint32 _end
    ) external exists(_labId) onlyInstitution(institutionalProvider) {
        _institutionalReservationRequest(institutionalProvider, puc, _labId, _start, _end);
    }

    function confirmInstitutionalReservationRequest(
        address institutionalProvider,
        bytes32 _reservationKey
    ) external reservationPending(_reservationKey) onlyInstitution(institutionalProvider) {
        // Only lab provider (owner or authorized backend) can confirm
        _requireLabProviderOrBackend(_reservationKey);
        _confirmInstitutionalReservationRequest(institutionalProvider, _reservationKey);
    }

    function denyInstitutionalReservationRequest(
        address institutionalProvider,
        string calldata puc,
        bytes32 _reservationKey
    ) external onlyInstitution(institutionalProvider) {
        // Only lab provider (owner or authorized backend) can deny
        _requireLabProviderOrBackend(_reservationKey);
        _denyInstitutionalReservationRequest(institutionalProvider, puc, _reservationKey);
    }

    /// @notice Institutional cancellation via intent (emits ReservationIntentProcessed)
    function cancelInstitutionalReservationRequestWithIntent(
        bytes32 requestId,
        address institutionalProvider,
        string calldata puc,
        bytes32 _reservationKey
    ) external onlyInstitution(institutionalProvider) {
        _cancelInstitutionalReservationRequest(institutionalProvider, puc, _reservationKey);
        emit ReservationIntentProcessed(requestId, _reservationKey, "CANCEL_RESERVATION_REQUEST", institutionalProvider, true, "");
    }

    function cancelInstitutionalReservationRequest(
        address institutionalProvider,
        string calldata puc,
        bytes32 _reservationKey
    ) external onlyInstitution(institutionalProvider) {
        _cancelInstitutionalReservationRequest(institutionalProvider, puc, _reservationKey);
    }

    /// @notice  Cancels a confirmed booking via intent and emits ReservationIntentProcessed
    function cancelInstitutionalBookingWithIntent(
        bytes32 requestId,
        address institutionalProvider,
        bytes32 _reservationKey
    ) external onlyInstitution(institutionalProvider) {
        _cancelInstitutionalBooking(institutionalProvider, _reservationKey);
        emit ReservationIntentProcessed(requestId, _reservationKey, "CANCEL_BOOKING", institutionalProvider, true, "");
    }

    function cancelInstitutionalBooking(
        address institutionalProvider,
        bytes32 _reservationKey
    ) external onlyInstitution(institutionalProvider) {
        _cancelInstitutionalBooking(institutionalProvider, _reservationKey);
    }

    function releaseInstitutionalExpiredReservations(
        address institutionalProvider,
        string calldata puc,
        uint256 _labId,
        uint256 maxBatch
    ) external onlyInstitution(institutionalProvider) returns (uint256 processed) {
        AppStorage storage s = _s();

        require(s.institutionalBackends[institutionalProvider] != address(0), "No authorized backend");
        require(msg.sender == s.institutionalBackends[institutionalProvider], "Not authorized backend");
        require(bytes(puc).length > 0, "PUC cannot be empty");

        address userTrackingKey = _trackingKeyFromInstitution(institutionalProvider, puc);
        return _releaseInstitutionalExpiredReservations(institutionalProvider, puc, _labId, maxBatch, userTrackingKey);
    }

    function getInstitutionalUserReservationCount(
        address institutionalProvider,
        string calldata puc
    ) external view onlyInstitution(institutionalProvider) returns (uint256) {
        return _getInstitutionalUserReservationCount(institutionalProvider, puc);
    }

    function getInstitutionalUserReservationByIndex(
        address institutionalProvider,
        string calldata puc,
        uint256 index
    ) external view onlyInstitution(institutionalProvider) returns (bytes32 key) {
        return _getInstitutionalUserReservationByIndex(institutionalProvider, puc, index);
    }

    function hasInstitutionalUserActiveBooking(
        address institutionalProvider,
        string calldata puc,
        uint256 labId
    ) external onlyInstitution(institutionalProvider) returns (bool) {
        return _hasInstitutionalUserActiveBooking(institutionalProvider, puc, labId);
    }

    function getInstitutionalUserActiveReservationKey(
        address institutionalProvider,
        string calldata puc,
        uint256 labId
    ) external onlyInstitution(institutionalProvider) returns (bytes32 reservationKey) {
        return _getInstitutionalUserActiveReservationKey(institutionalProvider, puc, labId);
    }

    // ---------------------------------------------------------------------
    // Institutional overrides
    // ---------------------------------------------------------------------

    modifier onlyInstitution(address institution) {
        AppStorage storage s = _s();
        require(s.roleMembers[INSTITUTION_ROLE].contains(institution), "Unknown institution");
        _;
    }

    /// @dev Verifies that caller is the lab owner or authorized backend for institutional labs
    function _requireLabProviderOrBackend(bytes32 _reservationKey) internal view {
        AppStorage storage s = _s();
        Reservation storage reservation = s.reservations[_reservationKey];
        address labOwner = IERC721(address(this)).ownerOf(reservation.labId);
        address authorizedBackend = s.institutionalBackends[labOwner];
        
        require(
            msg.sender == labOwner || (authorizedBackend != address(0) && msg.sender == authorizedBackend),
            "Only lab provider or authorized backend"
        );
    }

    function _institutionalReservationRequest(
        address institutionalProvider,
        string calldata puc,
        uint256 _labId,
        uint32 _start,
        uint32 _end
    ) internal override {
        AppStorage storage s = _s();

        require(s.institutionalBackends[institutionalProvider] != address(0), "No authorized backend");
        require(msg.sender == s.institutionalBackends[institutionalProvider], "Caller must be authorized backend");

        require(bytes(puc).length > 0, "PUC cannot be empty");
        require(bytes(puc).length <= 256, "PUC too long");

        if (!s.tokenStatus[_labId]) revert("Lab not listed for reservations");

        address labOwner = IERC721(address(this)).ownerOf(_labId);
        uint256 listedLabsCount = s.providerStakes[labOwner].listedLabsCount;
        uint256 requiredStake = ReservableToken(address(this)).calculateRequiredStake(labOwner, listedLabsCount);
        if (s.providerStakes[labOwner].stakedAmount < requiredStake) {
            revert("Lab provider does not have sufficient stake");
        }

        if (_start >= _end || _start <= block.timestamp + RESERVATION_MARGIN) {
            revert("Invalid time range");
        }

        uint96 price = s.labs[_labId].price;
        bytes32 reservationKey = _getReservationKey(_labId, _start);
        address userTrackingKey = _trackingKeyFromInstitution(institutionalProvider, puc);

        uint256 userActiveCount = s.activeReservationCountByTokenAndUser[_labId][userTrackingKey];
        if (userActiveCount >= MAX_RESERVATIONS_PER_LAB_USER - 2) {
            _releaseExpiredReservationsInternal(_labId, userTrackingKey, MAX_RESERVATIONS_PER_LAB_USER);
            userActiveCount = s.activeReservationCountByTokenAndUser[_labId][userTrackingKey];
        }
        if (userActiveCount >= MAX_RESERVATIONS_PER_LAB_USER) revert MaxReservationsReached();

        if (s.reservationKeys.contains(reservationKey)) {
            revert("Not available");
        }

        address collectorInstitution = address(0);
        if (s.institutionalBackends[labOwner] != address(0)) {
            collectorInstitution = labOwner;
        }

        uint96 chargeAmount = price;
        if (institutionalProvider == collectorInstitution) {
            chargeAmount = 0;
        }

        if (chargeAmount > 0) {
            IInstitutionalTreasuryFacet(address(this)).checkInstitutionalTreasuryAvailability(
                institutionalProvider,
                puc,
                chargeAmount
            );
        }

        uint256 periodDuration = _resolveSpendingPeriod(s, institutionalProvider);
        uint256 currentPeriodStart = (block.timestamp / periodDuration) * periodDuration;
        require(periodDuration <= type(uint64).max, "Spending period too long");
        require(currentPeriodStart <= type(uint64).max, "Timestamp overflow");

        uint64 requestPeriodDuration = uint64(periodDuration);
        uint64 requestPeriodStart = uint64(currentPeriodStart);

        s.reservationKeysByToken[_labId].add(reservationKey);
        s.reservations[reservationKey] = Reservation({
            labId: _labId,
            renter: institutionalProvider,
            labProvider: labOwner,
            price: chargeAmount,
            start: _start,
            end: _end,
            status: PENDING,
            puc: puc,
            requestPeriodStart: requestPeriodStart,
            requestPeriodDuration: requestPeriodDuration,
            payerInstitution: institutionalProvider,
            collectorInstitution: collectorInstitution
        });

        s.reservationKeys.add(reservationKey);
        s.renters[institutionalProvider].add(reservationKey);
        s.renters[userTrackingKey].add(reservationKey);
        s.activeReservationCountByTokenAndUser[_labId][userTrackingKey]++;
        s.reservationKeysByTokenAndUser[_labId][userTrackingKey].add(reservationKey);

        emit ReservationRequested(institutionalProvider, _labId, _start, _end, reservationKey);
    }

    function _confirmInstitutionalReservationRequest(
        address institutionalProvider,
        bytes32 _reservationKey
    ) internal override {
        AppStorage storage s = _s();
        Reservation storage reservation = s.reservations[_reservationKey];
        if (reservation.payerInstitution != institutionalProvider) revert("Not institutional");
        if (bytes(reservation.puc).length == 0) revert("Not institutional reservation");

        address userTrackingKey = _trackingKeyFromInstitution(institutionalProvider, reservation.puc);
        address labProvider = IERC721(address(this)).ownerOf(reservation.labId);
        reservation.labProvider = labProvider;

        if (!_providerCanFulfill(s, labProvider, reservation.labId)) {
            _cancelReservation(_reservationKey);
            emit ReservationRequestDenied(_reservationKey, reservation.labId);
            return;
        }

        reservation.collectorInstitution = s.institutionalBackends[labProvider] != address(0) ? labProvider : address(0);

        uint256 requestStart = reservation.requestPeriodStart;
        uint256 requestDuration = reservation.requestPeriodDuration;
        if (requestDuration == 0) {
            requestDuration = _resolveSpendingPeriod(s, institutionalProvider);
        }
        if (block.timestamp >= requestStart + requestDuration) {
            _cancelReservation(_reservationKey);
            emit ReservationRequestDenied(_reservationKey, reservation.labId);
            return;
        }

        if (reservation.price == 0) {
            _setReservationSplit(reservation);
            s.calendars[reservation.labId].insert(reservation.start, reservation.end);

            reservation.status = CONFIRMED;
            s.reservationsProvider[labProvider].add(_reservationKey);
            s.reservationsByLabId[reservation.labId].add(_reservationKey);
            _incrementActiveReservationCounters(reservation);
            _enqueuePayoutCandidate(s, reservation.labId, _reservationKey, reservation.end);
            _enqueueInstitutionalActiveReservation(s, reservation.labId, reservation, _reservationKey);
            IStakingFacet(address(this)).updateLastReservation(labProvider);

            bytes32 currentIndexKey = s.activeReservationByTokenAndUser[reservation.labId][userTrackingKey];

            if (currentIndexKey == bytes32(0)) {
                s.activeReservationByTokenAndUser[reservation.labId][userTrackingKey] = _reservationKey;
            } else {
                Reservation memory currentReservation = s.reservations[currentIndexKey];
                if (reservation.start < currentReservation.start) {
                    s.activeReservationByTokenAndUser[reservation.labId][userTrackingKey] = _reservationKey;
                }
            }

            emit ReservationConfirmed(_reservationKey, reservation.labId);
            return;
        }

        try IInstitutionalTreasuryFacet(address(this)).spendFromInstitutionalTreasury(
            reservation.payerInstitution,
            reservation.puc,
            reservation.price
        ) {
            _setReservationSplit(reservation);
            s.calendars[reservation.labId].insert(reservation.start, reservation.end);
            reservation.status = CONFIRMED;
            s.reservationsProvider[labProvider].add(_reservationKey);
            s.reservationsByLabId[reservation.labId].add(_reservationKey);
            _incrementActiveReservationCounters(reservation);
            _enqueuePayoutCandidate(s, reservation.labId, _reservationKey, reservation.end);
            _enqueueInstitutionalActiveReservation(s, reservation.labId, reservation, _reservationKey);

            IStakingFacet(address(this)).updateLastReservation(labProvider);

            bytes32 currentIndexKey = s.activeReservationByTokenAndUser[reservation.labId][userTrackingKey];
            if (currentIndexKey == bytes32(0)) {
                s.activeReservationByTokenAndUser[reservation.labId][userTrackingKey] = _reservationKey;
            } else {
                Reservation memory currentReservation = s.reservations[currentIndexKey];
                if (reservation.start < currentReservation.start) {
                    s.activeReservationByTokenAndUser[reservation.labId][userTrackingKey] = _reservationKey;
                }
            }

            emit ReservationConfirmed(_reservationKey, reservation.labId);
        } catch {
            _cancelReservation(_reservationKey);
            emit ReservationRequestDenied(_reservationKey, reservation.labId);
        }
    }

    function _denyInstitutionalReservationRequest(
        address institutionalProvider,
        string calldata puc,
        bytes32 _reservationKey
    ) internal override {
        AppStorage storage s = _s();
        Reservation storage reservation = s.reservations[_reservationKey];
        if (reservation.status != PENDING) revert("Not pending");
        if (reservation.payerInstitution != institutionalProvider) revert("Not institutional");
        if (keccak256(bytes(puc)) != keccak256(bytes(reservation.puc))) revert("PUC mismatch");

        _cancelReservation(_reservationKey);
        emit ReservationRequestDenied(_reservationKey, reservation.labId);
    }

    function _cancelInstitutionalReservationRequest(
        address institutionalProvider,
        string calldata puc,
        bytes32 _reservationKey
    ) internal override {
        AppStorage storage s = _s();
        require(s.institutionalBackends[institutionalProvider] != address(0), "No authorized backend");
        require(msg.sender == s.institutionalBackends[institutionalProvider], "Not authorized backend");

        Reservation storage reservation = s.reservations[_reservationKey];
        if (reservation.renter == address(0)) revert("Not found");
        if (reservation.payerInstitution != institutionalProvider) revert("Not renter");
        if (reservation.status != PENDING) revert("Not pending");
        if (keccak256(bytes(puc)) != keccak256(bytes(reservation.puc))) revert("PUC mismatch");

        _cancelReservation(_reservationKey);
        emit ReservationRequestCanceled(_reservationKey, reservation.labId);
    }

    function _cancelInstitutionalBooking(
        address institutionalProvider,
        bytes32 _reservationKey
    ) internal override {
        AppStorage storage s = _s();
        require(s.institutionalBackends[institutionalProvider] != address(0), "No authorized backend");
        require(msg.sender == s.institutionalBackends[institutionalProvider], "Not authorized backend");

        Reservation storage reservation = s.reservations[_reservationKey];
        if (reservation.renter == address(0) || (reservation.status != CONFIRMED && reservation.status != IN_USE)) {
            revert("Invalid");
        }
        if (reservation.payerInstitution != institutionalProvider) revert("Not renter");
        uint96 price = reservation.price;
        uint96 providerFee;
        uint96 treasuryFee;
        uint96 governanceFee;
        uint96 refundAmount = price;

        if (price > 0) {
            (providerFee, treasuryFee, governanceFee, refundAmount) = _computeCancellationFee(price);
        }

        address labProvider = reservation.labProvider;
        s.reservationsProvider[labProvider].remove(_reservationKey);
        s.reservationsByLabId[reservation.labId].remove(_reservationKey);
        _cancelReservation(_reservationKey);

        if (price > 0) {
            _applyCancellationFees(s, reservation.labId, providerFee, treasuryFee, governanceFee);
        }

        IInstitutionalTreasuryFacet(address(this)).refundToInstitutionalTreasury(
            reservation.payerInstitution,
            reservation.puc,
            refundAmount
        );

        emit BookingCanceled(_reservationKey, reservation.labId);
    }

    function _releaseInstitutionalExpiredReservations(
        address institutionalProvider,
        string calldata puc,
        uint256 _labId,
        uint256 maxBatch
    ) internal override returns (uint256) {
        AppStorage storage s = _s();
        if (maxBatch == 0 || maxBatch > 50) revert("Invalid batch size");
        if (bytes(puc).length == 0) revert("PUC cannot be empty");
        address userTrackingKey = _trackingKeyFromInstitution(institutionalProvider, puc);
        return _releaseExpiredReservationsInternal(_labId, userTrackingKey, maxBatch);
    }

    function _getInstitutionalUserReservationCount(
        address institutionalProvider,
        string calldata puc
    ) internal view override returns (uint256) {
        AppStorage storage s = _s();
        address userTrackingKey = _trackingKeyFromInstitution(institutionalProvider, puc);
        return s.renters[userTrackingKey].length();
    }

    function _getInstitutionalUserReservationByIndex(
        address institutionalProvider,
        string calldata puc,
        uint256 index
    ) internal view override returns (bytes32) {
        AppStorage storage s = _s();
        address userTrackingKey = _trackingKeyFromInstitution(institutionalProvider, puc);
        EnumerableSet.Bytes32Set storage userReservations = s.renters[userTrackingKey];
        if (index >= userReservations.length()) revert("Index out of bounds");
        return userReservations.at(index);
    }

    function _hasInstitutionalUserActiveBooking(
        address institutionalProvider,
        string calldata puc,
        uint256 labId
    ) internal override returns (bool) {
        require(bytes(puc).length > 0, "PUC cannot be empty");

        AppStorage storage s = _s();
        address userTrackingKey = _trackingKeyFromInstitution(institutionalProvider, puc);
        bytes32 reservationKey = _peekActiveReservation(s, labId, userTrackingKey);
        if (reservationKey == bytes32(0)) {
            return false;
        }

        Reservation storage reservation = s.reservations[reservationKey];
        uint32 time = uint32(block.timestamp);
        return (reservation.status == CONFIRMED || reservation.status == IN_USE)
            && reservation.start <= time
            && reservation.end >= time;
    }

    function _getInstitutionalUserActiveReservationKey(
        address institutionalProvider,
        string calldata puc,
        uint256 labId
    ) internal override returns (bytes32) {
        require(bytes(puc).length > 0, "PUC cannot be empty");

        AppStorage storage s = _s();
        address userTrackingKey = _trackingKeyFromInstitution(institutionalProvider, puc);
        bytes32 activeKey = _peekActiveReservation(s, labId, userTrackingKey);
        if (activeKey == bytes32(0)) {
            return bytes32(0);
        }

        Reservation storage reservation = s.reservations[activeKey];
        uint32 time = uint32(block.timestamp);
        if (
            (reservation.status == CONFIRMED || reservation.status == IN_USE)
                && reservation.start <= time
                && reservation.end >= time
        ) {
            return activeKey;
        }

        return bytes32(0);
    }

    function _resolveSpendingPeriod(AppStorage storage s, address provider) private view returns (uint256) {
        uint256 duration = s.institutionalSpendingPeriod[provider];
        return duration == 0 ? LibAppStorage.DEFAULT_SPENDING_PERIOD : duration;
    }

}
