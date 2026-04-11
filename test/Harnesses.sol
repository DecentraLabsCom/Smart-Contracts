// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.33;

import "../contracts/facets/reservation/institutional/InstitutionalReservationCancellationFacet.sol";
import "../contracts/facets/reservation/institutional/InstitutionalReservationConfirmationFacet.sol";
import "../contracts/libraries/LibAppStorage.sol";
import "../contracts/libraries/LibERC721Storage.sol";
import "./LibERC721StorageTestHelper.sol";
import "../contracts/libraries/LibInstitutionalReservation.sol";
import "../contracts/libraries/LibLabAdmin.sol";

contract InstReservationHarness {
    using EnumerableSet for EnumerableSet.Bytes32Set;

    // expose helpers to set storage
    function setBackend(
        address inst,
        address backend
    ) external {
        AppStorage storage s = LibAppStorage.diamondStorage();
        s.institutionalBackends[inst] = backend;
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

        // reservation index sets are not required by these unit tests and are omitted in the harness
    }

    // wrappers to call the internal library functions
    function cancelReservationRequestWrapper(
        address institutionalProvider,
        string calldata puc,
        bytes32 reservationKey
    ) external returns (uint256) {
        return LibInstitutionalReservation.cancelReservationRequest(institutionalProvider, puc, reservationKey);
    }

    function cancelBookingWrapper(
        address institutionalProvider,
        string calldata puc,
        bytes32 reservationKey
    ) external returns (uint256) {
        return LibInstitutionalReservation.cancelBooking(institutionalProvider, puc, reservationKey);
    }

    // capture refunds
    address public lastRefundProvider;
    string public lastRefundPuc;
    uint256 public lastRefundAmount;

    function refundToInstitutionalTreasury(
        address provider,
        string calldata puc,
        uint256 amount
    ) external {
        lastRefundProvider = provider;
        lastRefundPuc = puc;
        lastRefundAmount = amount;
    }

    // helper to read reservation status from the harness storage
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

        // reservation index sets are not required by these unit tests and are omitted in the harness
    }

    // for test: implement spendFromInstitutionalTreasury to succeed
    address public lastSpentProvider;
    string public lastSpentPuc;
    uint256 public lastSpentAmount;

    function spendFromInstitutionalTreasury(
        address provider,
        string calldata puc,
        uint256 amount
    ) external {
        lastSpentProvider = provider;
        lastSpentPuc = puc;
        lastSpentAmount = amount;
        // succeed silently
    }

    // expose confirm wrapper
    function ext_confirmWithPuc(
        address inst,
        bytes32 key,
        string calldata puc
    ) external {
        // call external interface to emulate external actor
        this.confirmInstitutionalReservationRequestWithPuc(inst, key, puc);
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

    function setLabResourceType(
        uint256 labId,
        uint8 resourceType
    ) external {
        AppStorage storage s = LibAppStorage.diamondStorage();
        s.labs[labId].resourceType = resourceType;
    }
}

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
