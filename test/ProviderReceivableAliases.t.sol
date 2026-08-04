// SPDX-License-Identifier: MIT
pragma solidity ^0.8.33;

import {Test} from "forge-std/Test.sol";
import {ERC721} from "@openzeppelin/contracts/token/ERC721/ERC721.sol";
import {EnumerableSet} from "@openzeppelin/contracts/utils/structs/EnumerableSet.sol";
import {ProviderSettlementFacet} from "../contracts/facets/reservation/ProviderSettlementFacet.sol";
import {
    AppStorage,
    INSTITUTION_ROLE,
    LibAppStorage,
    PayoutCandidate,
    Reservation
} from "../contracts/libraries/LibAppStorage.sol";
import {LibAccessControlEnumerable} from "../contracts/libraries/LibAccessControlEnumerable.sol";
import {LibERC721StorageTestHelper} from "./LibERC721StorageTestHelper.sol";
import {LibInstitutionalReservationRelease} from "../contracts/libraries/LibInstitutionalReservationRelease.sol";
import {LibProviderReceivable} from "../contracts/libraries/LibProviderReceivable.sol";
import {LibTracking} from "../contracts/libraries/LibTracking.sol";
import {LibCreditLedger} from "../contracts/libraries/LibCreditLedger.sol";

contract ProviderReceivableHarness is ERC721, ProviderSettlementFacet {
    using LibAccessControlEnumerable for AppStorage;
    using EnumerableSet for EnumerableSet.AddressSet;
    using EnumerableSet for EnumerableSet.Bytes32Set;

    uint256 public lastRefundAmount;
    bool public ledgerRefundEnabled;

    constructor() ERC721("Labs", "LAB") {}

    function initialize(
        address admin,
        address provider,
        uint256 labId
    ) external {
        AppStorage storage s = LibAppStorage.diamondStorage();
        s.DEFAULT_ADMIN_ROLE = keccak256("DEFAULT_ADMIN_ROLE");
        s.roleMembers[s.DEFAULT_ADMIN_ROLE].add(admin);
        s._addProviderRole(provider, "provider", "provider@example.com", "ES", "");
        _mint(provider, labId);
        LibERC721StorageTestHelper.setOwnerForTest(labId, provider);
    }

    function setPendingProviderPayout(
        uint256 labId,
        uint256 amount
    ) external {
        AppStorage storage s = LibAppStorage.diamondStorage();
        s.providerReceivableAccrued[labId] = amount;
        s.providerReceivableAccruedScopeRoot[labId] = keccak256(abi.encode("test-pending-scope", labId, amount));
    }

    function setProviderReceivableBucket(
        uint256 labId,
        uint8 state,
        uint256 amount
    ) external {
        AppStorage storage s = LibAppStorage.diamondStorage();
        if (state == 1) {
            s.providerReceivableAccrued[labId] = amount;
            s.providerReceivableAccruedScopeRoot[labId] = keccak256(abi.encode("test-pending-scope", labId, amount));
        } else if (state == 2) {
            s.providerSettlementQueue[labId] = amount;
        } else if (state == 3) {
            s.providerReceivableInvoiced[labId] = amount;
        } else if (state == 4) {
            s.providerReceivableApproved[labId] = amount;
        } else if (state == 5) {
            s.providerReceivablePaid[labId] = amount;
        } else if (state == 6) {
            s.providerReceivableReversed[labId] = amount;
        } else if (state == 7) {
            s.providerReceivableDisputed[labId] = amount;
        } else {
            revert("invalid state");
        }
    }

    function setAuthorizedBackend(
        address institution,
        address backend
    ) external {
        AppStorage storage s = LibAppStorage.diamondStorage();
        s.institutionalBackends[institution] = backend;
    }

    function setLabResourceType(
        uint256 labId,
        uint8 resourceType
    ) external {
        LibAppStorage.diamondStorage().labs[labId].resourceType = resourceType;
    }

    function enableLedgerRefund() external {
        ledgerRefundEnabled = true;
    }

    function seedCreditReservationAtLotLimit(
        bytes32 reservationKey,
        uint256 sourceAmount,
        uint256 capturedAmount
    ) external {
        address account = LibAppStorage.diamondStorage().reservations[reservationKey].payerInstitution;
        bytes32 sourceFundingOrder = keccak256(abi.encode("payout-source", reservationKey));
        LibCreditLedger.mintCredits(account, sourceAmount, sourceFundingOrder, sourceAmount, 0);
        for (uint256 i = 1; i < 128; ++i) {
            LibCreditLedger.mintCredits(account, 1, bytes32(i), 0, 0);
        }
        LibCreditLedger.debitCredits(account, capturedAmount, reservationKey);
    }

    function creditLotCount(
        address account
    ) external view returns (uint256) {
        return LibCreditLedger.lotCount(account);
    }

    function setExpiredPayoutReservation(
        bytes32 reservationKey,
        uint256 labId,
        uint8 status,
        uint96 providerShare,
        uint32 end
    ) external {
        AppStorage storage s = LibAppStorage.diamondStorage();
        Reservation storage reservation = s.reservations[reservationKey];
        address institution = ownerOf(labId);
        bytes32 pucHash = keccak256(abi.encode(reservationKey));
        reservation.labId = labId;
        reservation.renter = address(0xCAFE);
        reservation.payerInstitution = institution;
        reservation.price = providerShare;
        reservation.labProvider = institution;
        reservation.status = status;
        reservation.start = end - 1;
        reservation.end = end;
        reservation.providerShare = providerShare;
        s.roleMembers[INSTITUTION_ROLE].add(institution);
        s.reservationPucHash[reservationKey] = pucHash;
        s.payoutHeaps[labId].push(PayoutCandidate({end: end, key: reservationKey}));
        s.payoutHeapContains[reservationKey] = true;
        s.payoutHeapIndexPlusOne[reservationKey] = s.payoutHeaps[labId].length;
        s.reservationKeysByToken[labId].add(reservationKey);
        address trackingIndex = LibTracking.trackingKeyFromInstitutionHash(institution, pucHash);
        s.reservationKeysByTokenAndUser[labId][trackingIndex].add(reservationKey);
        s.activeReservationByTokenAndUser[labId][trackingIndex] = reservationKey;
        s.activeReservationCountByTokenAndUser[labId][trackingIndex] = 1;
        s.renters[reservation.renter].add(reservationKey);
        s.totalReservationsCount += 1;
        s.labActiveReservationCount[labId] += 1;
        s.providerActiveReservationCount[reservation.labProvider] += 1;
    }

    function seedPayoutHeapEntries(
        uint256 labId,
        uint256 count
    ) external {
        AppStorage storage s = LibAppStorage.diamondStorage();
        for (uint256 i; i < count; ++i) {
            s.payoutHeaps[labId].push(
                PayoutCandidate({end: 1, key: keccak256(abi.encode("legacy-preview-cap", labId, i))})
            );
        }
    }

    function releaseInstitutionalReservation(
        bytes32 reservationKey,
        uint256 labId
    ) external returns (uint256) {
        address institution = ownerOf(labId);
        bytes32 pucHash = keccak256(abi.encode(reservationKey));
        return
            LibInstitutionalReservationRelease.releaseInstitutionalExpiredReservations(institution, pucHash, labId, 1);
    }

    function refundToInstitutionalTreasuryForReservation(
        address institution,
        bytes32,
        bytes32 reservationKey,
        uint256 amount
    ) external {
        lastRefundAmount = amount;
        if (ledgerRefundEnabled) {
            LibCreditLedger.cancelCredits(institution, amount, reservationKey);
        }
    }

    function markSessionStartedForTest(
        bytes32 reservationKey
    ) external {
        AppStorage storage s = LibAppStorage.diamondStorage();
        s.reservationSessionStartedRecorded[reservationKey] = true;
    }

    function accrueProviderReceivableForTest(
        uint256 labId,
        uint256 amount,
        bytes32 reservationId
    ) external {
        Reservation storage reservation = LibAppStorage.diamondStorage().reservations[reservationId];
        if (reservation.renter == address(0)) {
            reservation.labId = labId;
            reservation.renter = address(0xCAFE);
            reservation.status = 3;
        }
        LibProviderReceivable.accrueReceivable(labId, amount, reservationId);
    }

    function accrueProviderReceivableRawForTest(
        uint256 labId,
        uint256 amount,
        bytes32 reservationId
    ) external {
        LibProviderReceivable.accrueReceivable(labId, amount, reservationId);
    }

    function setReceivableSourceForTest(
        bytes32 reservationId,
        uint256 labId
    ) external {
        Reservation storage reservation = LibAppStorage.diamondStorage().reservations[reservationId];
        reservation.labId = labId;
        reservation.renter = address(0xCAFE);
        reservation.status = 3;
    }

    function getReservationStatus(
        bytes32 reservationKey
    ) external view returns (uint8) {
        AppStorage storage s = LibAppStorage.diamondStorage();
        return s.reservations[reservationKey].status;
    }

    function getLabReputation(
        uint256 labId
    ) external view returns (int32 score, uint32 totalEvents, uint64 lastUpdated) {
        AppStorage storage s = LibAppStorage.diamondStorage();
        score = s.labReputation[labId].score;
        totalEvents = s.labReputation[labId].totalEvents;
        lastUpdated = s.labReputation[labId].lastUpdated;
    }

    function reservationIndexCount(
        uint256 labId
    ) external view returns (uint256) {
        return LibAppStorage.diamondStorage().reservationKeysByToken[labId].length();
    }

    function totalReservations() external view returns (uint256) {
        return LibAppStorage.diamondStorage().totalReservationsCount;
    }

    function setPayoutHeapInvalidCount(
        uint256 labId,
        uint256 count
    ) external {
        LibAppStorage.diamondStorage().payoutHeapInvalidCount[labId] = count;
    }

    function payoutHeapLength(
        uint256 labId
    ) external view returns (uint256) {
        return LibAppStorage.diamondStorage().payoutHeaps[labId].length;
    }

    function updateLastReservation(
        address
    ) external {}
}

