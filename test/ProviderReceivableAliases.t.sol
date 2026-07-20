// SPDX-License-Identifier: MIT
pragma solidity ^0.8.33;

import {Test} from "forge-std/Test.sol";
import {ERC721} from "@openzeppelin/contracts/token/ERC721/ERC721.sol";
import {EnumerableSet} from "@openzeppelin/contracts/utils/structs/EnumerableSet.sol";
import {ProviderSettlementFacet} from "../contracts/facets/reservation/ProviderSettlementFacet.sol";
import {AppStorage, LibAppStorage, PayoutCandidate, Reservation} from "../contracts/libraries/LibAppStorage.sol";
import {LibAccessControlEnumerable} from "../contracts/libraries/LibAccessControlEnumerable.sol";
import {LibERC721StorageTestHelper} from "./LibERC721StorageTestHelper.sol";

contract ProviderReceivableHarness is ERC721, ProviderSettlementFacet {
    using LibAccessControlEnumerable for AppStorage;
    using EnumerableSet for EnumerableSet.AddressSet;
    using EnumerableSet for EnumerableSet.Bytes32Set;

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
    }

    function setProviderReceivableBucket(
        uint256 labId,
        uint8 state,
        uint256 amount
    ) external {
        AppStorage storage s = LibAppStorage.diamondStorage();
        if (state == 1) s.providerReceivableAccrued[labId] = amount;
        else if (state == 2) s.providerSettlementQueue[labId] = amount;
        else if (state == 3) s.providerReceivableInvoiced[labId] = amount;
        else if (state == 4) s.providerReceivableApproved[labId] = amount;
        else if (state == 5) s.providerReceivablePaid[labId] = amount;
        else if (state == 6) s.providerReceivableReversed[labId] = amount;
        else if (state == 7) s.providerReceivableDisputed[labId] = amount;
        else revert("invalid state");
    }

    function setAuthorizedBackend(
        address institution,
        address backend
    ) external {
        AppStorage storage s = LibAppStorage.diamondStorage();
        s.institutionalBackends[institution] = backend;
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
        reservation.labId = labId;
        reservation.renter = address(0xCAFE);
        reservation.price = providerShare;
        reservation.labProvider = ownerOf(labId);
        reservation.status = status;
        reservation.start = end - 1;
        reservation.end = end;
        reservation.providerShare = providerShare;
        s.payoutHeaps[labId].push(PayoutCandidate({end: end, key: reservationKey}));
        s.payoutHeapContains[reservationKey] = true;
        s.reservationKeysByToken[labId].add(reservationKey);
        s.renters[reservation.renter].add(reservationKey);
        s.totalReservationsCount += 1;
        s.labActiveReservationCount[labId] += 1;
        s.providerActiveReservationCount[reservation.labProvider] += 1;
    }

    function markSessionStartedForTest(
        bytes32 reservationKey
    ) external {
        AppStorage storage s = LibAppStorage.diamondStorage();
        s.reservationSessionStartedRecorded[reservationKey] = true;
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
    uint256 internal constant ONE_CREDIT = 100_000;
    uint256 internal constant FIVE_CREDITS = 500_000;
    uint96 internal constant FIVE_CREDITS_U96 = 500_000;
    uint256 internal constant SEVEN_CREDITS = 700_000;
    uint256 internal constant TEN_CREDITS = 1_000_000;
    uint256 internal constant ELEVEN_CREDITS = 1_100_000;
    uint256 internal constant TWELVE_CREDITS = 1_200_000;
    uint256 internal constant THIRTEEN_CREDITS = 1_300_000;
    uint256 internal constant SEVENTEEN_CREDITS = 1_700_000;
    uint256 internal constant NINETEEN_CREDITS = 1_900_000;
    uint256 internal constant TWENTY_THREE_CREDITS = 2_300_000;
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

        (uint256 providerReceivable, uint256 totalReceivable, uint256 eligibleCount) =
            harness.getLabProviderReceivable(LAB_ID);

        assertEq(providerReceivable, FIVE_CREDITS);
        assertEq(totalReceivable, FIVE_CREDITS);
        assertEq(eligibleCount, 0);
    }

    function test_requestProviderPayout_moves_accrued_receivable_into_settlement_queue_without_token_transfer() public {
        harness.setPendingProviderPayout(LAB_ID, TWELVE_CREDITS);

        vm.prank(PROVIDER);
        harness.requestProviderPayout(LAB_ID, 10);

        (uint256 providerReceivable, uint256 totalReceivable,) = harness.getLabProviderReceivable(LAB_ID);
        assertEq(providerReceivable, TWELVE_CREDITS);
        assertEq(totalReceivable, TWELVE_CREDITS);

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
        assertEq(settlementQueued, TWELVE_CREDITS);
        assertEq(invoicedReceivable, 0);
        assertEq(approvedReceivable, 0);
        assertEq(paidReceivable, 0);
        assertEq(reversedReceivable, 0);
        assertEq(disputedReceivable, 0);
    }

    function test_requestProviderPayout_allows_authorized_backend() public {
        harness.setPendingProviderPayout(LAB_ID, FIVE_CREDITS);

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

        (uint256 providerReceivable, uint256 totalReceivable, uint256 eligibleCount) =
            harness.getLabProviderReceivable(LAB_ID);

        assertEq(providerReceivable, 0);
        assertEq(totalReceivable, 0);
        assertEq(eligibleCount, 0);
    }

    function test_requestProviderPayout_rejects_confirmed_expired_reservation_without_session_started() public {
        bytes32 reservationKey = keccak256("confirmed-expired");
        harness.setExpiredPayoutReservation(reservationKey, LAB_ID, CONFIRMED, FIVE_CREDITS_U96, 999);

        vm.prank(PROVIDER);
        vm.expectRevert("No settleable reservations");
        harness.requestProviderPayout(LAB_ID, 10);

        (int32 score, uint32 totalEvents,) = harness.getLabReputation(LAB_ID);
        assertEq(score, int32(0));
        assertEq(totalEvents, uint32(0));
    }

    function test_requestProviderPayout_rejects_accessAuthorized_reservation_without_session_started() public {
        bytes32 reservationKey = keccak256("access-authorized-no-session");
        harness.setExpiredPayoutReservation(reservationKey, LAB_ID, ACCESS_AUTHORIZED, FIVE_CREDITS_U96, 999);

        vm.prank(PROVIDER);
        vm.expectRevert("No settleable reservations");
        harness.requestProviderPayout(LAB_ID, 10);

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

        assertLt(gasForLargeBatch, gasForSmallBatch * 8);
    }

    function test_heap_compaction_preserves_future_confirmed_candidate() public {
        bytes32 invalidKey = keccak256("invalid-before-future");
        bytes32 futureKey = keccak256("future-confirmed");
        harness.setExpiredPayoutReservation(invalidKey, LAB_ID, SETTLED, FIVE_CREDITS_U96, 100);
        harness.setExpiredPayoutReservation(futureKey, LAB_ID, CONFIRMED, FIVE_CREDITS_U96, 10_000);
        harness.setPayoutHeapInvalidCount(LAB_ID, 1);
        harness.setPendingProviderPayout(LAB_ID, ONE_CREDIT);

        vm.prank(PROVIDER);
        harness.requestProviderPayout(LAB_ID, 10);

        assertEq(harness.payoutHeapLength(LAB_ID), 1);
    }

    function test_requestProviderPayout_waits_for_unattested_attestation_grace() public {
        bytes32 unattestedKey = keccak256("unattested-root");
        bytes32 attestedKey = keccak256("attested-next");
        harness.setExpiredPayoutReservation(unattestedKey, LAB_ID, ACCESS_AUTHORIZED, FIVE_CREDITS_U96, 998);
        harness.setExpiredPayoutReservation(attestedKey, LAB_ID, ACCESS_AUTHORIZED, FIVE_CREDITS_U96, 999);
        harness.markSessionStartedForTest(attestedKey);

        vm.prank(PROVIDER);
        vm.expectRevert("No settleable reservations");
        harness.requestProviderPayout(LAB_ID, 10);

        assertEq(harness.payoutHeapLength(LAB_ID), 2);
        assertEq(harness.getReservationStatus(unattestedKey), ACCESS_AUTHORIZED);
        assertEq(harness.getReservationStatus(attestedKey), ACCESS_AUTHORIZED);

        vm.warp(999 + 1 days + 1);
        vm.prank(PROVIDER);
        harness.requestProviderPayout(LAB_ID, 10);

        (uint256 accruedReceivable, uint256 settlementQueued,,,,,) = _getLifecycleWithoutTimestamp();
        assertEq(accruedReceivable, 0);
        assertEq(settlementQueued, FIVE_CREDITS);
        assertEq(harness.getReservationStatus(unattestedKey), ACCESS_AUTHORIZED);
        assertEq(harness.getReservationStatus(attestedKey), SETTLED);
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

        (uint256 providerReceivable, uint256 totalReceivable,) = harness.getLabProviderReceivable(LAB_ID);
        assertEq(providerReceivable, 5_300_000);
        assertEq(totalReceivable, 5_300_000);
    }

    function test_transitionProviderReceivableState_moves_between_lifecycle_buckets() public {
        harness.setProviderReceivableBucket(LAB_ID, 2, TWELVE_CREDITS);

        vm.prank(PROVIDER);
        harness.transitionProviderReceivableState(LAB_ID, 2, 3, FIVE_CREDITS, bytes32("invoice-001"));

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
        assertEq(settlementQueued, SEVEN_CREDITS);
        assertEq(invoicedReceivable, FIVE_CREDITS);
        assertEq(approvedReceivable, 0);
        assertEq(paidReceivable, 0);
        assertEq(reversedReceivable, 0);
        assertEq(disputedReceivable, 0);

        (uint256 providerReceivable, uint256 totalReceivable,) = harness.getLabProviderReceivable(LAB_ID);
        assertEq(providerReceivable, TWELVE_CREDITS);
        assertEq(totalReceivable, TWELVE_CREDITS);
    }

    function test_transitionProviderReceivableState_reverts_for_invalid_transition() public {
        harness.setProviderReceivableBucket(LAB_ID, 2, TEN_CREDITS);

        vm.prank(PROVIDER);
        vm.expectRevert("Invalid transition");
        harness.transitionProviderReceivableState(LAB_ID, 2, 5, ONE_CREDIT, bytes32("bad"));
    }

    function test_transitionProviderReceivableState_requires_reference() public {
        harness.setProviderReceivableBucket(LAB_ID, 2, TEN_CREDITS);

        vm.prank(PROVIDER);
        vm.expectRevert("Reference required");
        harness.transitionProviderReceivableState(LAB_ID, 2, 3, ONE_CREDIT, bytes32(0));
    }

    function test_provider_claim_requires_reservation_scope_and_payment_attestation() public {
        bytes32 claimId = keccak256("claim-001");
        bytes32 reservationHash = keccak256("reservations-001");
        bytes32 invoiceHash = keccak256("invoice-001");
        bytes32 paymentRef = keccak256("payment-001");
        bytes32 attestation = keccak256("attestation-001");
        address settler = address(this);
        harness.setProviderReceivableBucket(LAB_ID, 2, FIVE_CREDITS);

        vm.prank(PROVIDER);
        harness.submitProviderSettlementClaim(claimId, LAB_ID, FIVE_CREDITS, reservationHash, invoiceHash);

        vm.prank(settler);
        harness.approveProviderSettlementClaim(claimId, keccak256("approval-001"));

        vm.prank(settler);
        harness.recordProviderSettlementClaimPayment(claimId, paymentRef, attestation);

        (
            uint256 labId,
            uint256 amount,
            uint8 status,
            bytes32 storedReservationHash,
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
        assertEq(storedReservationHash, reservationHash);
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
