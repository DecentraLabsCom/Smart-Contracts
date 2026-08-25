// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.33;

import {Diamond, DiamondArgs} from "../contracts/Diamond.sol";
import {IDiamond} from "../contracts/interfaces/IDiamond.sol";
import {IDiamondCut} from "../contracts/interfaces/IDiamondCut.sol";
import {DiamondCutFacet} from "../contracts/facets/diamond/DiamondCutFacet.sol";
import {DiamondLoupeFacet} from "../contracts/facets/diamond/DiamondLoupeFacet.sol";
import {OwnershipFacet} from "../contracts/facets/diamond/OwnershipFacet.sol";
import {InitFacet} from "../contracts/facets/InitFacet.sol";
import {ProviderFacet} from "../contracts/facets/ProviderFacet.sol";
import {ServiceCreditFacet} from "../contracts/facets/ServiceCreditFacet.sol";
import {IntentRegistryFacet} from "../contracts/facets/IntentRegistryFacet.sol";
import {InstitutionFacet} from "../contracts/facets/reservation/institutional/InstitutionFacet.sol";
import {
    InstitutionalOrgRegistryFacet
} from "../contracts/facets/reservation/institutional/InstitutionalOrgRegistryFacet.sol";
import {InstitutionalTreasuryFacet} from "../contracts/facets/reservation/institutional/InstitutionalTreasuryFacet.sol";
import {LabFacet} from "../contracts/facets/lab/LabFacet.sol";
import {LabAdminFacet} from "../contracts/facets/lab/LabAdminFacet.sol";
import {LabIntentFacet} from "../contracts/facets/lab/LabIntentFacet.sol";
import {LabQueryFacet} from "../contracts/facets/lab/LabQueryFacet.sol";
import {LabReputationFacet} from "../contracts/facets/lab/LabReputationFacet.sol";
import {ProviderSettlementFacet} from "../contracts/facets/reservation/ProviderSettlementFacet.sol";
import {
    InstitutionalReservationRequestValidationFacet
} from "../contracts/facets/reservation/institutional/InstitutionalReservationRequestValidationFacet.sol";
import {
    InstitutionalReservationRequestCreationFacet
} from "../contracts/facets/reservation/institutional/InstitutionalReservationRequestCreationFacet.sol";
import {
    InstitutionalReservationConfirmationFacet
} from "../contracts/facets/reservation/institutional/InstitutionalReservationConfirmationFacet.sol";
import {
    InstitutionalReservationCancellationFacet
} from "../contracts/facets/reservation/institutional/InstitutionalReservationCancellationFacet.sol";
import {
    InstitutionalReservationQueryFacet
} from "../contracts/facets/reservation/institutional/InstitutionalReservationQueryFacet.sol";
import {
    InstitutionalReservationFacet
} from "../contracts/facets/reservation/institutional/InstitutionalReservationFacet.sol";
import {ReservationCheckInFacet} from "../contracts/facets/reservation/ReservationCheckInFacet.sol";
import {ReservationStatsFacet} from "../contracts/facets/reservation/ReservationStatsFacet.sol";
import {ReservationDenialFacet} from "../contracts/facets/reservation/ReservationDenialFacet.sol";
import {ReservationIntentFacet} from "../contracts/facets/reservation/ReservationIntentFacet.sol";
import {
    ReservationIntentCancellationFacet
} from "../contracts/facets/reservation/ReservationIntentCancellationFacet.sol";
import {ReservationSessionFacet} from "../contracts/facets/reservation/ReservationSessionFacet.sol";

