// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.33;

import "forge-std/Test.sol";
import "../contracts/facets/lab/LabAdminFacet.sol";
import "../contracts/facets/reservation/ReservationDenialFacet.sol";
import "../contracts/facets/reservation/institutional/InstitutionalReservationConfirmationFacet.sol";
import "../contracts/facets/reservation/institutional/InstitutionalReservationFacet.sol";
import "../contracts/facets/reservation/institutional/InstitutionalReservationRequestCreationFacet.sol";
import "../contracts/libraries/LibAppStorage.sol";
import "../contracts/libraries/LibERC721Storage.sol";
import "../contracts/libraries/LibInstitutionalReservation.sol";
import "../contracts/libraries/LibTracking.sol";
import "./LibERC721StorageTestHelper.sol";

contract LabPendingReservationHarness is
    LabAdminFacet,
    ReservationDenialFacet,
    InstitutionalReservationConfirmationFacet,
    InstitutionalReservationFacet,
    InstitutionalReservationRequestCreationFacet
{
    using EnumerableSet for EnumerableSet.AddressSet;

    function seedLab(
        uint256 labId,
        address owner,
        uint96 pricePerSecond
    ) external {
        AppStorage storage s = LibAppStorage.diamondStorage();
        s.labs[labId] = LabBase({
            uri: "ipfs://lab",
            price: pricePerSecond,
            accessURI: "https://access",
            accessKey: "key",
            createdAt: uint32(block.timestamp),
            resourceType: 1
        });
        s.activeLabIds.push(labId);
        s.activeLabIndexPlusOne[labId] = s.activeLabIds.length;
        s.tokenStatus[labId] = true;
        s.labReservationIntakeStopped[labId] = false;
        s.providerNetworkStatus[owner] = ProviderNetworkStatus.ACTIVE;
        LibERC721StorageTestHelper.setOwnerForTest(labId, owner);
    }

    function setInstitution(
        address institution
    ) external {
        LibAppStorage.diamondStorage().roleMembers[INSTITUTION_ROLE].add(institution);
    }

    function setBackend(
        address institution,
        address backend
    ) external {
        LibAppStorage.diamondStorage().institutionalBackends[institution] = backend;
    }

    function ownerOf(
        uint256 labId
    ) external view returns (address) {
        return LibERC721Storage.ownerOf(labId);
    }

    function burnToken(
        uint256 labId
    ) external {
        require(msg.sender == address(this), "Only diamond can call");
        LibERC721StorageTestHelper.setOwnerForTest(labId, address(0));
    }

    function createPending(
        address institution,
        address labOwner,
        uint256 labId,
        uint32 start,
        uint32 end,
        bytes32 pucHash,
        bytes32 reservationKey
    ) external {
        this.createInstReservation(
            InstitutionalReservationRequestCreationFacet.InstInput({
                p: institution,
                o: labOwner,
                l: labId,
                s: start,
                e: end,
                u: pucHash,
                k: reservationKey,
                t: LibTracking.trackingKeyFromInstitutionHash(institution, pucHash)
            })
        );
    }

    function cancelInstitutionalReservationRequest(
        address institution,
        bytes32 pucHash,
        bytes32 reservationKey
    ) external {
        LibInstitutionalReservation.cancelReservationRequest(institution, pucHash, reservationKey);
    }

    function pendingCount(
        uint256 labId
    ) external view returns (uint256) {
        return LibAppStorage.diamondStorage().labPendingReservationCount[labId];
    }

    function activeCount(
        uint256 labId
    ) external view returns (uint256) {
        return LibAppStorage.diamondStorage().labActiveReservationCount[labId];
    }

    function totalCount() external view returns (uint256) {
        return LibAppStorage.diamondStorage().totalReservationsCount;
    }

    function checkInstitutionalTreasuryAvailability(
        address,
        bytes32,
        uint256
    ) external pure {}

    function spendFromInstitutionalTreasuryForReservation(
        address,
        bytes32,
        bytes32,
        uint256
    ) external {}

    function refundToInstitutionalTreasuryForReservation(
        address,
        bytes32,
        bytes32,
        uint256
    ) external {}
}

