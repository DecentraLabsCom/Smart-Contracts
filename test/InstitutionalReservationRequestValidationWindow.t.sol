// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.33;

import "forge-std/Test.sol";
import "../contracts/facets/reservation/institutional/InstitutionalReservationRequestValidationFacet.sol";
import "../contracts/libraries/LibAppStorage.sol";
import "../contracts/libraries/LibReservationConfig.sol";
import "./LibERC721StorageTestHelper.sol";

contract InstitutionalReservationRequestValidationWindowHarness is InstitutionalReservationRequestValidationFacet {
    function configureLab(
        uint256 labId,
        address provider
    ) external {
        AppStorage storage s = LibAppStorage.diamondStorage();
        s.tokenStatus[labId] = true;
        s.providerNetworkStatus[provider] = ProviderNetworkStatus.ACTIVE;
        LibERC721StorageTestHelper.setOwnerForTest(labId, provider);
    }

    function configureBackend(
        address institution,
        address backend
    ) external {
        LibAppStorage.diamondStorage().institutionalBackends[institution] = backend;
    }
}

contract InstitutionalReservationRequestValidationWindowTest is Test {
    InstitutionalReservationRequestValidationWindowHarness private harness;

    address private constant INSTITUTION = address(0xBEEF);
    address private constant BACKEND = address(0xCAFE);
    address private constant PROVIDER = address(0xD00D);
    uint256 private constant LAB_ID = 7;
    bytes32 private constant PUC_HASH = keccak256("puc");

    function setUp() public {
        harness = new InstitutionalReservationRequestValidationWindowHarness();
        harness.configureBackend(INSTITUTION, BACKEND);
        harness.configureLab(LAB_ID, PROVIDER);
    }

    function test_rejects_start_before_confirmation_lead_time() public {
        vm.warp(1_000_000);
        uint32 start = uint32(block.timestamp + LibReservationConfig.RESERVATION_CONFIRMATION_LEAD_TIME - 1);

        vm.prank(BACKEND);
        vm.expectRevert();
        harness.validateInstRequest(INSTITUTION, PUC_HASH, LAB_ID, start, start + 1 hours);
    }

    function test_protocol_window_leaves_finality_budget() public pure {
        assertEq(LibReservationConfig.PENDING_REQUEST_TTL, 5 minutes);
        assertEq(LibReservationConfig.RESERVATION_CONFIRMATION_LEAD_TIME, 10 minutes);
        assertGe(
            LibReservationConfig.RESERVATION_CONFIRMATION_LEAD_TIME,
            LibReservationConfig.PENDING_REQUEST_TTL + 5 minutes
        );
    }

    function test_accepts_start_at_confirmation_lead_time() public {
        vm.warp(1_000_000);
        uint32 start = uint32(block.timestamp + LibReservationConfig.RESERVATION_CONFIRMATION_LEAD_TIME);

        vm.prank(BACKEND);
        harness.validateInstRequest(INSTITUTION, PUC_HASH, LAB_ID, start, start + 1 hours);
    }
}
