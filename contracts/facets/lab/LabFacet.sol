// SPDX-License-Identifier: GPL-3.0-or-later
pragma solidity ^0.8.31;

import {ERC721Upgradeable} from "@openzeppelin/contracts-upgradeable/token/ERC721/ERC721Upgradeable.sol";
import {ERC721EnumerableUpgradeable} from "@openzeppelin/contracts-upgradeable/token/ERC721/extensions/ERC721EnumerableUpgradeable.sol";
import {IERC721Upgradeable} from "@openzeppelin/contracts-upgradeable/token/ERC721/IERC721Upgradeable.sol";
import {EnumerableSet} from "@openzeppelin/contracts/utils/structs/EnumerableSet.sol";
import {AppStorage} from "../../libraries/LibAppStorage.sol";
import {LibAccessControlEnumerable} from "../../libraries/LibAccessControlEnumerable.sol";
import {ReservableToken} from "../../abstracts/ReservableToken.sol";

using EnumerableSet for EnumerableSet.Bytes32Set;
using EnumerableSet for EnumerableSet.AddressSet;


/// @title LabFacet Contract
/// @author
/// - Juan Luis Ramos Villalón
/// - Luis de la Torre Cubillo
/// @notice This contract is part of a diamond architecture and implements the ERC721 standard.
/// @dev This contract is an ERC721 token implementation for managing Labs.
///      It extends the functionality of ERC721EnumerableUpgradeable and integrates with custom libraries
///      for application-specific storage and access control.
///      Throughout the contract, `labId` and `tokenId` are used interchangeably and refer to the same identifier.
///      This convention is followed for compatibility with the ERC721 standard and to maintain homogeneity
///      across overridden functions from OpenZeppelin's implementation.
/// @notice The contract allows Lab Providers to add, update, delete, and manage Labs, which are represented as NFTs.
///         Each Lab has associated metadata, including a URI, price, authentication details, and access information.
/// @custom:security Only authorized Lab Providers can perform certain actions, such as adding or updating Labs.
/// @custom:security The contract uses OpenZeppelin's AccessControlEnumerable for role-based access control.
contract LabFacet is ERC721EnumerableUpgradeable, ReservableToken {
    using LibAccessControlEnumerable for AppStorage;

    /// @dev Maximum number of reservation indices to clean up during NFT transfer
    /// @notice Higher values reduce memory leaks but increase gas cost
    uint256 private constant _MAX_CLEANUP_PER_TRANSFER = 100;
    
    /// @dev Emitted when a new lab is added to the system.
    /// @param _labId The unique identifier of the lab.
    /// @param _provider The address of the provider adding the lab.
    /// @param _uri The URI containing metadata or details about the lab.
    /// @param _price The price associated with the lab, represented as a uint96.
    /// @param _auth The authorization details for the lab.
    /// @param _accessUri The URI used to access the lab's services.
    /// @param _accessKey The access key required to interact with the lab.
    event LabAdded(
        uint256 indexed _labId,
        address indexed _provider,
        string _uri,
        uint96 _price,
        string _auth,
        string _accessUri,
        string _accessKey
    );

    /// @dev Emitted when a lab is updated.
    /// @param _labId The unique identifier of the lab.
    /// @param _uri The updated URI of the lab.
    /// @param _price The updated price of the lab.
    /// @param _auth The updated authorization details for the lab.
    /// @param _accessUri The updated URI for accessing the lab.
    /// @param _accessKey The updated access key required to interact with the lab.
    event LabUpdated(
        uint256 indexed _labId,
        string _uri,
        uint96 _price,
        string _auth,
        string _accessUri,
        string _accessKey
    );

    /// @dev Emitted when a lab is deleted.
    /// @param _labId The unique identifier of the lab.
    event LabDeleted(uint256 indexed _labId);

    /// @dev Emitted when a lab is transferred and its provider changes
    /// @param reservationKey The unique identifier of the affected reservation
    /// @param labId The unique identifier of the lab
    /// @param oldProvider The previous provider address
    /// @param newProvider The new provider address
    event ReservationProviderUpdated(
        bytes32 indexed reservationKey,
        uint256 indexed labId,
        address indexed oldProvider,
        address newProvider
    );

    /// @notice Intent lifecycle event for lab operations
    event LabIntentProcessed(bytes32 indexed requestId, uint256 labId, string action, address provider, bool success, string reason);

    /// @dev Emitted when the URI of a lab is set.
    /// @param _labId The unique identifier of the lab.
    /// @param _uri The URI of the lab.
    event LabURISet(uint256 indexed _labId, string _uri);

    // NOTE: _consumeLabIntent moved to LabIntentFacet

    /// @dev Modifier to restrict access to functions that can only be executed by the LabProvider.
    ///      Ensures that the caller is authorized as the LabProvider before proceeding.
    /// @notice Throws an error if the caller is not the designated LabProvider.
    modifier isLabProvider() {
        _isLabProvider();
        _;
    }

    function _isLabProvider() internal view {
        require(
            _s()._isLabProvider(msg.sender),
            "Only one LabProvider can perform this action"
        );
    }

    /// @dev Constructor for the LabFacet contract.
    /// Currently, this constructor does not perform any specific initialization.
    constructor() {}

    /// @dev Initializes the contract with a given name and symbol.
    /// This function is intended to be called only once, during the contract deployment.
    /// It sets up the ERC721 token with the provided name and symbol.
    /// @param _name The name of the ERC721 token.
    /// @param _symbol The symbol of the ERC721 token.
    function initialize(
        string memory _name,
        string memory _symbol
    ) public initializer {
        __ERC721_init(_name, _symbol);
    }

    /// @notice Adds a new Lab with the specified details.
    /// @dev This function increments the Lab ID, mints a new token for the Lab,
    ///      and stores the Lab's details in the contract's state.
    ///      labId is incremented AFTER successful mint to avoid ID gaps on mint failures.
    /// @param _uri The URI of the Lab, providing metadata or additional information.
    /// @param _price The price of the Lab in the smallest unit of the currency.
    // NOTE: addLab(), addAndListLab(), updateLab(), deleteLab(), setTokenURI(), listLab(), unlistLab()
    // moved to LabAdminFacet for contract size optimization

    // NOTE: addLabWithIntent(), addAndListLabWithIntent(), updateLabWithIntent(), deleteLabWithIntent(),
    // setTokenURIWithIntent(), listLabWithIntent(), unlistLabWithIntent() moved to LabIntentFacet

    // NOTE: getLab() and getLabsPaginated() moved to LabQueryFacet

    /// @notice Helper function called by LabAdminFacet to mint tokens
    /// @dev Only callable through diamond delegatecall from LabAdminFacet
    function safeMintTo(address to, uint256 tokenId) external {
        // This will be called via delegatecall, so msg.sender is the original caller
        // The LabAdminFacet already validates isLabProvider
        _safeMint(to, tokenId);
    }

    /// @notice Helper function called by LabAdminFacet to burn tokens
    /// @dev Only callable through diamond delegatecall from LabAdminFacet  
    function burnToken(uint256 tokenId) external {
        _burn(tokenId);
    }

    /// @notice Returns the URI for a given token ID.
    function tokenURI(
        uint256 _labId
    ) public view override exists(_labId) returns (string memory) {
         return _s().labs[_labId].uri;
    }

    /// @notice Checks if a lab has any uncollected reservations
    function _hasActiveBookings(uint256 _labId) internal view returns (bool) {
        AppStorage storage s = _s();
        return s.labActiveReservationCount[_labId] > 0 || s.pendingProviderPayout[_labId] > 0;
    }

    /// @notice Approves a specific address to manage the given token ID.
    /// @dev Overrides the `approve` function from both IERC721Upgradeable and ERC721Upgradeable.
    ///      Ensures that only a LabProvider can be approved for the token.
    /// @param _to The address to be approved.
    /// @param _tokenId The ID of the token to approve.
    /// @custom:require `_to` must be a LabProvider as determined by `_isLabProvider`.
    /// @custom:throws Reverts if `_to` is not a LabProvider.
    function approve(
        address _to,
        uint256 _tokenId
    ) public virtual override(IERC721Upgradeable, ERC721Upgradeable) {
        require(
            _s()._isLabProvider(_to),
            "Only one LabProvider can be approved"
        );
        // Proceed with the standard approval process
        super.approve(_to, _tokenId);
    }

    /// @notice Overrides the `setApprovalForAll` function to enforce a restriction on approvals.
    /// @dev Ensures that only a LabProvider can be approved as an operator.
    /// @param _operator The address of the operator to be approved or disapproved.
    /// @param _approved A boolean indicating whether the operator is approved (`true`) or disapproved (`false`).
    /// @custom:require `_operator` must be a LabProvider as determined by `_s()._isLabProvider`.
    /// @custom:override Overrides the `setApprovalForAll` function from both `IERC721Upgradeable` and `ERC721Upgradeable`.
    function setApprovalForAll(
        address _operator,
        bool _approved
    ) public virtual override(IERC721Upgradeable, ERC721Upgradeable) {
        require(
            _s()._isLabProvider(_operator),
            "Only one LabProvider can be approved"
        );
        // Proceed with the standard approval process
        super.setApprovalForAll(_operator, _approved);
    }

    /// @dev Internal hook executed before transfers/mints/burns to enforce provider/stake rules
    ///      and migrate reservation bookkeeping on ownership changes.
    function _beforeTokenTransfer(
        address from,
        address to,
        uint256 tokenId,
        uint256 batchSize
    ) internal virtual override(ERC721EnumerableUpgradeable) {
        AppStorage storage s = _s();
        require(batchSize == 1, "Batch transfers not supported");
        
        if (to != address(0)) {
            // If not a burn operation, require recipient to be a provider
            require(s._isLabProvider(to), "Only one Lab owner can receive Lab");
        }

        // from != address(0) means it's not a mint
        // to != address(0) means it's not a burn
        if (from != address(0) && to != address(0)) {
            _handleListingOnTransfer(s, from, to, tokenId);
            _migrateReservationsOnTransfer(s, from, to, tokenId);
        }

        super._beforeTokenTransfer(from, to, tokenId, batchSize);
    }

    function _handleListingOnTransfer(
        AppStorage storage s,
        address from,
        address to,
        uint256 tokenId
    ) internal {
        if (!s.tokenStatus[tokenId]) {
            return;
        }

        s.tokenStatus[tokenId] = false;

        if (s.providerStakes[from].listedLabsCount > 0) {
            s.providerStakes[from].listedLabsCount--;
        }

        emit LabUnlisted(tokenId, from);

        uint256 recipientListedCount = s.providerStakes[to].listedLabsCount;
        if (recipientListedCount == 0) {
            return;
        }

        uint256 requiredStake = calculateRequiredStake(to, recipientListedCount);
        uint256 currentStake = s.providerStakes[to].stakedAmount;

        require(
            currentStake >= requiredStake,
            "Recipient lacks sufficient stake for their current listings"
        );
    }

    function _migrateReservationsOnTransfer(
        AppStorage storage s,
        address from,
        address to,
        uint256 tokenId
    ) internal {
        EnumerableSet.Bytes32Set storage labReservations = s.reservationKeysByToken[tokenId];
        uint256 reservationCount = labReservations.length();
        require(
            reservationCount <= _MAX_CLEANUP_PER_TRANSFER,
            "Too many active reservations to transfer"
        );

        bool hasActiveReservation;

        for (uint256 i = 0; i < reservationCount;) {
            bytes32 key = labReservations.at(i);

            // Cache status in memory to save SLOAD
            uint8 status = s.reservations[key].status;

            // Prevent transferring labs with pending reservations to avoid owner ambush
            if (status == _PENDING) {
                revert("Pending reservations block transfer");
            }

            // Migrate _CONFIRMED, _IN_USE and _COMPLETED reservations to new lab owner.
            // The new owner inherits the right to collect pending funds earned by the lab.
            // _PENDING reservations don't have provider assigned yet.
            // _COLLECTED/_CANCELLED are terminal states and don't need migration.
            if (status == _CONFIRMED || status == _IN_USE || status == _COMPLETED) {
                hasActiveReservation = true;
                s.reservations[key].labProvider = to;
                s.reservations[key].collectorInstitution =
                    s.institutionalBackends[to] != address(0) ? to : address(0);

                if (s.providerActiveReservationCount[from] > 0) {
                    s.providerActiveReservationCount[from]--;
                }
                s.providerActiveReservationCount[to]++;

                emit ReservationProviderUpdated(key, tokenId, from, to);
            }

            unchecked { ++i; }
        }

        // Preserve or extend unstake lock on new owner to prevent lock-bypass via transfer
        uint256 fromLast = s.providerStakes[from].lastReservationTimestamp;
        uint256 toLast = s.providerStakes[to].lastReservationTimestamp;
        uint256 newLast = fromLast > toLast ? fromLast : toLast;
        if (hasActiveReservation && block.timestamp > newLast) {
            newLast = block.timestamp;
        }
        if (newLast > toLast) {
            s.providerStakes[to].lastReservationTimestamp = newLast;
        }
    }
}
