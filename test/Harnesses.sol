// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.33;

import "../contracts/facets/reservation/institutional/InstitutionalReservationCancellationFacet.sol";
import "../contracts/facets/reservation/wallet/WalletReservationCancellationFacet.sol";
import "../contracts/facets/reservation/institutional/InstitutionalReservationConfirmationFacet.sol";
import "../contracts/libraries/LibAppStorage.sol";
import "../contracts/libraries/LibInstitutionalReservation.sol";
import "../contracts/libraries/LibReservationCancellation.sol";
import "../contracts/libraries/LibWalletReservationCancellation.sol";

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

contract WalletCancellationHarness is WalletReservationCancellationFacet {
    // simple ERC721 ownerOf stub
    mapping(uint256 => address) public owners;

    function setOwner(
        uint256 tokenId,
        address owner
    ) external {
        owners[tokenId] = owner;
    }

    function ownerOf(
        uint256 tokenId
    ) external view returns (address) {
        return owners[tokenId];
    }

    // minimal ERC20 transfer stub so SafeERC20 calls succeed in tests
    function transfer(
        address to,
        uint256 amount
    ) external pure returns (bool) {
        // succeed silently
        to;
        amount;
        return true;
    }

    function setLabTokenAddress(
        address addr
    ) external {
        AppStorage storage s = LibAppStorage.diamondStorage();
        s.labTokenAddress = addr;
    }

    function setReservation(
        bytes32 key,
        address renter,
        uint96 price,
        uint8 status,
        uint256 labId,
        uint32 start,
        address payerInstitution,
        string calldata puc
    ) external {
        AppStorage storage s = LibAppStorage.diamondStorage();
        Reservation storage r = s.reservations[key];
        r.renter = renter;
        r.price = price;
        r.status = status;
        r.labId = labId;
        r.start = start;
        r.end = start + 3600; // default 1 hour
        r.payerInstitution = payerInstitution;
        if (bytes(puc).length > 0) s.reservationPucHash[key] = keccak256(bytes(puc));

        // set the request period to avoid confirmation being denied due to period slippage
        uint256 d = s.institutionalSpendingPeriod[payerInstitution];
        if (d == 0) d = LibAppStorage.DEFAULT_SPENDING_PERIOD;
        uint256 rsAligned = block.timestamp - (block.timestamp % d);
        r.requestPeriodStart = uint64(rsAligned);
        r.requestPeriodDuration = uint64(d);

        // reservation index sets are not required by these unit tests and are omitted in the harness
    }

    // public wrapper to call internal cancel booking
    function ext_cancelBooking(
        bytes32 key
    ) external {
        LibWalletReservationCancellation.cancelBooking(key);
    }

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

    // staking stub used by confirm flow
    function updateLastReservation(
        address
    ) external {}

    // stubbed required stake so provider checks pass in tests
    function calculateRequiredStake(
        address,
        uint256
    ) external pure returns (uint256) {
        return 0;
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

    function setProviderStake(
        address p,
        uint256 amount
    ) external {
        AppStorage storage s = LibAppStorage.diamondStorage();
        s.providerStakes[p].stakedAmount = amount;
    }

    function getReservationStatus(
        bytes32 key
    ) external view returns (uint8) {
        AppStorage storage s = LibAppStorage.diamondStorage();
        return s.reservations[key].status;
    }
}
