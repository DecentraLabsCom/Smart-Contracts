// SPDX-License-Identifier: MIT
pragma solidity ^0.8.33;

import {Test} from "forge-std/Test.sol";
import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import {ERC721} from "@openzeppelin/contracts/token/ERC721/ERC721.sol";
import {EnumerableSet} from "@openzeppelin/contracts/utils/structs/EnumerableSet.sol";
import {WalletPayoutFacet} from "../contracts/facets/reservation/wallet/WalletPayoutFacet.sol";
import {AppStorage, LibAppStorage} from "../contracts/libraries/LibAppStorage.sol";
import {LibAccessControlEnumerable} from "../contracts/libraries/LibAccessControlEnumerable.sol";

contract ProviderReceivableMockToken is ERC20 {
    constructor() ERC20("Mock Lab Token", "MLAB") {}

    function mint(
        address to,
        uint256 amount
    ) external {
        _mint(to, amount);
    }
}

contract ProviderReceivableHarness is ERC721, WalletPayoutFacet {
    using LibAccessControlEnumerable for AppStorage;
    using EnumerableSet for EnumerableSet.AddressSet;

    constructor() ERC721("Labs", "LAB") {}

    function initialize(
        address labToken,
        address admin,
        address provider,
        uint256 labId
    ) external {
        AppStorage storage s = LibAppStorage.diamondStorage();
        s.labTokenAddress = labToken;
        s.DEFAULT_ADMIN_ROLE = keccak256("DEFAULT_ADMIN_ROLE");
        s.roleMembers[s.DEFAULT_ADMIN_ROLE].add(admin);
        s._addProviderRole(provider, "provider", "provider@example.com", "ES", "");
        _mint(provider, labId);
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

    function updateLastReservation(
        address
    ) external {}
}

contract ProviderReceivableAliasesTest is Test {
    ProviderReceivableMockToken internal token;
    ProviderReceivableHarness internal harness;

    address internal constant PROVIDER = address(0xABCD);
    uint256 internal constant LAB_ID = 7;

    function setUp() public {
        token = new ProviderReceivableMockToken();
        harness = new ProviderReceivableHarness();
        harness.initialize(address(token), address(this), PROVIDER, LAB_ID);
    }

    function test_getLabProviderReceivable_exposes_pending_provider_bucket() public {
        harness.setPendingProviderPayout(LAB_ID, 5e6);

        (uint256 providerReceivable, uint256 deferredInstitutionalReceivable, uint256 totalReceivable, uint256 eligibleCount)
        = harness.getLabProviderReceivable(LAB_ID);

        assertEq(providerReceivable, 5e6);
        assertEq(deferredInstitutionalReceivable, 0);
        assertEq(totalReceivable, 5e6);
        assertEq(eligibleCount, 0);
    }

    function test_requestProviderPayout_moves_accrued_receivable_into_settlement_queue_without_token_transfer() public {
        harness.setPendingProviderPayout(LAB_ID, 12e6);

        vm.prank(PROVIDER);
        harness.requestProviderPayout(LAB_ID, 10);

        assertEq(token.balanceOf(PROVIDER), 0);
        assertEq(token.balanceOf(address(harness)), 0);

        (uint256 providerReceivable,, uint256 totalReceivable,) = harness.getLabProviderReceivable(LAB_ID);
        assertEq(providerReceivable, 12e6);
        assertEq(totalReceivable, 12e6);

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
        assertEq(settlementQueued, 12e6);
        assertEq(invoicedReceivable, 0);
        assertEq(approvedReceivable, 0);
        assertEq(paidReceivable, 0);
        assertEq(reversedReceivable, 0);
        assertEq(disputedReceivable, 0);
    }

    function test_getLabProviderReceivable_includes_unsettled_lifecycle_buckets() public {
        harness.setProviderReceivableBucket(LAB_ID, 1, 5e6);
        harness.setProviderReceivableBucket(LAB_ID, 2, 7e6);
        harness.setProviderReceivableBucket(LAB_ID, 3, 11e6);
        harness.setProviderReceivableBucket(LAB_ID, 4, 13e6);
        harness.setProviderReceivableBucket(LAB_ID, 7, 17e6);
        harness.setProviderReceivableBucket(LAB_ID, 5, 19e6);
        harness.setProviderReceivableBucket(LAB_ID, 6, 23e6);

        (uint256 providerReceivable,, uint256 totalReceivable,) = harness.getLabProviderReceivable(LAB_ID);
        assertEq(providerReceivable, 53e6);
        assertEq(totalReceivable, 53e6);
    }

    function test_transitionProviderReceivableState_moves_between_lifecycle_buckets() public {
        harness.setProviderReceivableBucket(LAB_ID, 2, 12e6);

        vm.prank(PROVIDER);
        harness.transitionProviderReceivableState(LAB_ID, 2, 3, 5e6, bytes32("invoice-001"));

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
        assertEq(settlementQueued, 7e6);
        assertEq(invoicedReceivable, 5e6);
        assertEq(approvedReceivable, 0);
        assertEq(paidReceivable, 0);
        assertEq(reversedReceivable, 0);
        assertEq(disputedReceivable, 0);

        (uint256 providerReceivable,, uint256 totalReceivable,) = harness.getLabProviderReceivable(LAB_ID);
        assertEq(providerReceivable, 12e6);
        assertEq(totalReceivable, 12e6);
    }

    function test_transitionProviderReceivableState_reverts_for_invalid_transition() public {
        harness.setProviderReceivableBucket(LAB_ID, 2, 10e6);

        vm.prank(PROVIDER);
        vm.expectRevert("Invalid transition");
        harness.transitionProviderReceivableState(LAB_ID, 2, 5, 1e6, bytes32("bad"));
    }

    function test_transitionProviderReceivableState_reverts_for_unauthorized_caller() public {
        harness.setProviderReceivableBucket(LAB_ID, 2, 10e6);

        vm.prank(address(0xDEAD));
        vm.expectRevert("Not authorized");
        harness.transitionProviderReceivableState(LAB_ID, 2, 3, 1e6, bytes32("nope"));
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