contract ProviderReceivableAliasesTest is Test {
    ProviderReceivableHarness internal harness;

    address internal constant PROVIDER = address(0xABCD);
    address internal constant BACKEND = address(0xBEEF);
    uint256 internal constant LAB_ID = 7;
    uint256 internal constant ONE_CREDIT = 10_000_000;
    uint256 internal constant FIVE_CREDITS = 50_000_000;
    uint96 internal constant FIVE_CREDITS_U96 = 50_000_000;
    uint256 internal constant SEVEN_CREDITS = 70_000_000;
    uint256 internal constant TEN_CREDITS = 100_000_000;
    uint256 internal constant ELEVEN_CREDITS = 110_000_000;
    uint256 internal constant TWELVE_CREDITS = 120_000_000;
    uint256 internal constant THIRTEEN_CREDITS = 130_000_000;
    uint256 internal constant SEVENTEEN_CREDITS = 170_000_000;
    uint256 internal constant NINETEEN_CREDITS = 190_000_000;
    uint256 internal constant TWENTY_THREE_CREDITS = 230_000_000;
    uint8 internal constant CONFIRMED = 1;
    uint8 internal constant ACCESS_AUTHORIZED = 2;
    uint8 internal constant SETTLED = 3;

    function setUp() public {
        vm.warp(1000);
        harness = new ProviderReceivableHarness();
        harness.initialize(address(this), PROVIDER, LAB_ID);
    }

    function test_getLabProviderReceivable_exposes_pending_provider_bucket() public {
        harness.setPendingProviderPayout(LAB_ID, FIVE_CREDITS);

        (
            uint256 attestedSessionPayout,
            uint256 potentialNoShowFee,
            uint256 pendingGraceReservationCount,
            uint256 accruedReceivable
        ) = harness.getLabProviderReceivable(LAB_ID);

        assertEq(attestedSessionPayout, 0);
        assertEq(potentialNoShowFee, 0);
        assertEq(pendingGraceReservationCount, 0);
        assertEq(accruedReceivable, FIVE_CREDITS);
    }

    function test_getLabProviderReceivable_separates_attested_noShow_grace_and_accrued() public {
        bytes32 attestedKey = keccak256("preview-attested");
        bytes32 noShowKey = keccak256("preview-no-show");
        bytes32 graceKey = keccak256("preview-grace");

        harness.setExpiredPayoutReservation(attestedKey, LAB_ID, ACCESS_AUTHORIZED, FIVE_CREDITS_U96, 997);
        harness.markSessionStartedForTest(attestedKey);
        harness.setExpiredPayoutReservation(noShowKey, LAB_ID, CONFIRMED, FIVE_CREDITS_U96, 998);
        harness.setExpiredPayoutReservation(graceKey, LAB_ID, ACCESS_AUTHORIZED, FIVE_CREDITS_U96, 999);
        harness.setPendingProviderPayout(LAB_ID, TWELVE_CREDITS);

        (
            uint256 attestedSessionPayout,
            uint256 potentialNoShowFee,
            uint256 pendingGraceReservationCount,
            uint256 previewAccruedReceivable
        ) = harness.getLabProviderReceivable(LAB_ID);

        assertEq(attestedSessionPayout, FIVE_CREDITS);
        assertEq(potentialNoShowFee, 7_500_000);
        assertEq(pendingGraceReservationCount, 1);
        assertEq(previewAccruedReceivable, TWELVE_CREDITS);
    }

    function test_requestProviderPayout_queues_entire_accrued_bucket() public {
        harness.setPendingProviderPayout(LAB_ID, TWELVE_CREDITS);

        bytes32 reservationKey = keccak256("newly-accrued-with-existing-balance");
        harness.setExpiredPayoutReservation(reservationKey, LAB_ID, ACCESS_AUTHORIZED, FIVE_CREDITS_U96, 999);
        harness.markSessionStartedForTest(reservationKey);

        vm.prank(PROVIDER);
        harness.requestProviderPayout(LAB_ID, 10);

        (
            uint256 attestedSessionPayout,
            uint256 potentialNoShowFee,
            uint256 pendingGraceReservationCount,
            uint256 previewAccruedReceivable
        ) = harness.getLabProviderReceivable(LAB_ID);
        assertEq(attestedSessionPayout, 0);
        assertEq(potentialNoShowFee, 0);
        assertEq(pendingGraceReservationCount, 0);
        assertEq(previewAccruedReceivable, TWELVE_CREDITS + FIVE_CREDITS);

        (
            uint256 accruedReceivable,
            uint256 settlementQueued,
            uint256 invoicedReceivable,
            uint256 approvedReceivable,
            uint256 paidReceivable,
            uint256 reversedReceivable,
            uint256 disputedReceivable
        ) = _getLifecycleWithoutTimestamp();

        assertEq(accruedReceivable, 0);
        assertEq(settlementQueued, TWELVE_CREDITS + FIVE_CREDITS);
        assertEq(invoicedReceivable, 0);
        assertEq(approvedReceivable, 0);
        assertEq(paidReceivable, 0);
        assertEq(reversedReceivable, 0);
        assertEq(disputedReceivable, 0);
    }

    function test_requestProviderPayout_queues_accrued_bucket_when_heap_is_empty() public {
        harness.setPendingProviderPayout(LAB_ID, TWELVE_CREDITS);
        assertEq(harness.payoutHeapLength(LAB_ID), 0);

        vm.prank(PROVIDER);
        harness.requestProviderPayout(LAB_ID, 10);

        (uint256 accruedReceivable, uint256 settlementQueued,,,,,) = _getLifecycleWithoutTimestamp();
        assertEq(accruedReceivable, 0);
        assertEq(settlementQueued, TWELVE_CREDITS);
    }

    function test_requestProviderPayout_queues_permissionless_accrual_removed_from_heap() public {
        bytes32 reservationKey = keccak256("permissionless-accrual");
        harness.setExpiredPayoutReservation(reservationKey, LAB_ID, ACCESS_AUTHORIZED, FIVE_CREDITS_U96, 999);
        harness.markSessionStartedForTest(reservationKey);

        vm.prank(address(0xBEEF));
        uint256 processed = harness.releaseInstitutionalReservation(reservationKey, LAB_ID);

        assertEq(processed, 1);
        assertEq(harness.payoutHeapLength(LAB_ID), 0);

        (uint256 accruedReceivable, uint256 settlementQueued,,,,,) = _getLifecycleWithoutTimestamp();
        assertEq(accruedReceivable, FIVE_CREDITS);
        assertEq(settlementQueued, 0);

        vm.prank(PROVIDER);
        harness.requestProviderPayout(LAB_ID, 10);

        (accruedReceivable, settlementQueued,,,,,) = _getLifecycleWithoutTimestamp();
        assertEq(accruedReceivable, 0);
        assertEq(settlementQueued, FIVE_CREDITS);
    }

    function test_requestProviderPayout_allows_authorized_backend() public {
        bytes32 reservationKey = keccak256("authorized-backend-session-started");
        harness.setExpiredPayoutReservation(reservationKey, LAB_ID, ACCESS_AUTHORIZED, FIVE_CREDITS_U96, 999);
        harness.markSessionStartedForTest(reservationKey);

        harness.setAuthorizedBackend(PROVIDER, BACKEND);

        vm.prank(BACKEND);
        harness.requestProviderPayout(LAB_ID, 10);

        (
            uint256 accruedReceivable,
            uint256 settlementQueued,
            uint256 invoicedReceivable,
            uint256 approvedReceivable,
            uint256 paidReceivable,
            uint256 reversedReceivable,
            uint256 disputedReceivable
        ) = _getLifecycleWithoutTimestamp();

        assertEq(accruedReceivable, 0);
        assertEq(settlementQueued, FIVE_CREDITS);
        assertEq(invoicedReceivable, 0);
        assertEq(approvedReceivable, 0);
        assertEq(paidReceivable, 0);
        assertEq(reversedReceivable, 0);
        assertEq(disputedReceivable, 0);
    }

    function test_getLabProviderReceivable_requires_double_attestation_for_pending_closure() public {
        bytes32 reservationKey = keccak256("access-authorized-without-session");
        harness.setExpiredPayoutReservation(reservationKey, LAB_ID, ACCESS_AUTHORIZED, FIVE_CREDITS_U96, 999);

        (
            uint256 attestedSessionPayout,
            uint256 potentialNoShowFee,
            uint256 pendingGraceReservationCount,
            uint256 accruedReceivable
        ) = harness.getLabProviderReceivable(LAB_ID);

        assertEq(attestedSessionPayout, 0);
        assertEq(potentialNoShowFee, 0);
        assertEq(pendingGraceReservationCount, 1);
        assertEq(accruedReceivable, 0);
    }

    function test_getLabProviderReceivable_exposes_confirmed_noShow_fee() public {
        bytes32 reservationKey = keccak256("preview-confirmed-no-show");
        harness.setExpiredPayoutReservation(reservationKey, LAB_ID, CONFIRMED, FIVE_CREDITS_U96, 999);

        (
            uint256 attestedSessionPayout,
            uint256 potentialNoShowFee,
            uint256 pendingGraceReservationCount,
            uint256 previewAccruedReceivable
        ) = harness.getLabProviderReceivable(LAB_ID);

        assertEq(attestedSessionPayout, 0);
        assertEq(potentialNoShowFee, 7_500_000);
        assertEq(pendingGraceReservationCount, 0);
        assertEq(previewAccruedReceivable, 0);
    }

    function test_getLabProviderReceivablePaginated_uses_same_preview_categories() public {
        bytes32 noShowKey = keccak256("preview-paginated-no-show");
        bytes32 graceKey = keccak256("preview-paginated-grace");
        harness.setExpiredPayoutReservation(noShowKey, LAB_ID, CONFIRMED, FIVE_CREDITS_U96, 998);
        harness.setExpiredPayoutReservation(graceKey, LAB_ID, ACCESS_AUTHORIZED, FIVE_CREDITS_U96, 999);

        (
            uint256 attestedSessionPayout,
            uint256 potentialNoShowFee,
            uint256 pendingGraceReservationCount,
            uint256 accruedReceivable,
            uint256 nextOffset,
            bool hasMore
        ) = harness.getLabProviderReceivablePaginated(LAB_ID, 0, 10);

        assertEq(attestedSessionPayout, 0);
        assertEq(potentialNoShowFee, 7_500_000);
        assertEq(pendingGraceReservationCount, 1);
        assertEq(accruedReceivable, 0);
        assertEq(nextOffset, 2);
        assertFalse(hasMore);
    }

    function test_getLabProviderReceivable_reverts_above_legacy_heap_limit() public {
        harness.seedPayoutHeapEntries(LAB_ID, 1001);

        vm.expectRevert(bytes("Use paginated receivable getter"));
        harness.getLabProviderReceivable(LAB_ID);

        (,,,, uint256 nextOffset, bool hasMore) = harness.getLabProviderReceivablePaginated(LAB_ID, 0, 1000);
        assertEq(nextOffset, 1000);
        assertTrue(hasMore);
    }

    function test_requestProviderPayout_finalizes_confirmed_no_show_without_session_started() public {
        bytes32 reservationKey = keccak256("confirmed-expired");
        harness.setExpiredPayoutReservation(reservationKey, LAB_ID, CONFIRMED, FIVE_CREDITS_U96, 999);

        vm.prank(PROVIDER);
        harness.requestProviderPayout(LAB_ID, 10);

        assertEq(harness.getReservationStatus(reservationKey), SETTLED);
        assertEq(harness.lastRefundAmount(), 37_500_000);
        assertEq(harness.reservationIndexCount(LAB_ID), 0);
        assertEq(harness.totalReservations(), 0);

        (uint256 accruedReceivable, uint256 settlementQueued,,,,,) = _getLifecycleWithoutTimestamp();
        assertEq(accruedReceivable, 0);
        assertEq(settlementQueued, 7_500_000);

        (int32 score, uint32 totalEvents,) = harness.getLabReputation(LAB_ID);
        assertEq(score, int32(0));
        assertEq(totalEvents, uint32(0));
    }

    function test_requestProviderPayout_no_show_at_lot_limit_restores_refund() public {
        bytes32 reservationKey = keccak256("confirmed-expired-lot-limit");
        harness.setExpiredPayoutReservation(reservationKey, LAB_ID, CONFIRMED, FIVE_CREDITS_U96, 999);
        harness.enableLedgerRefund();
        harness.seedCreditReservationAtLotLimit(reservationKey, FIVE_CREDITS * 2, FIVE_CREDITS);

        vm.prank(PROVIDER);
        harness.requestProviderPayout(LAB_ID, 10);

        assertEq(harness.getReservationStatus(reservationKey), SETTLED);
        assertEq(harness.lastRefundAmount(), 37_500_000);
        assertEq(harness.creditLotCount(PROVIDER), 128);
    }

    function test_requestProviderPayout_fmu_at_lot_limit_restores_full_refund() public {
        bytes32 reservationKey = keccak256("fmu-expired-lot-limit");
        harness.setLabResourceType(LAB_ID, 1);
        harness.setExpiredPayoutReservation(reservationKey, LAB_ID, CONFIRMED, FIVE_CREDITS_U96, 999);
        harness.enableLedgerRefund();
        harness.seedCreditReservationAtLotLimit(reservationKey, FIVE_CREDITS * 2, FIVE_CREDITS);

        vm.prank(PROVIDER);
        harness.requestProviderPayout(LAB_ID, 10);

        assertEq(harness.getReservationStatus(reservationKey), SETTLED);
        assertEq(harness.lastRefundAmount(), FIVE_CREDITS);
        assertEq(harness.creditLotCount(PROVIDER), 128);
    }

    function test_requestProviderPayout_finalizes_accessAuthorized_no_show_after_attestation_grace() public {
        bytes32 reservationKey = keccak256("access-authorized-no-session");
        harness.setExpiredPayoutReservation(reservationKey, LAB_ID, ACCESS_AUTHORIZED, FIVE_CREDITS_U96, 999);

        vm.warp(999 + 1 days + 1);
        vm.prank(PROVIDER);
        harness.requestProviderPayout(LAB_ID, 10);

        assertEq(harness.getReservationStatus(reservationKey), SETTLED);
        assertEq(harness.lastRefundAmount(), 37_500_000);
        assertEq(harness.reservationIndexCount(LAB_ID), 0);
        assertEq(harness.totalReservations(), 0);

        (uint256 accruedReceivable, uint256 settlementQueued,,,,,) = _getLifecycleWithoutTimestamp();
        assertEq(accruedReceivable, 0);
        assertEq(settlementQueued, 7_500_000);

        (int32 score, uint32 totalEvents,) = harness.getLabReputation(LAB_ID);
        assertEq(score, int32(0));
        assertEq(totalEvents, uint32(0));
    }

    function test_requestProviderPayout_records_completion_for_session_started_reservation() public {
        bytes32 reservationKey = keccak256("session-started");
        harness.setExpiredPayoutReservation(reservationKey, LAB_ID, ACCESS_AUTHORIZED, FIVE_CREDITS_U96, 999);
        harness.markSessionStartedForTest(reservationKey);

        vm.prank(PROVIDER);
        harness.requestProviderPayout(LAB_ID, 10);

        (int32 score, uint32 totalEvents,) = harness.getLabReputation(LAB_ID);
        assertEq(score, int32(1));
        assertEq(totalEvents, uint32(1));
    }

    function test_requestProviderPayout_cleans_settled_reservation_indexes() public {
        bytes32 reservationKey = keccak256("indexed-session-started");
        harness.setExpiredPayoutReservation(reservationKey, LAB_ID, ACCESS_AUTHORIZED, FIVE_CREDITS_U96, 999);
        harness.markSessionStartedForTest(reservationKey);

        vm.prank(PROVIDER);
        harness.requestProviderPayout(LAB_ID, 10);

        assertEq(harness.reservationIndexCount(LAB_ID), 0);
        assertEq(harness.totalReservations(), 0);
    }

    function test_requestProviderPayout_cleans_more_than_100_historical_reservations() public {
        vm.warp(1000);
        for (uint256 i; i < 101; i++) {
            bytes32 reservationKey = keccak256(abi.encodePacked("historical", i));
            harness.setExpiredPayoutReservation(reservationKey, LAB_ID, ACCESS_AUTHORIZED, 1, 999);
            harness.markSessionStartedForTest(reservationKey);
        }

        vm.prank(PROVIDER);
        harness.requestProviderPayout(LAB_ID, 100);
        assertEq(harness.reservationIndexCount(LAB_ID), 1);

        vm.prank(PROVIDER);
        harness.requestProviderPayout(LAB_ID, 1);
        assertEq(harness.reservationIndexCount(LAB_ID), 0);
        assertEq(harness.totalReservations(), 0);
    }

    function test_requestProviderPayout_batch_growth_is_not_quadratic_in_heap_size() public {
        uint256 gasForSmallBatch = _measurePayoutGas(16);
        uint256 gasForLargeBatch = _measurePayoutGas(96);

        assertLt(gasForLargeBatch, gasForSmallBatch * 7);
    }

    function test_requestProviderPayout_compaction_path_gas_remains_bounded() public {
        bytes32 invalidKey = keccak256("invalid-compaction");
        bytes32 eligibleKey = keccak256("eligible-compaction");
        bytes32 futureKey = keccak256("future-compaction");
        harness.setExpiredPayoutReservation(invalidKey, LAB_ID, SETTLED, FIVE_CREDITS_U96, 100);
        harness.setExpiredPayoutReservation(eligibleKey, LAB_ID, ACCESS_AUTHORIZED, FIVE_CREDITS_U96, 200);
        harness.setExpiredPayoutReservation(futureKey, LAB_ID, CONFIRMED, FIVE_CREDITS_U96, 10_000);
        harness.markSessionStartedForTest(eligibleKey);
        harness.setPayoutHeapInvalidCount(LAB_ID, 1);

        uint256 gasBefore = gasleft();
        vm.prank(PROVIDER);
        harness.requestProviderPayout(LAB_ID, 10);
        uint256 gasUsed = gasBefore - gasleft();

        // Emergency settlement-review eligibility adds bounded storage checks
        // to payout candidates while preserving the compaction budget.
        assertLt(gasUsed, 1_010_000);
    }

    function test_heap_compaction_preserves_future_confirmed_candidate() public {
        bytes32 invalidKey = keccak256("invalid-before-future");
        bytes32 eligibleKey = keccak256("eligible-before-future");
        bytes32 futureKey = keccak256("future-confirmed");
        harness.setExpiredPayoutReservation(invalidKey, LAB_ID, SETTLED, FIVE_CREDITS_U96, 100);
        harness.setExpiredPayoutReservation(eligibleKey, LAB_ID, ACCESS_AUTHORIZED, FIVE_CREDITS_U96, 200);
        harness.setExpiredPayoutReservation(futureKey, LAB_ID, CONFIRMED, FIVE_CREDITS_U96, 10_000);
        harness.markSessionStartedForTest(eligibleKey);
        harness.setPayoutHeapInvalidCount(LAB_ID, 1);

        vm.prank(PROVIDER);
        harness.requestProviderPayout(LAB_ID, 10);

        assertEq(harness.payoutHeapLength(LAB_ID), 1);
    }

    function test_requestProviderPayout_skips_unattested_attestation_grace_root() public {
        bytes32 unattestedKey = keccak256("unattested-root");
        bytes32 attestedKey = keccak256("attested-next");
        harness.setExpiredPayoutReservation(unattestedKey, LAB_ID, ACCESS_AUTHORIZED, FIVE_CREDITS_U96, 998);
        harness.setExpiredPayoutReservation(attestedKey, LAB_ID, ACCESS_AUTHORIZED, FIVE_CREDITS_U96, 999);
        harness.markSessionStartedForTest(attestedKey);

        vm.prank(PROVIDER);
        harness.requestProviderPayout(LAB_ID, 10);

        (uint256 accruedReceivable, uint256 settlementQueued,,,,,) = _getLifecycleWithoutTimestamp();
        assertEq(accruedReceivable, 0);
        assertEq(settlementQueued, FIVE_CREDITS);
        assertEq(harness.payoutHeapLength(LAB_ID), 1);
        assertEq(harness.getReservationStatus(unattestedKey), ACCESS_AUTHORIZED);
        assertEq(harness.getReservationStatus(attestedKey), SETTLED);
        assertEq(harness.lastRefundAmount(), 0);

        vm.warp(999 + 1 days + 1);
        vm.prank(PROVIDER);
        harness.requestProviderPayout(LAB_ID, 10);

        (accruedReceivable, settlementQueued,,,,,) = _getLifecycleWithoutTimestamp();
        assertEq(accruedReceivable, 0);
        assertEq(settlementQueued, FIVE_CREDITS + 7_500_000);
        assertEq(harness.getReservationStatus(unattestedKey), SETTLED);
        assertEq(harness.getReservationStatus(attestedKey), SETTLED);
        assertEq(harness.lastRefundAmount(), 37_500_000);
    }

    function test_requestProviderPayout_rejects_settled_reservation() public {
        bytes32 reservationKey = keccak256("settled-status");
        harness.setExpiredPayoutReservation(reservationKey, LAB_ID, SETTLED, FIVE_CREDITS_U96, 999);

        vm.prank(PROVIDER);
        vm.expectRevert("No settleable reservations");
        harness.requestProviderPayout(LAB_ID, 10);

        (int32 score, uint32 totalEvents,) = harness.getLabReputation(LAB_ID);
        assertEq(score, int32(0));
        assertEq(totalEvents, uint32(0));
    }

    function test_getLabProviderReceivable_includes_unsettled_lifecycle_buckets() public {
        harness.setProviderReceivableBucket(LAB_ID, 1, FIVE_CREDITS);
        harness.setProviderReceivableBucket(LAB_ID, 2, SEVEN_CREDITS);
        harness.setProviderReceivableBucket(LAB_ID, 3, ELEVEN_CREDITS);
        harness.setProviderReceivableBucket(LAB_ID, 4, THIRTEEN_CREDITS);
        harness.setProviderReceivableBucket(LAB_ID, 7, SEVENTEEN_CREDITS);
        harness.setProviderReceivableBucket(LAB_ID, 5, NINETEEN_CREDITS);
        harness.setProviderReceivableBucket(LAB_ID, 6, TWENTY_THREE_CREDITS);

        (
            uint256 attestedSessionPayout,
            uint256 potentialNoShowFee,
            uint256 pendingGraceReservationCount,
            uint256 previewAccruedReceivable
        ) = harness.getLabProviderReceivable(LAB_ID);
        assertEq(attestedSessionPayout, 0);
        assertEq(potentialNoShowFee, 0);
        assertEq(pendingGraceReservationCount, 0);
        assertEq(previewAccruedReceivable, 530_000_000);
    }

    function test_transitionProviderReceivableState_rejects_object_bound_invalidations() public {
        harness.setProviderReceivableBucket(LAB_ID, 2, TWELVE_CREDITS);

        vm.expectRevert("Use settlement object");
        harness.transitionProviderReceivableState(LAB_ID, 2, 7, FIVE_CREDITS, bytes32("dispute-001"));
    }

    function test_transitionProviderReceivableState_reverts_without_claim_for_paid_state() public {
        harness.setProviderReceivableBucket(LAB_ID, 2, TEN_CREDITS);

        vm.expectRevert("Claim required");
        harness.transitionProviderReceivableState(LAB_ID, 2, 5, ONE_CREDIT, bytes32("bad"));
    }

    function test_transitionProviderReceivableState_requires_reference() public {
        harness.setProviderReceivableBucket(LAB_ID, 2, TEN_CREDITS);

        vm.prank(PROVIDER);
        vm.expectRevert("Reference required");
        harness.transitionProviderReceivableState(LAB_ID, 2, 3, ONE_CREDIT, bytes32(0));
    }

    function test_provider_claim_requires_batch_scope_and_payment_attestation() public {
        bytes32 claimId = keccak256("claim-001");
        bytes32 batchId = _queueBatch(FIVE_CREDITS, keccak256("reservation-source-001"));
        bytes32 invoiceHash = keccak256("invoice-001");
        bytes32 paymentRef = keccak256("payment-001");
        bytes32 attestation = keccak256("attestation-001");
        address settler = address(this);

        vm.prank(PROVIDER);
        harness.submitProviderSettlementClaim(claimId, LAB_ID, FIVE_CREDITS, batchId, invoiceHash);

        vm.prank(settler);
        harness.approveProviderSettlementClaim(claimId, keccak256("approval-001"));

        vm.prank(settler);
        harness.recordProviderSettlementClaimPayment(claimId, paymentRef, attestation);

        (
            uint256 labId,
            uint256 amount,
            uint8 status,
            bytes32 storedBatchId,
            bytes32 storedInvoiceHash,
            bytes32 storedPaymentRef,
            bytes32 storedAttestation,
            address submittedBy,
            address approvedBy,
            address paidBy,
            uint64 submittedAt,
            uint64 approvedAt,
            uint64 paidAt
        ) = harness.getProviderSettlementClaim(claimId);

        assertEq(labId, LAB_ID);
        assertEq(amount, FIVE_CREDITS);
        assertEq(status, 3);
        assertEq(storedBatchId, batchId);
        assertEq(storedInvoiceHash, invoiceHash);
        assertEq(storedPaymentRef, paymentRef);
        assertEq(storedAttestation, attestation);
        assertEq(submittedBy, PROVIDER);
        assertEq(approvedBy, settler);
        assertEq(paidBy, settler);
        assertGt(submittedAt, 0);
        assertGe(approvedAt, submittedAt);
        assertGe(paidAt, approvedAt);
    }

    function test_provider_receivable_scope_rejects_source_from_another_lab() public {
        bytes32 reservationId = keccak256("reservation-source-wrong-lab");
        harness.setReceivableSourceForTest(reservationId, LAB_ID + 1);

        vm.expectRevert("Receivable source lab mismatch");
        harness.accrueProviderReceivableForTest(LAB_ID, ONE_CREDIT, reservationId);
    }

    function test_provider_receivable_scope_rejects_unknown_source() public {
        vm.expectRevert("Receivable source not found");
        harness.accrueProviderReceivableRawForTest(LAB_ID, ONE_CREDIT, keccak256("reservation-source-unknown"));
    }

    function test_provider_receivable_cannot_be_queued_without_batch() public {
        harness.setProviderReceivableBucket(LAB_ID, 1, ONE_CREDIT);

        vm.prank(PROVIDER);
        vm.expectRevert("Use requestProviderPayout");
        harness.transitionProviderReceivableState(LAB_ID, 1, 2, ONE_CREDIT, bytes32("direct-queue"));
    }

    function test_provider_claim_rejects_reused_invoice_and_approval_references() public {
        bytes32 firstClaim = keccak256("claim-reference-001");
        bytes32 secondClaim = keccak256("claim-reference-002");
        bytes32 firstInvoice = keccak256("invoice-reference-001");
        bytes32 secondInvoice = keccak256("invoice-reference-002");
        bytes32 approval = keccak256("approval-reference-001");
        bytes32 firstBatch = _queueBatch(FIVE_CREDITS, keccak256("reservation-source-002"));

        vm.prank(PROVIDER);
        harness.submitProviderSettlementClaim(firstClaim, LAB_ID, FIVE_CREDITS, firstBatch, firstInvoice);

        bytes32 secondBatch = _queueBatch(ONE_CREDIT, keccak256("reservation-source-003"));

        vm.prank(PROVIDER);
        vm.expectRevert("Invoice reference already used");
        harness.submitProviderSettlementClaim(secondClaim, LAB_ID, ONE_CREDIT, secondBatch, firstInvoice);

        vm.prank(PROVIDER);
        harness.submitProviderSettlementClaim(secondClaim, LAB_ID, ONE_CREDIT, secondBatch, secondInvoice);

        vm.prank(address(this));
        harness.approveProviderSettlementClaim(firstClaim, approval);

        vm.prank(address(this));
        vm.expectRevert("Approval reference already used");
        harness.approveProviderSettlementClaim(secondClaim, approval);
    }

    function test_provider_claim_requires_existing_batch() public {
        _queueBatch(FIVE_CREDITS, keccak256("reservation-source-004"));

        vm.prank(PROVIDER);
        vm.expectRevert("Settlement batch not found");
        harness.submitProviderSettlementClaim(
            keccak256("claim-unknown-batch"),
            LAB_ID,
            FIVE_CREDITS,
            keccak256("unknown-batch"),
            keccak256("invoice-unknown-batch")
        );
    }

    function test_provider_claim_requires_matching_batch_lab_and_amount() public {
        bytes32 batchId = _queueBatch(FIVE_CREDITS, keccak256("reservation-source-005"));

        vm.expectRevert("Settlement batch lab mismatch");
        harness.submitProviderSettlementClaim(
            keccak256("claim-wrong-lab"), LAB_ID + 1, FIVE_CREDITS, batchId, keccak256("invoice-wrong-lab")
        );

        vm.prank(PROVIDER);
        vm.expectRevert("Claim amount must match batch remaining amount");
        harness.submitProviderSettlementClaim(
            keccak256("claim-partial-batch"), LAB_ID, ONE_CREDIT, batchId, keccak256("invoice-partial-batch")
        );
    }

    function test_provider_claim_consumes_batch_scope_once() public {
        bytes32 batchId = _queueBatch(FIVE_CREDITS, keccak256("reservation-source-006"));
        (
            uint256 labId,
            uint256 totalAmount,
            uint256 remainingAmount,
            bytes32 scopeRoot,
            uint64 createdAt,
            uint64 claimedAt,
            uint8 status
        ) = harness.getProviderSettlementBatch(batchId);
        createdAt;
        claimedAt;

        assertEq(labId, LAB_ID);
        assertEq(totalAmount, FIVE_CREDITS);
        assertEq(remainingAmount, FIVE_CREDITS);
        assertTrue(scopeRoot != bytes32(0));
        assertEq(status, 1);

        vm.prank(PROVIDER);
        harness.submitProviderSettlementClaim(
            keccak256("claim-batch-once"), LAB_ID, FIVE_CREDITS, batchId, keccak256("invoice-batch-once")
        );

        (,, remainingAmount,,,, status) = harness.getProviderSettlementBatch(batchId);
        assertEq(remainingAmount, 0);
        assertEq(status, 2);

        vm.prank(PROVIDER);
        vm.expectRevert("Settlement batch not claimable");
        harness.submitProviderSettlementClaim(
            keccak256("claim-batch-twice"), LAB_ID, FIVE_CREDITS, batchId, keccak256("invoice-batch-twice")
        );
    }

    function test_reversed_batch_cannot_be_claimed_after_new_batch_is_queued() public {
        bytes32 batchA = _queueBatch(FIVE_CREDITS, keccak256("reversal-batch-a"));

        harness.reverseSettlementBatch(batchA, keccak256("batch-reversal-001"));

        (,, uint256 remainingAmount,,,, uint8 status) = harness.getProviderSettlementBatch(batchA);
        assertEq(remainingAmount, 0);
        assertEq(status, 4);

        bytes32 batchB = _queueBatch(FIVE_CREDITS, keccak256("reversal-batch-b"));
        assertTrue(batchB != batchA);

        vm.prank(PROVIDER);
        vm.expectRevert("Settlement batch not claimable");
        harness.submitProviderSettlementClaim(
            keccak256("reversal-batch-old-claim"), LAB_ID, FIVE_CREDITS, batchA, keccak256("reversal-batch-old-invoice")
        );
    }

    function test_disputed_submitted_claim_cannot_be_approved_after_new_claim() public {
        bytes32 batchA = _queueBatch(FIVE_CREDITS, keccak256("dispute-claim-batch-a"));
        bytes32 claimA = keccak256("dispute-claim-a");

        vm.prank(PROVIDER);
        harness.submitProviderSettlementClaim(
            claimA, LAB_ID, FIVE_CREDITS, batchA, keccak256("dispute-claim-invoice-a")
        );
        harness.disputeSettlementClaim(claimA, keccak256("claim-dispute-001"));

        bytes32 batchB = _queueBatch(FIVE_CREDITS, keccak256("dispute-claim-batch-b"));
        vm.prank(PROVIDER);
        harness.submitProviderSettlementClaim(
            keccak256("dispute-claim-b"), LAB_ID, FIVE_CREDITS, batchB, keccak256("dispute-claim-invoice-b")
        );

        vm.expectRevert("Claim is not submitted");
        harness.approveProviderSettlementClaim(claimA, keccak256("dispute-claim-approval-old"));
    }

    function test_reversed_approved_claim_cannot_be_paid_after_new_claim_is_approved() public {
        bytes32 batchA = _queueBatch(FIVE_CREDITS, keccak256("reverse-approved-batch-a"));
        bytes32 claimA = keccak256("reverse-approved-claim-a");

        vm.prank(PROVIDER);
        harness.submitProviderSettlementClaim(
            claimA, LAB_ID, FIVE_CREDITS, batchA, keccak256("reverse-approved-invoice-a")
        );
        harness.approveProviderSettlementClaim(claimA, keccak256("reverse-approved-ref-a"));
        harness.reverseSettlementClaim(claimA, keccak256("reverse-approved-reversal-001"));

        bytes32 batchB = _queueBatch(FIVE_CREDITS, keccak256("reverse-approved-batch-b"));
        bytes32 claimB = keccak256("reverse-approved-claim-b");
        vm.prank(PROVIDER);
        harness.submitProviderSettlementClaim(
            claimB, LAB_ID, FIVE_CREDITS, batchB, keccak256("reverse-approved-invoice-b")
        );
        harness.approveProviderSettlementClaim(claimB, keccak256("reverse-approved-ref-b"));

        vm.expectRevert("Claim is not approved");
        harness.recordProviderSettlementClaimPayment(
            claimA, keccak256("reverse-approved-payment-old"), keccak256("reverse-approved-attestation-old")
        );
    }

    function test_transitionProviderReceivableState_requires_claim_for_ordinary_financial_states() public {
        harness.setProviderReceivableBucket(LAB_ID, 2, ONE_CREDIT);
        vm.expectRevert("Claim required");
        harness.transitionProviderReceivableState(LAB_ID, 2, 3, ONE_CREDIT, bytes32("invoice-001"));

        harness.setProviderReceivableBucket(LAB_ID, 3, ONE_CREDIT);
        vm.expectRevert("Claim required");
        harness.transitionProviderReceivableState(LAB_ID, 3, 4, ONE_CREDIT, bytes32("approval-001"));

        harness.setProviderReceivableBucket(LAB_ID, 4, ONE_CREDIT);
        vm.expectRevert("Claim required");
        harness.transitionProviderReceivableState(LAB_ID, 4, 5, ONE_CREDIT, bytes32("payment-001"));

        harness.setProviderReceivableBucket(LAB_ID, 7, ONE_CREDIT);
        vm.expectRevert("Claim required");
        harness.transitionProviderReceivableState(LAB_ID, 7, 4, ONE_CREDIT, bytes32("approval-002"));
    }

    function test_transitionProviderReceivableState_reverts_for_unauthorized_caller() public {
        harness.setProviderReceivableBucket(LAB_ID, 2, TEN_CREDITS);

        vm.prank(address(0xDEAD));
        vm.expectRevert("Not authorized");
        harness.transitionProviderReceivableState(LAB_ID, 2, 3, ONE_CREDIT, bytes32("nope"));
    }

    function test_transitionProviderReceivableState_provider_cannot_approve() public {
        harness.setProviderReceivableBucket(LAB_ID, 2, TEN_CREDITS);

        vm.prank(PROVIDER);
        vm.expectRevert("Not authorized");
        harness.transitionProviderReceivableState(LAB_ID, 2, 4, ONE_CREDIT, bytes32("invoice"));
    }

    function _getLifecycleWithoutTimestamp()
        internal
        view
        returns (
            uint256 accruedReceivable,
            uint256 settlementQueued,
            uint256 invoicedReceivable,
            uint256 approvedReceivable,
            uint256 paidReceivable,
            uint256 reversedReceivable,
            uint256 disputedReceivable
        )
    {
        uint256 ignoredLastAccruedAt;
        (
            accruedReceivable,
            settlementQueued,
            invoicedReceivable,
            approvedReceivable,
            paidReceivable,
            reversedReceivable,
            disputedReceivable,
            ignoredLastAccruedAt
        ) = harness.getLabProviderReceivableLifecycle(LAB_ID);
        ignoredLastAccruedAt;
    }

    function _queueBatch(
        uint256 amount,
        bytes32 reservationId
    ) internal returns (bytes32 batchId) {
        harness.accrueProviderReceivableForTest(LAB_ID, amount, reservationId);
        vm.prank(PROVIDER);
        harness.requestProviderPayout(LAB_ID, 10);
        batchId = harness.getLatestProviderSettlementBatch(LAB_ID);
    }

    function _measurePayoutGas(
        uint256 batchSize
    ) internal returns (uint256 gasUsed) {
        ProviderReceivableHarness measurementHarness = new ProviderReceivableHarness();
        measurementHarness.initialize(address(this), PROVIDER, LAB_ID);

        for (uint256 i; i < batchSize; i++) {
            bytes32 reservationKey = keccak256(abi.encodePacked("gas-batch", batchSize, i));
            measurementHarness.setExpiredPayoutReservation(
                reservationKey, LAB_ID, ACCESS_AUTHORIZED, FIVE_CREDITS_U96, uint32(100 + i)
            );
            measurementHarness.markSessionStartedForTest(reservationKey);
        }

        uint256 gasBefore = gasleft();
        vm.prank(PROVIDER);
        measurementHarness.requestProviderPayout(LAB_ID, batchSize);
        gasUsed = gasBefore - gasleft();
    }
}
