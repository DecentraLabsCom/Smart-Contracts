// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.33;

import "../contracts/facets/reservation/institutional/InstitutionalReservationCancellationFacet.sol";
import "../contracts/facets/reservation/institutional/InstitutionalReservationConfirmationFacet.sol";
import "../contracts/facets/reservation/institutional/InstitutionalReservationQueryFacet.sol";
import "../contracts/facets/reservation/ReservationDenialFacet.sol";
import "../contracts/libraries/LibAppStorage.sol";
import "../contracts/libraries/LibERC721Storage.sol";
import "./LibERC721StorageTestHelper.sol";
import "../contracts/libraries/LibInstitutionalReservation.sol";
import "../contracts/libraries/LibInstitutionalReservationRelease.sol";
import "../contracts/libraries/LibTracking.sol";
import "../contracts/libraries/LibLabAdmin.sol";
import "../contracts/libraries/LibCreditLedger.sol";

contract InstReservationHarness is InstitutionalReservationCancellationFacet {
    using EnumerableSet for EnumerableSet.Bytes32Set;
    using EnumerableSet for EnumerableSet.AddressSet;

    // expose helpers to set storage
    function setBackend(
        address inst,
        address backend
    ) external {
        AppStorage storage s = LibAppStorage.diamondStorage();
        s.institutionalBackends[inst] = backend;
    }

    function setLabOwner(
        uint256 labId,
        address owner
    ) external {
        LibERC721StorageTestHelper.setOwnerForTest(labId, owner);
    }

    function setLabResourceType(
        uint256 labId,
        uint8 resourceType
    ) external {
        LibAppStorage.diamondStorage().labs[labId].resourceType = resourceType;
    }

    function setInstitution(
        address inst
    ) external {
        AppStorage storage s = LibAppStorage.diamondStorage();
        s.roleMembers[INSTITUTION_ROLE].add(inst);
    }

    function setReservation(
        bytes32 key,
        address renter,
        address payerInstitution,
        uint96 price,
        uint8 status,
        uint256 labId,
        uint32 start,
        string calldata puc
    ) external {
        AppStorage storage s = LibAppStorage.diamondStorage();
        Reservation storage r = s.reservations[key];
        r.renter = renter;
        r.payerInstitution = payerInstitution;
        r.price = price;
        r.status = status;
        r.labId = labId;
        r.start = start;
        r.end = start + 3600; // default 1 hour slot for tests
        if (bytes(puc).length > 0) s.reservationPucHash[key] = keccak256(bytes(puc));

        // set the institutional request period start/duration similar to production path so confirm checks pass
        uint256 d = s.institutionalSpendingPeriod[payerInstitution];
        if (d == 0) d = LibAppStorage.DEFAULT_SPENDING_PERIOD;
        uint256 rsAligned = block.timestamp - (block.timestamp % d);
        r.requestPeriodStart = uint64(rsAligned);
        r.requestPeriodDuration = uint64(d);
    }

    function setReservationAccounting(
        bytes32 key,
        uint256 periodStart,
        uint48 sourceCreditExpiry,
        bytes32 fundingOrderId,
        uint256 allocatedAmount
    ) external {
        AppStorage storage s = LibAppStorage.diamondStorage();
        address payer = s.reservations[key].payerInstitution;
        s.institutionalReservationPeriodStartPlusOne[key] = periodStart + 1;
        s.creditReservationExpiry[payer][key] = sourceCreditExpiry;
        s.creditReservationAllocations[payer][key].push(
            CreditReservationAllocation({
                fundingOrderId: fundingOrderId,
                amount: allocatedAmount,
                refundedAmount: 0,
                eurGrossAmount: allocatedAmount,
                refundedEurGrossAmount: 0,
                expiresAt: sourceCreditExpiry,
                lotId: 0
            })
        );
    }

    function setIndexedExpiredReservation(
        bytes32 key,
        address renter,
        address payerInstitution,
        uint96 price,
        uint8 status,
        uint256 labId,
        uint32 start,
        uint32 end,
        string calldata puc
    ) external {
        AppStorage storage s = LibAppStorage.diamondStorage();
        Reservation storage r = s.reservations[key];
        r.renter = renter;
        r.payerInstitution = payerInstitution;
        r.price = price;
        r.status = status;
        r.labId = labId;
        r.start = start;
        r.end = end;
        r.labProvider = payerInstitution;
        r.providerShare = price;
        if (bytes(puc).length > 0) {
            bytes32 pucHash = keccak256(bytes(puc));
            s.reservationPucHash[key] = pucHash;
            address trackingKey = LibTracking.trackingKeyFromInstitutionHash(payerInstitution, pucHash);
            s.reservationKeysByTokenAndUser[labId][trackingKey].add(key);
            s.activeReservationCountByTokenAndUser[labId][trackingKey] += 1;
            bytes32 currentKey = s.activeReservationByTokenAndUser[labId][trackingKey];
            if (currentKey == bytes32(0) || start < s.reservations[currentKey].start) {
                s.activeReservationByTokenAndUser[labId][trackingKey] = key;
            }
        }
        s.reservationKeysByToken[labId].add(key);
        s.renters[renter].add(key);
        s.labActiveReservationCount[labId] += 1;
        s.providerActiveReservationCount[payerInstitution] += 1;
        s.totalReservationsCount += 1;
    }

    function markSessionStartedForTest(
        bytes32 reservationKey
    ) external {
        AppStorage storage s = LibAppStorage.diamondStorage();
        s.reservationSessionStartedRecorded[reservationKey] = true;
    }

    // wrappers to call the internal library functions
    function cancelReservationRequestWrapper(
        address institutionalProvider,
        bytes32 pucHash,
        bytes32 reservationKey
    ) external returns (uint256) {
        return LibInstitutionalReservation.cancelReservationRequest(institutionalProvider, pucHash, reservationKey);
    }

    function cancelBookingWrapper(
        address institutionalProvider,
        bytes32 pucHash,
        bytes32 reservationKey
    ) external returns (uint256) {
        return LibInstitutionalReservation.cancelBooking(institutionalProvider, pucHash, reservationKey);
    }

    function cancelConfirmedBookingByProviderWrapper(
        bytes32 reservationKey,
        uint8 reasonCode
    )
        external
        returns (uint256 labId, address payerInstitution, address provider, bytes32 pucHash, uint96 refundAmount)
    {
        return LibInstitutionalReservation.cancelConfirmedBookingByProvider(reservationKey, reasonCode);
    }

    function releaseInstitutionalExpiredReservationsWrapper(
        address institutionalProvider,
        bytes32 pucHash,
        uint256 labId,
        uint256 maxBatch
    ) external returns (uint256) {
        return LibInstitutionalReservationRelease.releaseInstitutionalExpiredReservations(
            institutionalProvider, pucHash, labId, maxBatch
        );
    }

    // capture refunds
    address public lastRefundProvider;
    bytes32 public lastRefundPucHash;
    bytes32 public lastRefundReservationKey;
    uint256 public lastRefundAmount;
    bytes32 public reentrantReservationKey;
    bool public reentrancyEnabled;
    bool public reentrancyTriggered;
    bool public ledgerRefundEnabled;

    function enableLedgerRefund() external {
        ledgerRefundEnabled = true;
    }

    function seedCreditReservationAtLotLimit(
        address account,
        bytes32 reservationKey,
        bytes32 sourceFundingOrder,
        uint256 sourceAmount,
        uint256 capturedAmount
    ) external {
        LibCreditLedger.mintCredits(account, sourceAmount, sourceFundingOrder, sourceAmount, 0);
        for (uint256 i = 1; i < 128; ++i) {
            LibCreditLedger.mintCredits(account, 1, bytes32(i), 0, 0);
        }
        LibCreditLedger.debitCredits(account, capturedAmount, reservationKey);
    }

    function seedCreditReservationWithAllocations(
        address account,
        bytes32 reservationKey,
        uint256 allocationCount
    ) external {
        for (uint256 i; i < allocationCount; ++i) {
            LibCreditLedger.mintCredits(account, 1, bytes32(i + 1), 0, 0);
        }
        LibCreditLedger.debitCredits(account, allocationCount, reservationKey);
        bytes32 pucHash = LibAppStorage.diamondStorage().reservationPucHash[reservationKey];
        InstitutionalUserSpending storage spending =
            LibAppStorage.diamondStorage().institutionalUserSpending[account][pucHash];
        spending.totalHistoricalSpent = allocationCount;
    }

    function creditLotCount(
        address account
    ) external view returns (uint256) {
        return LibCreditLedger.lotCount(account);
    }

    function configureReentrancy(
        bytes32 reservationKey
    ) external {
        reentrantReservationKey = reservationKey;
        reentrancyEnabled = true;
        reentrancyTriggered = false;
    }

    function refundToInstitutionalTreasuryForReservation(
        address provider,
        bytes32 pucHash,
        bytes32 reservationKey,
        uint256 amount
    ) external {
        lastRefundProvider = provider;
        lastRefundPucHash = pucHash;
        lastRefundReservationKey = reservationKey;
        lastRefundAmount = amount;

        if (ledgerRefundEnabled) {
            LibCreditLedger.cancelCredits(provider, amount, reservationKey);
            LibCreditLedger.finalizeReservationCreditAllocations(provider, reservationKey);
            InstitutionalUserSpending storage spending =
                LibAppStorage.diamondStorage().institutionalUserSpending[provider][pucHash];
            if (spending.totalHistoricalSpent >= amount) spending.totalHistoricalSpent -= amount;
        }

        if (reentrancyEnabled && !reentrancyTriggered) {
            reentrancyTriggered = true;
            this.cancelConfirmedBookingByProvider(reentrantReservationKey, 7);
        }
    }

    // helper to read reservation status from the harness storage
    function getReservationStatus(
        bytes32 key
    ) external view returns (uint8) {
        AppStorage storage s = LibAppStorage.diamondStorage();
        return s.reservations[key].status;
    }

    function getActiveReservationKey(
        uint256 labId,
        address trackingKey
    ) external view returns (bytes32) {
        return LibAppStorage.diamondStorage().activeReservationByTokenAndUser[labId][trackingKey];
    }

    function getLabReputation(
        uint256 labId
    ) external view returns (int32 score, uint32 totalEvents, uint32 ownerCancellations, uint64 lastUpdated) {
        AppStorage storage s = LibAppStorage.diamondStorage();
        LabReputation storage rep = s.labReputation[labId];
        return (rep.score, rep.totalEvents, rep.ownerCancellations, rep.lastUpdated);
    }

    function providerReceivable(
        uint256 labId
    ) external view returns (uint256) {
        return LibAppStorage.diamondStorage().providerReceivableAccrued[labId];
    }
}

