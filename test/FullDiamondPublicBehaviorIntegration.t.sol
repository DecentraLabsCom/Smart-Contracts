// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.33;

import {Test} from "forge-std/Test.sol";
import {EnumerableSet} from "@openzeppelin/contracts/utils/structs/EnumerableSet.sol";
import {Diamond} from "../contracts/Diamond.sol";
import {IDiamond} from "../contracts/interfaces/IDiamond.sol";
import {IDiamondCut} from "../contracts/interfaces/IDiamondCut.sol";
import {IERC165} from "../contracts/interfaces/IERC165.sol";
import {DiamondLoupeFacet} from "../contracts/facets/diamond/DiamondLoupeFacet.sol";
import {OwnershipFacet} from "../contracts/facets/diamond/OwnershipFacet.sol";
import {ProviderFacet} from "../contracts/facets/ProviderFacet.sol";
import {InstitutionFacet} from "../contracts/facets/reservation/institutional/InstitutionFacet.sol";
import {
    InstitutionalOrgRegistryFacet
} from "../contracts/facets/reservation/institutional/InstitutionalOrgRegistryFacet.sol";
import {InstitutionalTreasuryFacet} from "../contracts/facets/reservation/institutional/InstitutionalTreasuryFacet.sol";
import {IntentRegistryFacet} from "../contracts/facets/IntentRegistryFacet.sol";
import {LabAdminFacet} from "../contracts/facets/lab/LabAdminFacet.sol";
import {LabFacet} from "../contracts/facets/lab/LabFacet.sol";
import {ProviderSettlementFacet} from "../contracts/facets/reservation/ProviderSettlementFacet.sol";
import {
    InstitutionalReservationQueryFacet
} from "../contracts/facets/reservation/institutional/InstitutionalReservationQueryFacet.sol";
import {ReservationCheckInFacet} from "../contracts/facets/reservation/ReservationCheckInFacet.sol";
import {ReservationStatsFacet} from "../contracts/facets/reservation/ReservationStatsFacet.sol";
import {
    AppStorage,
    LibAppStorage,
    Provider,
    Reservation,
    ProviderSettlementBatch,
    PROVIDER_ROLE
} from "../contracts/libraries/LibAppStorage.sol";
import {
    IntentMeta,
    IntentState,
    ReservationIntentPayload,
    ActionIntentPayload
} from "../contracts/libraries/IntentTypes.sol";
import {LibIntent} from "../contracts/libraries/LibIntent.sol";
import {FullDiamondFixture} from "./FullDiamondFixture.sol";

/// @dev Test-only state seeder. It is added after the production cut and is never
/// part of the production fixture or selector manifest.
contract FullDiamondPublicBehaviorSeedFacet {
    using EnumerableSet for EnumerableSet.Bytes32Set;

    function seedReservation(
        bytes32 reservationKey,
        bytes32 reservationId,
        address renter,
        address institution,
        uint256 labId,
        uint32 start,
        uint32 end,
        uint8 status,
        bytes32 pucHash
    ) external {
        AppStorage storage s = LibAppStorage.diamondStorage();
        Reservation storage reservation = s.reservations[reservationKey];
        reservation.labId = labId;
        reservation.renter = renter;
        reservation.price = 100;
        reservation.labProvider = institution;
        reservation.status = status;
        reservation.start = start;
        reservation.end = end;
        reservation.requestPeriodStart = uint64(block.timestamp);
        reservation.requestPeriodDuration = 1 days;
        reservation.payerInstitution = institution;
        reservation.collectorInstitution = institution;
        reservation.providerShare = 60;

        s.reservationIdByKey[reservationKey] = reservationId;
        s.reservationKeyById[reservationId] = reservationKey;
        s.reservationHistoryById[reservationId] = reservation;
        s.reservationPucHash[reservationId] = pucHash;

        address trackingKey = address(uint160(uint256(keccak256(abi.encodePacked(institution, pucHash)))));
        s.renters[renter].add(reservationKey);
        s.renters[trackingKey].add(reservationKey);
        s.reservationKeysByToken[labId].add(reservationKey);
        s.reservationKeysByTokenAndUser[labId][renter].add(reservationKey);
        s.reservationKeysByTokenAndUser[labId][trackingKey].add(reservationKey);
        s.activeReservationByTokenAndUser[labId][renter] = reservationKey;
        s.activeReservationByTokenAndUser[labId][trackingKey] = reservationKey;
        s.activeReservationCountByTokenAndUser[labId][renter] = 1;
        s.activeReservationCountByTokenAndUser[labId][trackingKey] = 1;
        s.labActiveReservationCount[labId] = 1;
        s.providerActiveReservationCount[institution] = 1;
        s.totalReservationsCount = 1;
    }

    function seedSettlementBatch(
        bytes32 batchId,
        uint256 labId,
        uint256 amount
    ) external {
        AppStorage storage s = LibAppStorage.diamondStorage();
        s.providerSettlementBatches[batchId] = ProviderSettlementBatch({
            labId: labId,
            totalAmount: amount,
            remainingAmount: amount,
            scopeRoot: keccak256(abi.encode("scope", batchId)),
            createdAt: uint64(block.timestamp),
            claimedAt: 0,
            status: 1,
            resolutionReferenceHash: bytes32(0),
            resolutionActor: address(0),
            resolutionAt: 0
        });
        s.providerSettlementQueue[labId] = amount;
    }
}