contract LabPendingReservationDeletionTest is Test {
    uint256 private constant LAB_ID = 1;
    uint96 private constant PRICE_PER_SECOND = 1;
    address private constant LAB_OWNER = address(0xBEEF);
    address private constant INSTITUTION = address(0xCAFE);
    bytes32 private constant PUC_HASH = keccak256("pending-user");

    LabPendingReservationHarness private harness;

    function setUp() public {
        harness = new LabPendingReservationHarness();
        harness.seedLab(LAB_ID, LAB_OWNER, PRICE_PER_SECOND);
    }

    function test_deleteLab_reverts_while_pending_request_exists() public {
        bytes32 reservationKey = keccak256("pending-delete");
        _createPending(reservationKey);

        assertEq(harness.pendingCount(LAB_ID), 1);
        assertEq(harness.activeCount(LAB_ID), 0);

        vm.prank(LAB_OWNER);
        vm.expectRevert(bytes("Cannot delete lab with uncollected reservations"));
        harness.deleteLab(LAB_ID);

        assertEq(harness.ownerOf(LAB_ID), LAB_OWNER);
    }

    function test_cancelPendingRequest_allows_delete() public {
        bytes32 reservationKey = keccak256("pending-cancel");
        _createPending(reservationKey);
        harness.setInstitution(INSTITUTION);
        harness.setBackend(INSTITUTION, INSTITUTION);

        vm.prank(INSTITUTION);
        harness.cancelInstitutionalReservationRequest(INSTITUTION, PUC_HASH, reservationKey);

        assertEq(harness.pendingCount(LAB_ID), 0);
        _deleteLab();
    }

    function test_denyPendingRequest_allows_delete() public {
        bytes32 reservationKey = keccak256("pending-deny");
        _createPending(reservationKey);

        vm.prank(LAB_OWNER);
        harness.denyReservationRequest(reservationKey);

        assertEq(harness.pendingCount(LAB_ID), 0);
        _deleteLab();
    }

    function test_expirePendingRequest_allows_delete() public {
        bytes32 reservationKey = keccak256("pending-expire");
        _createPending(reservationKey);
        harness.setInstitution(INSTITUTION);

        vm.warp(block.timestamp + 5 minutes);
        assertEq(harness.releaseInstitutionalExpiredReservations(INSTITUTION, PUC_HASH, LAB_ID, 1), 1);

        assertEq(harness.pendingCount(LAB_ID), 0);
        _deleteLab();
    }

    function test_confirmAndSettle_clears_obligations_before_delete() public {
        bytes32 reservationKey = keccak256("pending-confirm");
        uint32 start = uint32(block.timestamp + 1 days);
        uint32 end = start + 60;
        _createPending(reservationKey, start, end);
        harness.setInstitution(INSTITUTION);

        vm.prank(LAB_OWNER);
        harness.confirmInstitutionalReservationRequestWithPucHash(INSTITUTION, reservationKey, PUC_HASH);

        assertEq(harness.pendingCount(LAB_ID), 0);
        assertEq(harness.activeCount(LAB_ID), 1);

        vm.prank(LAB_OWNER);
        vm.expectRevert(bytes("Cannot delete lab with uncollected reservations"));
        harness.deleteLab(LAB_ID);

        vm.warp(uint256(end) + 1);
        assertEq(harness.releaseInstitutionalExpiredReservations(INSTITUTION, PUC_HASH, LAB_ID, 1), 1);

        assertEq(harness.pendingCount(LAB_ID), 0);
        assertEq(harness.activeCount(LAB_ID), 0);
        assertEq(harness.totalCount(), 0);
        _deleteLab();
    }

    function _createPending(
        bytes32 reservationKey
    ) private {
        uint32 start = uint32(block.timestamp + 1 days);
        _createPending(reservationKey, start, start + 60);
    }

    function _createPending(
        bytes32 reservationKey,
        uint32 start,
        uint32 end
    ) private {
        harness.createPending(INSTITUTION, LAB_OWNER, LAB_ID, start, end, PUC_HASH, reservationKey);
    }

    function _deleteLab() private {
        vm.prank(LAB_OWNER);
        harness.deleteLab(LAB_ID);

        vm.expectRevert();
        harness.ownerOf(LAB_ID);
    }
}
