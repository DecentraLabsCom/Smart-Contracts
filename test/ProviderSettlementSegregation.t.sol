// SPDX-License-Identifier: MIT
pragma solidity ^0.8.33;

import {Test} from "forge-std/Test.sol";
import {EnumerableSet} from "@openzeppelin/contracts/utils/structs/EnumerableSet.sol";
import {ProviderSettlementFacet} from "../contracts/facets/reservation/ProviderSettlementFacet.sol";
import {AppStorage, LibAppStorage, ProviderSettlementBatch} from "../contracts/libraries/LibAppStorage.sol";
import {
    SETTLEMENT_APPROVER_ROLE,
    SETTLEMENT_OPERATOR_ROLE,
    SETTLEMENT_PAYER_ROLE
} from "../contracts/libraries/LibProviderReceivable.sol";

contract ProviderSettlementSegregationHarness is ProviderSettlementFacet {
    using EnumerableSet for EnumerableSet.AddressSet;

    function initialize(
        address admin
    ) external {
        AppStorage storage s = LibAppStorage.diamondStorage();
        s.DEFAULT_ADMIN_ROLE = keccak256("DEFAULT_ADMIN_ROLE");
        s.roleMembers[s.DEFAULT_ADMIN_ROLE].add(admin);
        s.roleMembers[SETTLEMENT_OPERATOR_ROLE].add(admin);
    }

    function grantRole(
        bytes32 role,
        address account
    ) external {
        LibAppStorage.diamondStorage().roleMembers[role].add(account);
    }

    function seedQueuedBatch(
        bytes32 batchId,
        uint256 labId,
        uint256 amount
    ) external {
        AppStorage storage s = LibAppStorage.diamondStorage();
        s.providerSettlementQueue[labId] = amount;
        s.providerSettlementBatches[batchId] = ProviderSettlementBatch({
            labId: labId,
            totalAmount: amount,
            remainingAmount: amount,
            scopeRoot: keccak256(abi.encode("scope", batchId)),
            createdAt: 1,
            claimedAt: 0,
            status: 1,
            resolutionReferenceHash: bytes32(0),
            resolutionActor: address(0),
            resolutionAt: 0
        });
    }
}

contract ProviderSettlementSegregationTest is Test {
    ProviderSettlementSegregationHarness internal harness;

    address internal constant ADMIN = address(0xA11CE);
    address internal constant APPROVER = address(0xA22CE);
    address internal constant PAYER = address(0xA33CE);
    address internal constant SHARED_FINANCIAL_ACTOR = address(0xA44CE);
    uint256 internal constant LAB_ID = 7;
    uint256 internal constant AMOUNT = 50_000_000;

    function setUp() public {
        harness = new ProviderSettlementSegregationHarness();
        harness.initialize(ADMIN);
    }

    function test_approvalAndPaymentRequireDistinctRoleSpecificActors() public {
        bytes32 claimId = keccak256("claim-distinct-actors");
        bytes32 batchId = keccak256("batch-distinct-actors");
        harness.seedQueuedBatch(batchId, LAB_ID, AMOUNT);
        harness.grantRole(SETTLEMENT_APPROVER_ROLE, APPROVER);
        harness.grantRole(SETTLEMENT_PAYER_ROLE, PAYER);

        vm.prank(ADMIN);
        harness.submitProviderSettlementClaim(claimId, LAB_ID, AMOUNT, batchId, keccak256("invoice-distinct-actors"));

        vm.prank(APPROVER);
        harness.approveProviderSettlementClaim(claimId, keccak256("approval-distinct-actors"));

        vm.prank(PAYER);
        harness.recordProviderSettlementClaimPayment(
            claimId, keccak256("payment-distinct-actors"), keccak256("attestation-distinct-actors")
        );

        (,, uint8 status,,,,,,,,,,) = harness.getProviderSettlementClaim(claimId);
        assertEq(status, 3);
    }

    function test_approvalCannotBePerformedByDefaultAdminOrPayer() public {
        bytes32 claimId = keccak256("claim-approval-role");
        bytes32 batchId = keccak256("batch-approval-role");
        harness.seedQueuedBatch(batchId, LAB_ID, AMOUNT);
        harness.grantRole(SETTLEMENT_PAYER_ROLE, PAYER);

        vm.prank(ADMIN);
        harness.submitProviderSettlementClaim(claimId, LAB_ID, AMOUNT, batchId, keccak256("invoice-approval-role"));

        vm.prank(ADMIN);
        vm.expectRevert("Not authorized");
        harness.approveProviderSettlementClaim(claimId, keccak256("approval-admin"));

        vm.prank(PAYER);
        vm.expectRevert("Not authorized");
        harness.approveProviderSettlementClaim(claimId, keccak256("approval-payer"));
    }

    function test_approverCannotPayEvenWhenItAlsoHasPayerRole() public {
        bytes32 claimId = keccak256("claim-same-actor");
        bytes32 batchId = keccak256("batch-same-actor");
        harness.seedQueuedBatch(batchId, LAB_ID, AMOUNT);
        harness.grantRole(SETTLEMENT_APPROVER_ROLE, SHARED_FINANCIAL_ACTOR);
        harness.grantRole(SETTLEMENT_PAYER_ROLE, SHARED_FINANCIAL_ACTOR);

        vm.prank(ADMIN);
        harness.submitProviderSettlementClaim(claimId, LAB_ID, AMOUNT, batchId, keccak256("invoice-same-actor"));
        vm.prank(SHARED_FINANCIAL_ACTOR);
        harness.approveProviderSettlementClaim(claimId, keccak256("approval-same-actor"));

        vm.prank(SHARED_FINANCIAL_ACTOR);
        vm.expectRevert("Approver cannot pay");
        harness.recordProviderSettlementClaimPayment(
            claimId, keccak256("payment-same-actor"), keccak256("attestation-same-actor")
        );
    }
}
