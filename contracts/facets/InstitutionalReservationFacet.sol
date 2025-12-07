// SPDX-License-Identifier: GPL-3.0-or-later
pragma solidity ^0.8.23;

import {EnumerableSet} from "@openzeppelin/contracts/utils/structs/EnumerableSet.sol";
import {IERC721} from "@openzeppelin/contracts/token/ERC721/IERC721.sol";
import {ReentrancyGuard} from "@openzeppelin/contracts/security/ReentrancyGuard.sol";
import {BaseReservationFacet, IStakingFacet, IInstitutionalTreasuryFacet} from "./ReservationFacet.sol";
import {LibAppStorage, AppStorage, Reservation, INSTITUTION_ROLE} from "../libraries/LibAppStorage.sol";
import {RivalIntervalTreeLibrary, Tree} from "../libraries/RivalIntervalTreeLibrary.sol";
import {LibIntent} from "../libraries/LibIntent.sol";
import {ReservationIntentPayload, ActionIntentPayload} from "../libraries/IntentTypes.sol";
import {ReservableToken} from "../abstracts/ReservableToken.sol";

/// @title InstitutionalReservationFacet
/// @author
/// - Luis de la Torre Cubillo
/// - Juan Luis Ramos Villalón
/// @dev Facet contract to manage institutional reservations
/// @notice Provides functions to handle institutional reservation requests, 
/// confirmations, denials, cancellations, and expired reservation releases.