contract ReservationDenialHarness is ReservationDenialFacet {
    function setOwner(
        uint256 tokenId,
        address owner
    ) external {
        LibERC721StorageTestHelper.setOwnerForTest(tokenId, owner);
    }

    function setBackend(
        address provider,
        address backend
    ) external {
        AppStorage storage s = LibAppStorage.diamondStorage();
        s.institutionalBackends[provider] = backend;
    }

    function setReservation(
        bytes32 key,
        address renter,
        uint8 status,
        uint256 labId,
        uint32 start
    ) external {
        AppStorage storage s = LibAppStorage.diamondStorage();
        Reservation storage r = s.reservations[key];
        r.renter = renter;
        r.status = status;
        r.labId = labId;
        r.start = start;
        r.end = start + 3600;
    }

    function getLabReputation(
        uint256 labId
    ) external view returns (int32 score, uint32 totalEvents, uint32 ownerCancellations, uint64 lastUpdated) {
        AppStorage storage s = LibAppStorage.diamondStorage();
        LabReputation storage rep = s.labReputation[labId];
        return (rep.score, rep.totalEvents, rep.ownerCancellations, rep.lastUpdated);
    }

    function getReservationStatus(
        bytes32 key
    ) external view returns (uint8) {
        AppStorage storage s = LibAppStorage.diamondStorage();
        return s.reservations[key].status;
    }
}