contract FullDiamondPublicBehaviorIntegrationTest is Test, FullDiamondFixture {
    Diamond internal diamond;
    FullDiamondPublicBehaviorSeedFacet internal seed;

    address internal constant SECOND_PROVIDER = address(0xBEEF);
    address internal constant THIRD_PROVIDER = address(0xCAFE);
    address internal constant LAB_PROVIDER = SECOND_PROVIDER;
    address internal constant INSTITUTION = address(0xD00D);
    address internal constant RESERVATION_USER = address(0xF00D);
    bytes32 internal constant PUC_HASH = keccak256("surface-user@example.test");

    function setUp() public {
        diamond = _deployFullDiamond();
        FullDiamondPublicBehaviorSeedFacet seedImplementation = new FullDiamondPublicBehaviorSeedFacet();

        IDiamond.FacetCut[] memory cuts = new IDiamond.FacetCut[](1);
        bytes4[] memory selectors = new bytes4[](2);
        selectors[0] = FullDiamondPublicBehaviorSeedFacet.seedReservation.selector;
        selectors[1] = FullDiamondPublicBehaviorSeedFacet.seedSettlementBatch.selector;
        cuts[0] = IDiamond.FacetCut({
            facetAddress: address(seedImplementation), action: IDiamond.FacetCutAction.Add, functionSelectors: selectors
        });
        IDiamondCut(address(diamond)).diamondCut(cuts, address(0), "");
        seed = FullDiamondPublicBehaviorSeedFacet(address(diamond));

        ProviderFacet(address(diamond)).addProvider("Surface Provider", LAB_PROVIDER, "surface@example.test", "ES", "");
    }

    function test_loupe_and_ownership_cover_the_two_step_owner_flow() public {
        assertFalse(DiamondLoupeFacet(address(diamond)).supportsInterface(bytes4(0xffffffff)));

        address newOwner = address(0x123456);
        OwnershipFacet(address(diamond)).transferOwnership(newOwner);
        assertEq(OwnershipFacet(address(diamond)).pendingOwner(), newOwner);

        vm.prank(newOwner);
        OwnershipFacet(address(diamond)).acceptOwnership();
        assertEq(OwnershipFacet(address(diamond)).owner(), newOwner);
    }

    function test_provider_and_institution_queries_cover_paginated_surfaces() public {
        ProviderFacet provider = ProviderFacet(address(diamond));
        provider.addProvider("Third Provider", THIRD_PROVIDER, "third@example.test", "ES", "");

        (Provider[] memory providers, uint256 providerTotal) = provider.getLabProvidersPaginated(0, 10);
        assertEq(providerTotal, 3);
        assertEq(providers.length, 3);
        assertTrue(provider.hasRole(PROVIDER_ROLE, LAB_PROVIDER));
        assertEq(provider.getRoleAdmin(PROVIDER_ROLE), bytes32(0));

        (address[] memory institutions, uint256 institutionTotal) =
            InstitutionFacet(address(diamond)).getInstitutionsPaginated(0, 10);
        assertEq(institutionTotal, 3);
        assertEq(institutions.length, 3);
        assertEq(InstitutionFacet(address(diamond)).getAllInstitutions().length, 3);
    }

    function test_institutional_organization_admin_and_owner_paths_round_trip() public {
        InstitutionFacet institution = InstitutionFacet(address(diamond));
        InstitutionalOrgRegistryFacet registry = InstitutionalOrgRegistryFacet(address(diamond));
        bytes32 firstHash = keccak256("example.edu");
        bytes32 secondHash = keccak256("second.example.edu");

        institution.provisionInstitution(INSTITUTION, "Example.EDU", "https://first.example.test");
        institution.provisionInstitution(INSTITUTION, "second.example.edu", "");

        registry.adminSetSchacHomeOrganizationBackend(INSTITUTION, "example.edu", "https://admin.example.test");
        vm.prank(INSTITUTION);
        registry.setSchacHomeOrganizationBackend("example.edu", "https://institution.example.test");

        assertEq(registry.getInstitutionWalletByOrganizationHash(firstHash), INSTITUTION);
        (address firstOwner, string memory firstName) = registry.getOrganizationByHash(firstHash);
        assertEq(firstOwner, INSTITUTION);
        assertEq(firstName, "example.edu");
        assertEq(registry.getSchacHomeOrganizationBackend("EXAMPLE.EDU"), "https://institution.example.test");

        bytes32[] memory hashes = registry.getOrganizationHashesByInstitution(INSTITUTION);
        (bytes32[] memory hashPage, uint256 hashTotal) =
            registry.getOrganizationHashesByInstitutionPaginated(INSTITUTION, 0, 10);
        (string[] memory organizations, uint256 organizationTotal) =
            registry.getRegisteredSchacHomeOrganizationsPaginated(INSTITUTION, 0, 10);
        assertEq(hashes.length, 2);
        assertEq(hashPage.length, 2);
        assertEq(hashTotal, 2);
        assertEq(organizationTotal, 2);
        assertEq(organizations.length, 2);
        assertEq(registry.getInstitutionWalletByOrganizationHash(secondHash), INSTITUTION);

        vm.prank(INSTITUTION);
        registry.unregisterSchacHomeOrganization("second.example.edu");
        registry.adminUnregisterSchacHomeOrganization(INSTITUTION, "example.edu");

        assertEq(registry.getInstitutionWalletByOrganizationHash(firstHash), address(0));
        assertEq(registry.getInstitutionWalletByOrganizationHash(secondHash), address(0));
    }

    function test_institutional_treasury_reads_and_backend_lifecycle() public {
        InstitutionalTreasuryFacet treasury = InstitutionalTreasuryFacet(address(diamond));
        vm.warp(2000);

        uint256 limit = treasury.getInstitutionalUserLimit(address(this));
        uint256 period = treasury.getInstitutionalSpendingPeriod(address(this));
        (uint256 spent, uint256 periodStart) = treasury.getInstitutionalUserSpendingData(address(this), PUC_HASH);
        uint256 remaining = treasury.getInstitutionalUserRemainingAllowance(address(this), PUC_HASH);
        (
            uint256 currentSpent,
            uint256 historicalSpent,
            uint256 financialLimit,
            uint256 financialRemaining,
            uint256 financialPeriodStart,
            uint256 financialPeriodEnd,
            uint256 financialPeriodDuration
        ) = treasury.getInstitutionalUserFinancialStats(address(this), PUC_HASH);

        assertGt(limit, 0);
        assertGt(period, 0);
        assertEq(spent, 0);
        assertEq(periodStart, financialPeriodStart);
        assertEq(remaining, limit);
        assertEq(currentSpent, 0);
        assertEq(historicalSpent, 0);
        assertEq(financialLimit, limit);
        assertEq(financialRemaining, remaining);
        assertEq(financialPeriodEnd, financialPeriodStart + financialPeriodDuration);
        assertEq(financialPeriodDuration, period);

        treasury.resetInstitutionalSpendingPeriod();
        treasury.adminResetBackend(address(this), THIRD_PROVIDER);
        treasury.revokeBackend();
        treasury.adminResetBackend(address(this), address(this));
    }

    function test_intent_registry_checks_nonce_and_rejects_invalid_signatures() public {
        IntentRegistryFacet registry = IntentRegistryFacet(address(diamond));
        vm.warp(3000);
        assertEq(registry.nextIntentNonce(address(this)), 0);

        ActionIntentPayload memory actionPayload = ActionIntentPayload({
            executor: address(this),
            schacHomeOrganization: "example.edu",
            pucHash: PUC_HASH,
            assertionHash: bytes32(0),
            labId: 1,
            reservationKey: bytes32(0),
            uri: "ipfs://surface",
            price: 1,
            maxBatch: 0,
            accessURI: "access",
            accessKey: "key",
            tokenURI: "",
            resourceType: 0
        });
        IntentMeta memory actionMeta = IntentMeta({
            requestId: keccak256("surface-action-intent"),
            signer: address(this),
            executor: address(this),
            action: 1,
            payloadHash: LibIntent.hashActionPayloadPublic(actionPayload),
            nonce: 0,
            requestedAt: uint64(block.timestamp),
            expiresAt: uint64(block.timestamp + 1 days),
            state: IntentState.None
        });

        vm.expectRevert();
        registry.registerActionIntent(actionMeta, actionPayload, bytes("invalid"));

        ReservationIntentPayload memory reservationPayload = ReservationIntentPayload({
            executor: address(this),
            schacHomeOrganization: "example.edu",
            pucHash: PUC_HASH,
            assertionHash: bytes32(0),
            labId: 1,
            start: uint32(block.timestamp + 1 days),
            end: uint32(block.timestamp + 1 days + 1 hours),
            price: 1,
            reservationKey: keccak256("surface-reservation-intent")
        });
        IntentMeta memory reservationMeta = IntentMeta({
            requestId: keccak256("surface-reservation-intent"),
            signer: address(this),
            executor: address(this),
            action: 8,
            payloadHash: LibIntent.hashReservationPayload(reservationPayload),
            nonce: 0,
            requestedAt: uint64(block.timestamp),
            expiresAt: uint64(block.timestamp + 1 days),
            state: IntentState.None
        });

        vm.expectRevert();
        registry.registerReservationIntent(reservationMeta, reservationPayload, bytes("invalid"));
        assertEq(registry.nextIntentNonce(address(this)), 0);
    }

    function test_lab_queries_and_reservation_reads_cover_empty_and_seeded_state() public {
        uint256 labId = _createListedLab();
        LabFacet lab = LabFacet(address(diamond));
        vm.warp(4000);

        assertEq(lab.symbol(), "LABS");
        assertTrue(lab.isTokenListed(labId));
        assertTrue(lab.checkAvailable(labId, block.timestamp + 10, block.timestamp + 20));
        (uint32 foundStart, uint32 foundEnd) = lab.findReservationAt(labId, uint32(block.timestamp));
        assertEq(foundStart, 0);
        assertEq(foundEnd, 0);
        assertEq(lab.getNextExpiration(labId), 0);
        assertFalse(lab.isLabBusy(labId));
        assertFalse(lab.hasActiveBooking(bytes32(0), RESERVATION_USER));

        bytes32 reservationKey = keccak256("surface-seeded-reservation");
        bytes32 reservationId = keccak256("surface-seeded-reservation-id");
        uint32 start = uint32(block.timestamp - 10);
        uint32 end = uint32(block.timestamp + 100);
        seed.seedReservation(
            reservationKey, reservationId, RESERVATION_USER, address(this), labId, start, end, 1, PUC_HASH
        );

        Reservation memory labReservation = lab.getReservation(reservationKey);
        assertEq(labReservation.renter, RESERVATION_USER);
        assertEq(lab.userOfReservation(reservationKey), RESERVATION_USER);
        assertTrue(lab.hasActiveBooking(reservationKey, RESERVATION_USER));
    }

    function test_lab_erc721_transfer_and_approval_paths_work_through_diamond() public {
        ProviderFacet provider = ProviderFacet(address(diamond));
        provider.addProvider("Third Provider", THIRD_PROVIDER, "third@example.test", "ES", "");
        uint256 labId = _createListedLab();
        LabFacet lab = LabFacet(address(diamond));

        vm.prank(SECOND_PROVIDER);
        lab.setApprovalForAll(address(this), true);
        assertTrue(lab.isApprovedForAll(SECOND_PROVIDER, address(this)));

        vm.prank(SECOND_PROVIDER);
        lab.transferFrom(SECOND_PROVIDER, THIRD_PROVIDER, labId);
        assertEq(lab.ownerOf(labId), THIRD_PROVIDER);

        vm.prank(THIRD_PROVIDER);
        lab.safeTransferFrom(THIRD_PROVIDER, SECOND_PROVIDER, labId);
        assertEq(lab.ownerOf(labId), SECOND_PROVIDER);

        vm.prank(SECOND_PROVIDER);
        lab.safeTransferFrom(SECOND_PROVIDER, THIRD_PROVIDER, labId, hex"1234");
        assertEq(lab.ownerOf(labId), THIRD_PROVIDER);
    }

    function test_reservation_queries_stats_and_emergency_review_read_share_storage() public {
        uint256 labId = _createListedLab();
        vm.warp(5000);
        bytes32 reservationKey = keccak256("surface-query-reservation");
        bytes32 reservationId = keccak256("surface-query-reservation-id");
        uint32 start = uint32(block.timestamp - 10);
        uint32 end = uint32(block.timestamp + 100);
        seed.seedReservation(
            reservationKey, reservationId, RESERVATION_USER, address(this), labId, start, end, 1, PUC_HASH
        );

        InstitutionalReservationQueryFacet queries = InstitutionalReservationQueryFacet(address(diamond));
        assertEq(queries.getInstitutionalUserReservationCount(address(this), PUC_HASH), 1);
        assertEq(queries.getInstitutionalUserReservationByIndex(address(this), PUC_HASH, 0), reservationKey);
        assertTrue(queries.hasInstitutionalUserActiveBooking(address(this), PUC_HASH, labId));
        assertEq(queries.getInstitutionalUserActiveReservationKey(address(this), PUC_HASH, labId), reservationKey);
        assertEq(queries.getInstitutionalUserActiveCount(address(this), PUC_HASH, labId), 1);

        Reservation memory current = queries.getReservation(reservationKey);
        Reservation memory historical = queries.getReservationById(reservationId);
        assertEq(current.renter, RESERVATION_USER);
        assertEq(historical.renter, RESERVATION_USER);
        assertEq(queries.getReservationId(reservationKey), reservationId);
        assertEq(queries.getLabActiveReservationCount(labId), 1);

        ReservationStatsFacet stats = ReservationStatsFacet(address(diamond));
        assertEq(stats.reservationsOf(RESERVATION_USER), 1);
        assertEq(stats.reservationKeyOfUserByIndex(RESERVATION_USER, 0), reservationKey);
        assertEq(stats.getActiveReservationKeyForUser(labId, RESERVATION_USER), reservationKey);

        (
            bool settlementExcluded,
            uint8 reasonCode,
            address executor,
            uint64 checkedInAt,
            address reviewer,
            uint64 reviewedAt
        ) = ReservationCheckInFacet(address(diamond)).getEmergencyCheckInReview(reservationKey);
        assertFalse(settlementExcluded);
        assertEq(reasonCode, 0);
        assertEq(executor, address(0));
        assertEq(checkedInAt, 0);
        assertEq(reviewer, address(0));
        assertEq(reviewedAt, 0);
    }

    function test_provider_settlement_resolution_paths_update_audit_state() public {
        vm.warp(6000);
        bytes32 batchId = keccak256("surface-settlement-batch");
        bytes32 claimId = keccak256("surface-settlement-claim");
        bytes32 resolution = keccak256("surface-settlement-resolution");
        seed.seedSettlementBatch(batchId, 1, 500);

        ProviderSettlementFacet settlement = ProviderSettlementFacet(address(diamond));
        assertEq(settlement.getProviderSettlementClaimApprovalReferenceHash(claimId), bytes32(0));
        (bytes32 claimResolution, address claimActor, uint64 claimTimestamp) =
            settlement.getProviderSettlementClaimResolution(claimId);
        assertEq(claimResolution, bytes32(0));
        assertEq(claimActor, address(0));
        assertEq(claimTimestamp, 0);

        settlement.disputeSettlementBatch(batchId, resolution);
        (bytes32 batchResolution, address batchActor, uint64 batchTimestamp) =
            settlement.getProviderSettlementBatchResolution(batchId);
        assertEq(batchResolution, resolution);
        assertEq(batchActor, address(this));
        assertGt(batchTimestamp, 0);
    }

    function testFuzz_empty_lab_availability_is_stable(
        uint32 offset,
        uint32 duration
    ) public {
        vm.assume(duration > 0);
        uint256 labId = _createListedLab();
        uint256 start = block.timestamp + uint256(offset) + 1;
        uint256 end = start + uint256(duration);
        LabFacet lab = LabFacet(address(diamond));

        assertTrue(lab.checkAvailable(labId, start, end));
        assertFalse(lab.isLabBusy(labId));
        assertEq(lab.getNextExpiration(labId), 0);
    }

    function _createListedLab() internal returns (uint256 labId) {
        vm.prank(LAB_PROVIDER);
        LabAdminFacet(address(diamond))
            .addAndListLabWithPucHash(
                "ipfs://surface-lab", 1, "https://access.example.test", "surface-key", 0, PUC_HASH
            );
        return 1;
    }
}