/// @notice Reusable in-memory deployment of the production Diamond cut.
/// @dev The selector lists mirror selectors/diamond.json. Test-only facets are
/// intentionally excluded so proxy tests cannot accidentally use test storage
/// helpers as part of the production surface.
abstract contract FullDiamondFixture {
    uint256 internal constant PRODUCTION_FACET_COUNT = 28;
    uint256 internal constant PRODUCTION_SELECTOR_COUNT = 201;

    function _deployFullDiamond() internal returns (Diamond diamond) {
        address[] memory implementations = _deployFacetImplementations();
        IDiamond.FacetCut[] memory initialCut = new IDiamond.FacetCut[](1);
        initialCut[0] = _cut(implementations[0], _DiamondCutSelectors());
        diamond = new Diamond(initialCut, DiamondArgs({owner: address(this), init: address(0), initCalldata: ""}));

        IDiamond.FacetCut[] memory cuts = _buildCuts(implementations);
        IDiamondCut(address(diamond)).diamondCut(cuts, address(0), "");
        InitFacet(address(diamond)).initializeDiamond("Admin", "admin@example.test", "ES", "Labs", "LABS");
    }

    function _deployFacetImplementations() private returns (address[] memory implementations) {
        implementations = new address[](PRODUCTION_FACET_COUNT);
        implementations[0] = address(new DiamondCutFacet());
        implementations[1] = address(new DiamondLoupeFacet());
        implementations[2] = address(new OwnershipFacet());
        implementations[3] = address(new InitFacet());
        implementations[4] = address(new ProviderFacet());
        implementations[5] = address(new ServiceCreditFacet());
        implementations[6] = address(new IntentRegistryFacet());
        implementations[7] = address(new InstitutionFacet());
        implementations[8] = address(new InstitutionalOrgRegistryFacet());
        implementations[9] = address(new InstitutionalTreasuryFacet());
        implementations[10] = address(new LabFacet());
        implementations[11] = address(new LabAdminFacet());
        implementations[12] = address(new LabIntentFacet());
        implementations[13] = address(new LabQueryFacet());
        implementations[14] = address(new LabReputationFacet());
        implementations[15] = address(new ProviderSettlementFacet());
        implementations[16] = address(new InstitutionalReservationRequestValidationFacet());
        implementations[17] = address(new InstitutionalReservationRequestCreationFacet());
        implementations[18] = address(new InstitutionalReservationConfirmationFacet());
        implementations[19] = address(new InstitutionalReservationCancellationFacet());
        implementations[20] = address(new InstitutionalReservationQueryFacet());
        implementations[21] = address(new InstitutionalReservationFacet());
        implementations[22] = address(new ReservationCheckInFacet());
        implementations[23] = address(new ReservationStatsFacet());
        implementations[24] = address(new ReservationDenialFacet());
        implementations[25] = address(new ReservationIntentFacet());
        implementations[26] = address(new ReservationIntentCancellationFacet());
        implementations[27] = address(new ReservationSessionFacet());
    }

    function _buildCuts(
        address[] memory implementations
    ) private pure returns (IDiamond.FacetCut[] memory cuts) {
        cuts = new IDiamond.FacetCut[](PRODUCTION_FACET_COUNT - 1);
        cuts[0] = _cut(implementations[1], _DiamondLoupeSelectors());
        cuts[1] = _cut(implementations[2], _OwnershipSelectors());
        cuts[2] = _cut(implementations[3], _InitSelectors());
        cuts[3] = _cut(implementations[4], _ProviderSelectors());
        cuts[4] = _cut(implementations[5], _ServiceCreditSelectors());
        cuts[5] = _cut(implementations[6], _IntentRegistrySelectors());
        cuts[6] = _cut(implementations[7], _InstitutionSelectors());
        cuts[7] = _cut(implementations[8], _InstitutionalOrgRegistrySelectors());
        cuts[8] = _cut(implementations[9], _InstitutionalTreasurySelectors());
        cuts[9] = _cut(implementations[10], _LabSelectors());
        cuts[10] = _cut(implementations[11], _LabAdminSelectors());
        cuts[11] = _cut(implementations[12], _LabIntentSelectors());
        cuts[12] = _cut(implementations[13], _LabQuerySelectors());
        cuts[13] = _cut(implementations[14], _LabReputationSelectors());
        cuts[14] = _cut(implementations[15], _ProviderSettlementSelectors());
        cuts[15] = _cut(implementations[16], _InstitutionalReservationRequestValidationSelectors());
        cuts[16] = _cut(implementations[17], _InstitutionalReservationRequestCreationSelectors());
        cuts[17] = _cut(implementations[18], _InstitutionalReservationConfirmationSelectors());
        cuts[18] = _cut(implementations[19], _InstitutionalReservationCancellationSelectors());
        cuts[19] = _cut(implementations[20], _InstitutionalReservationQuerySelectors());
        cuts[20] = _cut(implementations[21], _InstitutionalReservationSelectors());
        cuts[21] = _cut(implementations[22], _ReservationCheckInSelectors());
        cuts[22] = _cut(implementations[23], _ReservationStatsSelectors());
        cuts[23] = _cut(implementations[24], _ReservationDenialSelectors());
        cuts[24] = _cut(implementations[25], _ReservationIntentSelectors());
        cuts[25] = _cut(implementations[26], _ReservationIntentCancellationSelectors());
        cuts[26] = _cut(implementations[27], _ReservationSessionSelectors());
    }

    function _cut(
        address facet,
        bytes4[] memory selectors
    ) private pure returns (IDiamond.FacetCut memory cut) {
        cut =
            IDiamond.FacetCut({facetAddress: facet, action: IDiamond.FacetCutAction.Add, functionSelectors: selectors});
    }

    function _selector(
        string memory signature
    ) private pure returns (bytes4) {
        return bytes4(keccak256(bytes(signature)));
    }

    function _DiamondCutSelectors() private pure returns (bytes4[] memory selectors) {
        selectors = new bytes4[](1);
        selectors[0] = _selector("diamondCut((address,uint8,bytes4[])[],address,bytes)");
    }

    function _DiamondLoupeSelectors() private pure returns (bytes4[] memory selectors) {
        selectors = new bytes4[](5);
        selectors[0] = _selector("facetAddress(bytes4)");
        selectors[1] = _selector("facetAddresses()");
        selectors[2] = _selector("facetFunctionSelectors(address)");
        selectors[3] = _selector("facets()");
        selectors[4] = _selector("supportsInterface(bytes4)");
    }

    function _OwnershipSelectors() private pure returns (bytes4[] memory selectors) {
        selectors = new bytes4[](4);
        selectors[0] = _selector("acceptOwnership()");
        selectors[1] = _selector("owner()");
        selectors[2] = _selector("pendingOwner()");
        selectors[3] = _selector("transferOwnership(address)");
    }

    function _InitSelectors() private pure returns (bytes4[] memory selectors) {
        selectors = new bytes4[](1);
        selectors[0] = _selector("initializeDiamond(string,string,string,string,string)");
    }

    function _ProviderSelectors() private pure returns (bytes4[] memory selectors) {
        selectors = new bytes4[](15);
        selectors[0] = _selector("DEFAULT_ADMIN_ROLE()");
        selectors[1] = _selector("addProvider(string,address,string,string,string)");
        selectors[2] = _selector("provisionProvider(string,address,string,string,string,string,string)");
        selectors[3] = _selector("getLabProvidersPaginated(uint256,uint256)");
        selectors[4] = _selector("getProviderAuthURI(address)");
        selectors[5] = _selector("getProviderNetworkStatus(address)");
        selectors[6] = _selector("getRoleAdmin(bytes32)");
        selectors[7] = _selector("hasRole(bytes32,address)");
        selectors[8] = _selector("initialize(string,string,string)");
        selectors[9] = _selector("isLabProvider(address)");
        selectors[10] = _selector("isProviderNetworkActive(address)");
        selectors[11] = _selector("removeProvider(address)");
        selectors[12] = _selector("setProviderAuthURI(string)");
        selectors[13] = _selector("setProviderNetworkStatus(address,uint8)");
        selectors[14] = _selector("updateProvider(string,string,string)");
    }

    function _ServiceCreditSelectors() private pure returns (bytes4[] memory selectors) {
        selectors = new bytes4[](16);
        selectors[0] = _selector("availableBalanceOf(address)");
        selectors[1] = _selector("cancelCredits(address,uint256,bytes32)");
        selectors[2] = _selector("cancelCreditsBatch(address,uint256,bytes32,uint256)");
        selectors[3] = _selector("captureLockedCredits(address,uint256,bytes32)");
        selectors[4] = _selector("compactCreditLots(address)");
        selectors[5] = _selector("expireCredits(address,uint256)");
        selectors[6] = _selector("finalizeReservationCreditAllocations(address,bytes32)");
        selectors[7] = _selector("getCreditLots(address,uint256,uint256)");
        selectors[8] = _selector("getCreditMovements(address,uint256,uint256)");
        selectors[9] = _selector("getCreditReservationAllocations(address,bytes32,uint256,uint256)");
        selectors[10] = _selector("ledgerAdjustCredits(address,int256,bytes32)");
        selectors[11] = _selector("lockCredits(address,uint256,bytes32)");
        selectors[12] = _selector("lockedBalanceOf(address)");
        selectors[13] = _selector("mintCredits(address,uint256,bytes32,uint256,uint48)");
        selectors[14] = _selector("releaseLockedCredits(address,uint256,bytes32)");
        selectors[15] = _selector("totalBalanceOf(address)");
    }

    function _IntentRegistrySelectors() private pure returns (bytes4[] memory selectors) {
        selectors = new bytes4[](6);
        selectors[0] = _selector("cancelIntent(bytes32)");
        selectors[1] = _selector("expireIntent(bytes32)");
        selectors[2] = _selector("getIntent(bytes32)");
        selectors[3] = _selector("nextIntentNonce(address)");
        selectors[4] = _selector(
            "registerActionIntent((bytes32,address,address,uint8,bytes32,uint256,uint64,uint64,uint8),(address,string,bytes32,bytes32,uint256,bytes32,string,uint96,uint96,string,string,string,uint8),bytes)"
        );
        selectors[5] = _selector(
            "registerReservationIntent((bytes32,address,address,uint8,bytes32,uint256,uint64,uint64,uint8),(address,string,bytes32,bytes32,uint256,uint32,uint32,uint96,bytes32),bytes)"
        );
    }

    function _InstitutionSelectors() private pure returns (bytes4[] memory selectors) {
        selectors = new bytes4[](4);
        selectors[0] = _selector("getAllInstitutions()");
        selectors[1] = _selector("getInstitutionsPaginated(uint256,uint256)");
        selectors[2] = _selector("provisionInstitution(address,string,string)");
        selectors[3] = _selector("revokeInstitutionRole(address,string)");
    }

    function _InstitutionalOrgRegistrySelectors() private pure returns (bytes4[] memory selectors) {
        selectors = new bytes4[](14);
        selectors[0] = _selector("adminRegisterSchacHomeOrganization(address,string)");
        selectors[1] = _selector("adminSetSchacHomeOrganizationBackend(address,string,string)");
        selectors[2] = _selector("adminUnregisterSchacHomeOrganization(address,string)");
        selectors[3] = _selector("getInstitutionWalletByOrganizationHash(bytes32)");
        selectors[4] = _selector("getOrganizationByHash(bytes32)");
        selectors[5] = _selector("getOrganizationHashesByInstitution(address)");
        selectors[6] = _selector("getOrganizationHashesByInstitutionPaginated(address,uint256,uint256)");
        selectors[7] = _selector("getRegisteredSchacHomeOrganizations(address)");
        selectors[8] = _selector("getRegisteredSchacHomeOrganizationsPaginated(address,uint256,uint256)");
        selectors[9] = _selector("getSchacHomeOrganizationBackend(string)");
        selectors[10] = _selector("registerSchacHomeOrganization(string)");
        selectors[11] = _selector("resolveSchacHomeOrganization(string)");
        selectors[12] = _selector("setSchacHomeOrganizationBackend(string,string)");
        selectors[13] = _selector("unregisterSchacHomeOrganization(string)");
    }

    function _InstitutionalTreasurySelectors() private pure returns (bytes4[] memory selectors) {
        selectors = new bytes4[](18);
        selectors[0] = _selector("adminResetBackend(address,address)");
        selectors[1] = _selector("authorizeBackend(address)");
        selectors[2] = _selector("checkInstitutionalTreasuryAvailability(address,bytes32,uint256)");
        selectors[3] = _selector("getAuthorizedBackend(address)");
        selectors[4] = _selector("getInstitutionalSpendingPeriod(address)");
        selectors[5] = _selector("getInstitutionalTreasuryBalance(address)");
        selectors[6] = _selector("getInstitutionalUserFinancialStats(address,bytes32)");
        selectors[7] = _selector("getInstitutionalUserLimit(address)");
        selectors[8] = _selector("getInstitutionalUserRemainingAllowance(address,bytes32)");
        selectors[9] = _selector("getInstitutionalUserSpendingData(address,bytes32)");
        selectors[10] = _selector("getInstitutionalUserSpent(address,bytes32)");
        selectors[11] = _selector("refundToInstitutionalTreasuryForReservation(address,bytes32,bytes32,uint256)");
        selectors[12] = _selector("resetInstitutionalSpendingPeriod()");
        selectors[13] = _selector("revokeBackend()");
        selectors[14] = _selector("setInstitutionalSpendingPeriod(uint256)");
        selectors[15] = _selector("setInstitutionalUserLimit(uint256)");
        selectors[16] = _selector("spendFromInstitutionalTreasury(address,bytes32,uint256)");
        selectors[17] = _selector("spendFromInstitutionalTreasuryForReservation(address,bytes32,bytes32,uint256)");
    }

    function _LabSelectors() private pure returns (bytes4[] memory selectors) {
        selectors = new bytes4[](27);
        selectors[0] = _selector("approve(address,uint256)");
        selectors[1] = _selector("balanceOf(address)");
        selectors[2] = _selector("burnToken(uint256)");
        selectors[3] = _selector("checkAvailable(uint256,uint256,uint256)");
        selectors[4] = _selector("findAvailableSlots(uint256,uint32,uint32,uint32)");
        selectors[5] = _selector("findReservationAt(uint256,uint32)");
        selectors[6] = _selector("getApproved(uint256)");
        selectors[7] = _selector("getBookedSlots(uint256)");
        selectors[8] = _selector("getBookedSlotsPaginated(uint256,uint256,uint256)");
        selectors[9] = _selector("getNextAvailableSlot(uint256,uint32)");
        selectors[10] = _selector("getNextExpiration(uint256)");
        selectors[11] = _selector("getReservation(bytes32)");
        selectors[12] = _selector("hasActiveBooking(bytes32,address)");
        selectors[13] = _selector("initialize(string,string)");
        selectors[14] = _selector("isApprovedForAll(address,address)");
        selectors[15] = _selector("isLabBusy(uint256)");
        selectors[16] = _selector("isTokenListed(uint256)");
        selectors[17] = _selector("name()");
        selectors[18] = _selector("ownerOf(uint256)");
        selectors[19] = _selector("safeMintTo(address,uint256)");
        selectors[20] = _selector("safeTransferFrom(address,address,uint256)");
        selectors[21] = _selector("safeTransferFrom(address,address,uint256,bytes)");
        selectors[22] = _selector("setApprovalForAll(address,bool)");
        selectors[23] = _selector("symbol()");
        selectors[24] = _selector("tokenURI(uint256)");
        selectors[25] = _selector("transferFrom(address,address,uint256)");
        selectors[26] = _selector("userOfReservation(bytes32)");
    }

    function _LabAdminSelectors() private pure returns (bytes4[] memory selectors) {
        selectors = new bytes4[](7);
        selectors[0] = _selector("addAndListLabWithPucHash(string,uint96,string,string,uint8,bytes32)");
        selectors[1] = _selector("addLabWithPucHash(string,uint96,string,string,uint8,bytes32)");
        selectors[2] = _selector("deleteLab(uint256)");
        selectors[3] = _selector("listLab(uint256)");
        selectors[4] = _selector("setTokenURI(uint256,string)");
        selectors[5] = _selector("unlistLab(uint256)");
        selectors[6] = _selector("updateLab(uint256,string,uint96,string,string,uint8)");
    }

    function _LabIntentSelectors() private pure returns (bytes4[] memory selectors) {
        selectors = new bytes4[](7);
        selectors[0] = _selector(
            "addAndListLabWithIntent(bytes32,(address,string,bytes32,bytes32,uint256,bytes32,string,uint96,uint96,string,string,string,uint8))"
        );
        selectors[1] = _selector(
            "addLabWithIntent(bytes32,(address,string,bytes32,bytes32,uint256,bytes32,string,uint96,uint96,string,string,string,uint8))"
        );
        selectors[2] = _selector(
            "deleteLabWithIntent(bytes32,(address,string,bytes32,bytes32,uint256,bytes32,string,uint96,uint96,string,string,string,uint8))"
        );
        selectors[3] = _selector(
            "listLabWithIntent(bytes32,(address,string,bytes32,bytes32,uint256,bytes32,string,uint96,uint96,string,string,string,uint8))"
        );
        selectors[4] = _selector(
            "setTokenURIWithIntent(bytes32,(address,string,bytes32,bytes32,uint256,bytes32,string,uint96,uint96,string,string,string,uint8))"
        );
        selectors[5] = _selector(
            "unlistLabWithIntent(bytes32,(address,string,bytes32,bytes32,uint256,bytes32,string,uint96,uint96,string,string,string,uint8))"
        );
        selectors[6] = _selector(
            "updateLabWithIntent(bytes32,(address,string,bytes32,bytes32,uint256,bytes32,string,uint96,uint96,string,string,string,uint8))"
        );
    }

    function _LabQuerySelectors() private pure returns (bytes4[] memory selectors) {
        selectors = new bytes4[](11);
        selectors[0] = _selector("getLab(uint256)");
        selectors[1] = _selector("getLabAccessKey(uint256)");
        selectors[2] = _selector("getLabAccessURI(uint256)");
        selectors[3] = _selector("getLabAge(uint256)");
        selectors[4] = _selector("getLabAuthURI(uint256)");
        selectors[5] = _selector("getLabCount()");
        selectors[6] = _selector("getLabPrice(uint256)");
        selectors[7] = _selector("getLabResourceType(uint256)");
        selectors[8] = _selector("getLabsPaginated(uint256,uint256)");
        selectors[9] = _selector("getPucHash(uint256)");
        selectors[10] = _selector("isLabListed(uint256)");
    }

    function _LabReputationSelectors() private pure returns (bytes4[] memory selectors) {
        selectors = new bytes4[](6);
        selectors[0] = _selector("adjustLabReputation(uint256,int32,string)");
        selectors[1] = _selector("getLabRating(uint256)");
        selectors[2] = _selector("getLabReputation(uint256)");
        selectors[3] = _selector("getLabScore(uint256)");
        selectors[4] = _selector("setLabReputation(uint256,int32,string)");
        selectors[5] = _selector("tokenURIWithReputation(uint256)");
    }

    function _ProviderSettlementSelectors() private pure returns (bytes4[] memory selectors) {
        selectors = new bytes4[](18);
        selectors[0] = _selector("getLabProviderReceivable(uint256)");
        selectors[1] = _selector("getLabProviderReceivableLifecycle(uint256)");
        selectors[2] = _selector("getLabProviderReceivablePaginated(uint256,uint256,uint256)");
        selectors[3] = _selector("getLatestProviderSettlementBatch(uint256)");
        selectors[4] = _selector("getProviderSettlementBatch(bytes32)");
        selectors[5] = _selector("getProviderSettlementClaim(bytes32)");
        selectors[6] = _selector("getProviderSettlementClaimApprovalReferenceHash(bytes32)");
        selectors[7] = _selector("getProviderSettlementBatchResolution(bytes32)");
        selectors[8] = _selector("getProviderSettlementClaimResolution(bytes32)");
        selectors[9] = _selector("submitProviderSettlementClaim(bytes32,uint256,uint256,bytes32,bytes32)");
        selectors[10] = _selector("approveProviderSettlementClaim(bytes32,bytes32)");
        selectors[11] = _selector("recordProviderSettlementClaimPayment(bytes32,bytes32,bytes32)");
        selectors[12] = _selector("disputeSettlementBatch(bytes32,bytes32)");
        selectors[13] = _selector("reverseSettlementBatch(bytes32,bytes32)");
        selectors[14] = _selector("disputeSettlementClaim(bytes32,bytes32)");
        selectors[15] = _selector("reverseSettlementClaim(bytes32,bytes32)");
        selectors[16] = _selector("requestProviderPayout(uint256,uint256)");
        selectors[17] = _selector("transitionProviderReceivableState(uint256,uint8,uint8,uint256,bytes32)");
    }

    function _InstitutionalReservationRequestValidationSelectors() private pure returns (bytes4[] memory selectors) {
        selectors = new bytes4[](1);
        selectors[0] = _selector("validateInstRequest(address,bytes32,uint256,uint32,uint32)");
    }

    function _InstitutionalReservationRequestCreationSelectors() private pure returns (bytes4[] memory selectors) {
        selectors = new bytes4[](2);
        selectors[0] =
            _selector("createInstReservation((address,address,uint256,uint32,uint32,bytes32,bytes32,address))");
        selectors[1] = _selector("recordRecentInstReservation(uint256,address,bytes32,uint32)");
    }

    function _InstitutionalReservationConfirmationSelectors() private pure returns (bytes4[] memory selectors) {
        selectors = new bytes4[](1);
        selectors[0] = _selector("confirmInstitutionalReservationRequestWithPucHash(address,bytes32,bytes32)");
    }

    function _InstitutionalReservationCancellationSelectors() private pure returns (bytes4[] memory selectors) {
        selectors = new bytes4[](4);
        selectors[0] = _selector("cancelConfirmedBookingByProvider(bytes32,uint8)");
        selectors[1] = _selector("cancelInstitutionalBookingWithPucHash(address,bytes32,bytes32)");
        selectors[2] = _selector("cancelInstitutionalReservationRequest(address,bytes32,bytes32)");
        selectors[3] = _selector("previewInstitutionalBookingCancellation(bytes32)");
    }

    function _InstitutionalReservationQuerySelectors() private pure returns (bytes4[] memory selectors) {
        selectors = new bytes4[](14);
        selectors[0] = _selector("getInstitutionalUserActiveCount(address,bytes32,uint256)");
        selectors[1] = _selector("getInstitutionalUserActiveReservationKey(address,bytes32,uint256)");
        selectors[2] = _selector("getInstitutionalUserReservationByIndex(address,bytes32,uint256)");
        selectors[3] = _selector("getInstitutionalUserReservationCount(address,bytes32)");
        selectors[4] = _selector("getLabActiveReservationCount(uint256)");
        selectors[5] = _selector("getLabReservationCount(uint256)");
        selectors[6] = _selector("getConcurrentReservationCount(uint256,uint32,uint32)");
        selectors[7] = _selector("getReservationId(bytes32)");
        selectors[8] = _selector("getReservationById(bytes32)");
        selectors[9] = _selector("getReservationOfTokenByIndex(uint256,uint256)");
        selectors[10] = _selector("getReservationPucHash(bytes32)");
        selectors[11] = _selector("getReservationsOfToken(uint256)");
        selectors[12] = _selector("getReservationsOfTokenPaginated(uint256,uint256,uint256)");
        selectors[13] = _selector("hasInstitutionalUserActiveBooking(address,bytes32,uint256)");
    }

    function _InstitutionalReservationSelectors() private pure returns (bytes4[] memory selectors) {
        selectors = new bytes4[](1);
        selectors[0] = _selector("releaseInstitutionalExpiredReservations(address,bytes32,uint256,uint256)");
    }

    function _ReservationCheckInSelectors() private pure returns (bytes4[] memory selectors) {
        selectors = new bytes4[](4);
        selectors[0] = _selector("emergencyCheckIn(bytes32,uint8)");
        selectors[1] = _selector("getEmergencyCheckInReview(bytes32)");
        selectors[2] = _selector("reviewEmergencyCheckIn(bytes32)");
        selectors[3] = _selector("checkInReservationWithSignature(bytes32,address,bytes32,uint64,bytes)");
    }

    function _ReservationStatsSelectors() private pure returns (bytes4[] memory selectors) {
        selectors = new bytes4[](5);
        selectors[0] = _selector("getActiveReservationKeyForUser(uint256,address)");
        selectors[1] = _selector("getReservationStats(uint256,uint32,uint32)");
        selectors[2] = _selector("getReservationStatsPaginated(uint256,uint32,uint32,uint32,uint256)");
        selectors[3] = _selector("reservationKeyOfUserByIndex(address,uint256)");
        selectors[4] = _selector("reservationsOf(address)");
    }

    function _ReservationDenialSelectors() private pure returns (bytes4[] memory selectors) {
        selectors = new bytes4[](2);
        selectors[0] = _selector("denyReservationRequest(bytes32)");
        selectors[1] = _selector("denyReservationRequestWithReason(bytes32,uint8)");
    }

    function _ReservationIntentSelectors() private pure returns (bytes4[] memory selectors) {
        selectors = new bytes4[](2);
        selectors[0] = _selector(
            "institutionalDirectBookingWithIntent(bytes32,(address,string,bytes32,bytes32,uint256,uint32,uint32,uint96,bytes32))"
        );
        selectors[1] = _selector(
            "institutionalReservationRequestWithIntent(bytes32,(address,string,bytes32,bytes32,uint256,uint32,uint32,uint96,bytes32))"
        );
    }

    function _ReservationIntentCancellationSelectors() private pure returns (bytes4[] memory selectors) {
        selectors = new bytes4[](2);
        selectors[0] = _selector(
            "cancelInstitutionalBookingWithIntent(bytes32,(address,string,bytes32,bytes32,uint256,bytes32,string,uint96,uint96,string,string,string,uint8))"
        );
        selectors[1] = _selector(
            "cancelInstitutionalReservationRequestWithIntent(bytes32,(address,string,bytes32,bytes32,uint256,uint32,uint32,uint96,bytes32))"
        );
    }

    function _ReservationSessionSelectors() private pure returns (bytes4[] memory selectors) {
        selectors = new bytes4[](3);
        selectors[0] = _selector("getReservationSessionStarted(bytes32)");
        selectors[1] = _selector("hasReservationSessionStarted(bytes32)");
        selectors[2] = _selector(
            "markSessionStarted((address,bytes32,string,bytes32,string,string,string,uint64,bytes32,bytes32,bytes32,bytes))"
        );
    }
}