contract ConfirmHarness is InstitutionalReservationConfirmationFacet {
    // simple ERC721 ownerOf stub
    mapping(uint256 => address) public owners;

    function setOwner(
        uint256 tokenId,
        address owner
    ) external {
        owners[tokenId] = owner;
        LibERC721StorageTestHelper.setOwnerForTest(tokenId, owner);
    }

    function ownerOf(
        uint256 tokenId
    ) external view returns (address) {
        return owners[tokenId];
    }

    // expose helpers
    function setReservation(
        bytes32 key,
        address renter,
        address payerInstitution,
        uint96 price,
        uint8 status,
        uint256 labId,
        uint32 start,
        string calldata puc
    ) external {
        AppStorage storage s = LibAppStorage.diamondStorage();
        Reservation storage r = s.reservations[key];
        r.renter = renter;
        r.payerInstitution = payerInstitution;
        r.price = price;
        r.status = status;
        r.labId = labId;
        r.start = start;
        r.end = start + 3600;
        if (bytes(puc).length > 0) s.reservationPucHash[key] = keccak256(bytes(puc));

        // set the institutional request period start/duration to emulate createInstReservation alignment
        uint256 d = s.institutionalSpendingPeriod[payerInstitution];
        if (d == 0) d = LibAppStorage.DEFAULT_SPENDING_PERIOD;
        uint256 rsAligned = block.timestamp - (block.timestamp % d);
        r.requestPeriodStart = uint64(rsAligned);
        r.requestPeriodDuration = uint64(d);
    }

    function setReservationWithEnd(
        bytes32 key,
        address renter,
        address payerInstitution,
        uint96 price,
        uint8 status,
        uint256 labId,
        uint32 start,
        uint32 end,
        string calldata puc
    ) external {
        AppStorage storage s = LibAppStorage.diamondStorage();
        Reservation storage r = s.reservations[key];
        r.renter = renter;
        r.payerInstitution = payerInstitution;
        r.price = price;
        r.status = status;
        r.labId = labId;
        r.start = start;
        r.end = end;
        if (bytes(puc).length > 0) s.reservationPucHash[key] = keccak256(bytes(puc));

        uint256 d = s.institutionalSpendingPeriod[payerInstitution];
        if (d == 0) d = LibAppStorage.DEFAULT_SPENDING_PERIOD;
        uint256 rsAligned = block.timestamp - (block.timestamp % d);
        r.requestPeriodStart = uint64(rsAligned);
        r.requestPeriodDuration = uint64(d);
    }

    // for test: implement reservation-scoped treasury spend to succeed
    address public lastSpentProvider;
    bytes32 public lastSpentPucHash;
    bytes32 public lastSpentReservationKey;
    uint256 public lastSpentAmount;

    function spendFromInstitutionalTreasuryForReservation(
        address provider,
        bytes32 pucHash,
        bytes32 reservationKey,
        uint256 amount
    ) external {
        lastSpentProvider = provider;
        lastSpentPucHash = pucHash;
        lastSpentReservationKey = reservationKey;
        lastSpentAmount = amount;
        // succeed silently
    }

    // expose confirm wrapper
    function ext_confirmWithPucHash(
        address inst,
        bytes32 key,
        bytes32 pucHash
    ) external {
        // call external interface to emulate external actor
        this.confirmInstitutionalReservationRequestWithPucHash(inst, key, pucHash);
    }

    // helper to set institution role and backend
    function setInstitutionRole(
        address inst
    ) external {
        AppStorage storage s = LibAppStorage.diamondStorage();
        EnumerableSet.add(s.roleMembers[INSTITUTION_ROLE], inst);
    }

    function setBackend(
        address inst,
        address backend
    ) external {
        AppStorage storage s = LibAppStorage.diamondStorage();
        s.institutionalBackends[inst] = backend;
    }

    // helpers for test to manipulate provider and token status in the harness storage
    function setTokenStatus(
        uint256 labId,
        bool status
    ) external {
        AppStorage storage s = LibAppStorage.diamondStorage();
        s.tokenStatus[labId] = status;
    }

    function setProviderActive(
        address provider
    ) external {
        AppStorage storage s = LibAppStorage.diamondStorage();
        s.providerNetworkStatus[provider] = ProviderNetworkStatus.ACTIVE;
    }

    function getReservationStatus(
        bytes32 key
    ) external view returns (uint8) {
        AppStorage storage s = LibAppStorage.diamondStorage();
        return s.reservations[key].status;
    }

    function getReservationEnd(
        bytes32 key
    ) external view returns (uint32) {
        AppStorage storage s = LibAppStorage.diamondStorage();
        return s.reservations[key].end;
    }

    function setLabResourceType(
        uint256 labId,
        uint8 resourceType
    ) external {
        AppStorage storage s = LibAppStorage.diamondStorage();
        s.labs[labId].resourceType = resourceType;
    }
}