contract InstitutionalReservationFacet is BaseReservationFacet, ReentrancyGuard {
    using EnumerableSet for EnumerableSet.Bytes32Set;
    using EnumerableSet for EnumerableSet.AddressSet;
    using RivalIntervalTreeLibrary for Tree;

    struct InstReservationInput {
        address provider;
        address labOwner;
        uint256 labId;
        uint32 startTime;
        uint32 endTime;
        string puc;
        bytes32 reservationKey;
        address userTrackingKey;
    }

    /// @notice Event of institutional intents (creation/cancellation)
    event ReservationIntentProcessed(bytes32 indexed requestId, bytes32 reservationKey, string action, string puc, address institution, bool success, string reason);

    /// @dev Consumes a reservation intent ensuring caller matches signer/executor
    function _consumeReservationIntent(
        bytes32 requestId,
        uint8 action,
        ReservationIntentPayload memory payload
    ) internal {
        require(payload.executor == msg.sender, "Executor must be caller");
        bytes32 payloadHash = LibIntent.hashReservationPayload(payload);
        LibIntent.consumeIntent(requestId, action, payloadHash, msg.sender);
    }

    /// @dev Consumes an action intent (for booking cancellations)
    function _consumeActionIntent(
        bytes32 requestId,
        uint8 action,
        ActionIntentPayload memory payload
    ) internal {
        require(payload.executor == msg.sender, "Executor must be caller");
        bytes32 payloadHash = LibIntent.hashActionPayload(payload);
        LibIntent.consumeIntent(requestId, action, payloadHash, msg.sender);
    }

    function _consumeInstitutionalRequestIntent(
        bytes32 requestId,
        string calldata puc,
        uint256 labId,
        uint32 start,
        uint32 end
    ) internal returns (bytes32 reservationKey) {
        reservationKey = _getReservationKey(labId, start);
        uint96 price = _s().labs[labId].price;

        ReservationIntentPayload memory payload;
        payload.executor = msg.sender;
        payload.schacHomeOrganization = "";
        payload.puc = puc;
        payload.assertionHash = bytes32(0);
        payload.labId = labId;
        payload.start = start;
        payload.end = end;
        payload.price = price;
        payload.reservationKey = reservationKey;
        _consumeReservationIntent(requestId, LibIntent.ACTION_REQUEST_BOOKING, payload);
    }

    /// @notice Institutional reservation request via intent (emits ReservationIntentProcessed)
    function institutionalReservationRequestWithIntent(
        bytes32 requestId,
        address institutionalProvider,
        string calldata puc,
        uint256 _labId,
        uint32 _start,
        uint32 _end
    ) external exists(_labId) onlyInstitution(institutionalProvider) {
        require(institutionalProvider == msg.sender, "Institution must be caller");
        bytes32 reservationKey = _consumeInstitutionalRequestIntent(
            requestId,
            puc,
            _labId,
            _start,
            _end
        );

        _institutionalReservationRequest(institutionalProvider, puc, _labId, _start, _end);
        emit ReservationIntentProcessed(requestId, reservationKey, "RESERVATION_REQUEST", puc, institutionalProvider, true, "");
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
        require(institutionalProvider == msg.sender, "Institution must be caller");
        AppStorage storage s = _s();
        Reservation storage reservation = s.reservations[_reservationKey];
        require(reservation.labId != 0, "Unknown reservation");

        ReservationIntentPayload memory payload = ReservationIntentPayload({
            executor: msg.sender,
            schacHomeOrganization: "",
            puc: puc,
            assertionHash: bytes32(0),
            labId: reservation.labId,
            start: reservation.start,
            end: reservation.end,
            price: reservation.price,
            reservationKey: _reservationKey
        });
        _consumeReservationIntent(requestId, LibIntent.ACTION_CANCEL_REQUEST_BOOKING, payload);

        _cancelInstitutionalReservationRequest(institutionalProvider, puc, _reservationKey);
        emit ReservationIntentProcessed(requestId, _reservationKey, "CANCEL_RESERVATION_REQUEST", puc, institutionalProvider, true, "");
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
        require(institutionalProvider == msg.sender, "Institution must be caller");
        AppStorage storage s = _s();
        Reservation storage reservation = s.reservations[_reservationKey];
        require(reservation.labId != 0, "Unknown reservation");

        ActionIntentPayload memory payload = ActionIntentPayload({
            executor: msg.sender,
            schacHomeOrganization: "",
            puc: reservation.puc,
            assertionHash: bytes32(0),
            labId: reservation.labId,
            reservationKey: _reservationKey,
            uri: "",
            price: reservation.price,
            maxBatch: 0,
            auth: "",
            accessURI: "",
            accessKey: "",
            tokenURI: ""
        });
        _consumeActionIntent(requestId, LibIntent.ACTION_CANCEL_BOOKING, payload);

        _cancelInstitutionalBooking(institutionalProvider, _reservationKey);
        emit ReservationIntentProcessed(requestId, _reservationKey, "CANCEL_BOOKING", reservation.puc, institutionalProvider, true, "");
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

        return _releaseInstitutionalExpiredReservations(institutionalProvider, puc, _labId, maxBatch);
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
        _onlyInstitution(institution);
        _;
    }

    function _onlyInstitution(address institution) internal view {
        AppStorage storage s = _s();
        require(s.roleMembers[INSTITUTION_ROLE].contains(institution), "Unknown institution");
        address backend = s.institutionalBackends[institution];
        require(msg.sender == institution || (backend != address(0) && msg.sender == backend), "Not authorized institution");
    }

    /// @dev Verifies that caller is the lab owner or authorized backend for institutional labs
    function _requireLabProviderOrBackend(bytes32 _reservationKey) internal view {
        AppStorage storage s = _s();
        Reservation storage reservation = s.reservations[_reservationKey];
        require(reservation.labId != 0, "Unknown reservation");
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
        (address labOwner, bytes32 reservationKey, address userTrackingKey) = _validateInstitutionalRequest(
            s,
            institutionalProvider,
            puc,
            _labId,
            _start,
            _end
        );

        InstReservationInput memory input = InstReservationInput({
            provider: institutionalProvider,
            labOwner: labOwner,
            labId: _labId,
            startTime: _start,
            endTime: _end,
            puc: puc,
            reservationKey: reservationKey,
            userTrackingKey: userTrackingKey
        });

        _createInstitutionalReservation(s, input);
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
        if (maxBatch == 0 || maxBatch > 50) revert("Invalid batch size");
        if (bytes(puc).length == 0) revert("PUC cannot be empty");
        address userTrackingKey = _trackingKeyFromInstitution(institutionalProvider, puc);
        return _releaseExpiredReservationsInternal(_labId, userTrackingKey, maxBatch);
    }

    function _resolveRequestWindow(AppStorage storage s, address provider)
        internal
        view
        returns (uint64 start, uint64 duration)
    {
        uint256 rawDuration = _resolveSpendingPeriod(s, provider);
        // forge-lint: disable-next-line(unsafe-typecast)
        duration = uint64(rawDuration);
        // forge-lint: disable-next-line(divide-before-multiply)
        uint256 computedStart = (block.timestamp / rawDuration) * rawDuration;
        // forge-lint: disable-next-line(unsafe-typecast)
        start = uint64(computedStart);
    }

    function _validateInstitutionalRequest(
        AppStorage storage s,
        address institutionalProvider,
        string calldata puc,
        uint256 labId,
        uint32 startTime,
        uint32 endTime
    ) internal returns (address labOwner, bytes32 reservationKey, address userTrackingKey) {
        require(s.institutionalBackends[institutionalProvider] != address(0), "No authorized backend");
        require(msg.sender == s.institutionalBackends[institutionalProvider], "Caller must be authorized backend");

        require(bytes(puc).length > 0, "PUC cannot be empty");
        require(bytes(puc).length <= 256, "PUC too long");

        if (!s.tokenStatus[labId]) revert("Lab not listed for reservations");

        labOwner = IERC721(address(this)).ownerOf(labId);
        if (
            s.providerStakes[labOwner].stakedAmount <
            ReservableToken(address(this)).calculateRequiredStake(labOwner, s.providerStakes[labOwner].listedLabsCount)
        ) {
            revert("Lab provider does not have sufficient stake");
        }

        if (startTime >= endTime || startTime <= block.timestamp + RESERVATION_MARGIN) {
            revert("Invalid time range");
        }

        reservationKey = _getReservationKey(labId, startTime);
        userTrackingKey = _trackingKeyFromInstitution(institutionalProvider, puc);

        uint256 userActiveCount = s.activeReservationCountByTokenAndUser[labId][userTrackingKey];
        if (userActiveCount >= MAX_RESERVATIONS_PER_LAB_USER - 2) {
            _releaseExpiredReservationsInternal(labId, userTrackingKey, MAX_RESERVATIONS_PER_LAB_USER);
            userActiveCount = s.activeReservationCountByTokenAndUser[labId][userTrackingKey];
        }
        if (userActiveCount >= MAX_RESERVATIONS_PER_LAB_USER) revert MaxReservationsReached();

        Reservation storage existing = s.reservations[reservationKey];
        if (existing.renter != address(0) && existing.status != CANCELLED && existing.status != COLLECTED) {
            revert("Not available");
        }
    }

    function _createInstitutionalReservation(
        AppStorage storage s,
        InstReservationInput memory input
    ) internal {
        bool hasBackendCollector = s.institutionalBackends[input.labOwner] != address(0);
        address collectorInstitution = hasBackendCollector ? input.labOwner : address(0);
        uint96 chargeAmount = (hasBackendCollector && input.provider == input.labOwner)
            ? 0
            : s.labs[input.labId].price;

        if (chargeAmount > 0) {
            IInstitutionalTreasuryFacet(address(this)).checkInstitutionalTreasuryAvailability(
                input.provider,
                input.puc,
                chargeAmount
            );
        }

        (uint64 requestPeriodStart, uint64 requestPeriodDuration) = _resolveRequestWindow(s, input.provider);

        s.reservationKeysByToken[input.labId].add(input.reservationKey);
        s.reservations[input.reservationKey] = Reservation({
            labId: input.labId,
            renter: input.provider,
            labProvider: input.labOwner,
            price: chargeAmount,
            start: input.startTime,
            end: input.endTime,
            status: PENDING,
            puc: input.puc,
            requestPeriodStart: requestPeriodStart,
            requestPeriodDuration: requestPeriodDuration,
            payerInstitution: input.provider,
            collectorInstitution: collectorInstitution,
            providerShare: 0,
            projectTreasuryShare: 0,
            subsidiesShare: 0,
            governanceShare: 0
        });

        s.totalReservationsCount++;
        s.renters[input.provider].add(input.reservationKey);
        s.renters[input.userTrackingKey].add(input.reservationKey);
        s.activeReservationCountByTokenAndUser[input.labId][input.userTrackingKey]++;
        s.reservationKeysByTokenAndUser[input.labId][input.userTrackingKey].add(input.reservationKey);

        _recordRecent(s, input.labId, input.userTrackingKey, input.reservationKey, input.startTime);

        emit ReservationRequested(input.provider, input.labId, input.startTime, input.endTime, input.reservationKey);
    }

    /// @dev Get count of reservations for an institutional user (internal)
    function _getInstitutionalUserReservationCount(
        address institutionalProvider,
        string calldata puc
    ) internal view override returns (uint256) {
        AppStorage storage s = _s();
        address userTrackingKey = _trackingKeyFromInstitution(institutionalProvider, puc);
        return s.renters[userTrackingKey].length();
    }

    /// @dev Get reservation key by index for an institutional user (internal)
    /// @notice Order is NOT guaranteed stable across mutations. Use for snapshot iteration only.
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

    // Wallet-only hooks required by BaseReservationFacet but unused here
    function _reservationRequest(uint256, uint32, uint32) internal pure override { revert("Wallet reservation only"); }

    function _confirmReservationRequest(bytes32) internal pure override { revert("Wallet reservation only"); }

    function _denyReservationRequest(bytes32) internal pure override { revert("Wallet reservation only"); }

    function _cancelReservationRequest(bytes32) internal pure override { revert("Wallet reservation only"); }

    function _cancelBooking(bytes32) internal pure override { revert("Wallet reservation only"); }

    function _requestFunds(uint256, uint256) internal pure override { revert("Wallet reservation only"); }

    function _getLabTokenAddress() internal pure override returns (address) { return address(0); }

    function _getSafeBalance() internal pure override returns (uint256) { return 0; }

    function _releaseExpiredReservations(uint256, address, uint256) internal pure override returns (uint256) { return 0; }

    function _resolveSpendingPeriod(AppStorage storage s, address provider) private view returns (uint256) {
        uint256 duration = s.institutionalSpendingPeriod[provider];
        return duration == 0 ? LibAppStorage.DEFAULT_SPENDING_PERIOD : duration;
    }

}
