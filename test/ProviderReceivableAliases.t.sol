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
        s.labActiveReservationCount[labId] += 1;
        s.providerActiveReservationCount[reservation.labProvider] += 1;
    }

    function getLabReputation(
        uint256 labId
    ) external view returns (int32 score, uint32 totalEvents, uint64 lastUpdated) {
        AppStorage storage s = LibAppStorage.diamondStorage();
        score = s.labReputation[labId].score;
        totalEvents = s.labReputation[labId].totalEvents;
        lastUpdated = s.labReputation[labId].lastUpdated;
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
    uint8 internal constant IN_USE = 2;
    uint8 internal constant SETTLED = 3;

    function setUp() public {
        vm.warp(1000);
        harness = new ProviderReceivableHarness();
        harness.initialize(address(this), PROVIDER, LAB_ID);
    }

    function test_getLabProviderReceivable_exposes_pending_provider_bucket() public {
        harness.setPendingProviderPayout(LAB_ID, FIVE_CREDITS);

        (
            uint256 providerReceivable,
            uint256 deferredInstitutionalReceivable,
            uint256 totalReceivable,
            uint256 eligibleCount
        ) = harness.getLabProviderReceivable(LAB_ID);

        assertEq(providerReceivable, FIVE_CREDITS);
        assertEq(deferredInstitutionalReceivable, 0);
        assertEq(totalReceivable, FIVE_CREDITS);
        assertEq(eligibleCount, 0);
    }

    function test_requestProviderPayout_moves_accrued_receivable_into_settlement_queue_without_token_transfer() public {
        harness.setPendingProviderPayout(LAB_ID, TWELVE_CREDITS);

        vm.prank(PROVIDER);
        harness.requestProviderPayout(LAB_ID, 10);

        (uint256 providerReceivable,, uint256 totalReceivable,) = harness.getLabProviderReceivable(LAB_ID);
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

    function test_requestProviderPayout_does_not_record_completion_for_confirmed_expired_reservation() public {
        bytes32 reservationKey = keccak256("confirmed-expired");
        harness.setExpiredPayoutReservation(reservationKey, LAB_ID, CONFIRMED, FIVE_CREDITS_U96, 999);

        vm.prank(PROVIDER);
        harness.requestProviderPayout(LAB_ID, 10);

        (int32 score, uint32 totalEvents,) = harness.getLabReputation(LAB_ID);
        assertEq(score, int32(0));
        assertEq(totalEvents, uint32(0));
    }

    function test_requestProviderPayout_records_completion_for_checked_in_reservation() public {
        bytes32 reservationKey = keccak256("checked-in");
        harness.setExpiredPayoutReservation(reservationKey, LAB_ID, IN_USE, FIVE_CREDITS_U96, 999);

        vm.prank(PROVIDER);
        harness.requestProviderPayout(LAB_ID, 10);

        (int32 score, uint32 totalEvents,) = harness.getLabReputation(LAB_ID);
        assertEq(score, int32(1));
        assertEq(totalEvents, uint32(1));
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

        (uint256 providerReceivable,, uint256 totalReceivable,) = harness.getLabProviderReceivable(LAB_ID);
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

        (uint256 providerReceivable,, uint256 totalReceivable,) = harness.getLabProviderReceivable(LAB_ID);
        assertEq(providerReceivable, TWELVE_CREDITS);
        assertEq(totalReceivable, TWELVE_CREDITS);
    }

    function test_transitionProviderReceivableState_reverts_for_invalid_transition() public {
        harness.setProviderReceivableBucket(LAB_ID, 2, TEN_CREDITS);

        vm.prank(PROVIDER);
        vm.expectRevert("Invalid transition");
        harness.transitionProviderReceivableState(LAB_ID, 2, 5, ONE_CREDIT, bytes32("bad"));
    }

    function test_transitionProviderReceivableState_reverts_for_unauthorized_caller() public {
        harness.setProviderReceivableBucket(LAB_ID, 2, TEN_CREDITS);

        vm.prank(address(0xDEAD));
        vm.expectRevert("Not authorized");
        harness.transitionProviderReceivableState(LAB_ID, 2, 3, ONE_CREDIT, bytes32("nope"));
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
}