contract ConfirmQueryHarness is ConfirmHarness, InstitutionalReservationQueryFacet {}

contract LabAdminResourceTypeHarness {
    mapping(uint256 => address) public owners;

    function ownerOf(
        uint256 tokenId
    ) external view returns (address) {
        return owners[tokenId];
    }

    function seedLab(
        uint256 labId,
        address owner,
        uint8 resourceType,
        uint32 createdAt
    ) external {
        AppStorage storage s = LibAppStorage.diamondStorage();
        owners[labId] = owner;
        LibERC721StorageTestHelper.setOwnerForTest(labId, owner);

        if (s.activeLabIndexPlusOne[labId] == 0) {
            s.activeLabIds.push(labId);
            s.activeLabIndexPlusOne[labId] = s.activeLabIds.length;
        }

        s.labs[labId].uri = "seed-uri";
        s.labs[labId].price = 1;
        s.labs[labId].accessURI = "seed-access";
        s.labs[labId].accessKey = "seed-key";
        s.labs[labId].createdAt = createdAt;
        s.labs[labId].resourceType = resourceType;
    }

    function setActiveReservationCount(
        uint256 labId,
        uint256 count
    ) external {
        AppStorage storage s = LibAppStorage.diamondStorage();
        s.labActiveReservationCount[labId] = count;
    }

    function setPendingProviderPayout(
        uint256 labId,
        uint256 amount
    ) external {
        AppStorage storage s = LibAppStorage.diamondStorage();
        s.providerReceivableAccrued[labId] = amount;
    }

    function listLab(
        uint256 labId
    ) external {
        LibLabAdmin.listLab(labId);
    }

    function unlistLab(
        uint256 labId
    ) external {
        LibLabAdmin.unlistLab(labId);
    }

    function isListed(
        uint256 labId
    ) external view returns (bool) {
        return LibAppStorage.diamondStorage().tokenStatus[labId];
    }

    function isAcceptingNewReservations(
        uint256 labId
    ) external view returns (bool) {
        AppStorage storage s = LibAppStorage.diamondStorage();
        return s.tokenStatus[labId] && !s.labReservationIntakeStopped[labId];
    }

    function updateLab(
        uint256 labId,
        string calldata uri,
        uint96 price,
        string calldata accessUri,
        string calldata accessKey,
        uint8 resourceType
    ) external {
        LibLabAdmin.updateLab(labId, uri, price, accessUri, accessKey, resourceType);
    }

    function getLabBase(
        uint256 labId
    ) external view returns (LabBase memory) {
        AppStorage storage s = LibAppStorage.diamondStorage();
        return s.labs[labId];
    }
}
