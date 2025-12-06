// SPDX-License-Identifier: GPL-3.0-or-later
pragma solidity ^0.8.23;

import "@openzeppelin/contracts-upgradeable/token/ERC721/extensions/ERC721EnumerableUpgradeable.sol";
import "@openzeppelin/contracts-upgradeable/token/ERC721/IERC721Upgradeable.sol";
import "@openzeppelin/contracts/utils/structs/EnumerableSet.sol";
import {LibAppStorage, AppStorage, Lab, LabBase} from "../libraries/LibAppStorage.sol";
import {LibAccessControlEnumerable} from "../libraries/LibAccessControlEnumerable.sol";
import {LibIntent} from "../libraries/LibIntent.sol";
import {ActionIntentPayload} from "../libraries/IntentTypes.sol";
import "../abstracts/ReservableToken.sol";

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
    uint256 private constant MAX_CLEANUP_PER_TRANSFER = 100;
    
    /// @dev Emitted when a new lab is added to the system.
    /// @param _labId The unique identifier of the lab.
    /// @param _provider The address of the provider adding the lab.
    /// @param _uri The URI containing metadata or details about the lab.
    /// @param _price The price associated with the lab, represented as a uint96.
    /// @param _auth The authorization details for the lab.
    /// @param _accessURI The URI used to access the lab's services.
    /// @param _accessKey The access key required to interact with the lab.
    event LabAdded(
        uint256 indexed _labId,
        address indexed _provider,
        string _uri,
        uint96 _price,
        string _auth,
        string _accessURI,
        string _accessKey
    );

    /// @dev Emitted when a lab is updated.
    /// @param _labId The unique identifier of the lab.
    /// @param _uri The updated URI of the lab.
    /// @param _price The updated price of the lab.
    /// @param _auth The updated authorization details for the lab.
    /// @param _accessURI The updated URI for accessing the lab.
    /// @param _accessKey The updated access key required to interact with the lab.
    event LabUpdated(
        uint256 indexed _labId,
        string _uri,
        uint96 _price,
        string _auth,
        string _accessURI,
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

    /// @dev Consumes a pending intent ensuring the caller matches signer/executor
    function _consumeLabIntent(
        bytes32 requestId,
        uint8 action,
        ActionIntentPayload memory payload
    ) internal {
        require(payload.executor == msg.sender, "Executor must be caller");
        bytes32 payloadHash = LibIntent.hashActionPayload(payload);
        LibIntent.consumeIntent(requestId, action, payloadHash, msg.sender);
    }

    /// @dev Modifier to restrict access to functions that can only be executed by the LabProvider.
    ///      Ensures that the caller is authorized as the LabProvider before proceeding.
    /// @notice Throws an error if the caller is not the designated LabProvider.
    modifier isLabProvider() {
        require(
            _s()._isLabProvider(msg.sender),
            "Only one LabProvider can perform this action"
        );
        _;
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
    /// @param _auth The URI to the authentication service that issues session tokens for lab access
    /// @param _accessURI The URI used to access the laboratory's services.
    /// @param _accessKey TA public (non-sensitive) key or ID used for routing/access to the laboratory.
    /// @dev The caller of this function must have the role of a Lab provider.
    /// @dev Emits a {LabAdded} event upon successful execution.
    /// @dev Note: The lab is created but not listed. Use listToken() or addAndListLab() to make it available.
    function addLab(
        string calldata _uri,
        uint96 _price,
        string calldata _auth,
        string calldata _accessURI,
        string calldata _accessKey
    ) public isLabProvider {
        // Validate string lengths to prevent DoS attacks
        require(bytes(_uri).length > 0 && bytes(_uri).length <= 500, "Invalid URI length");
        require(bytes(_auth).length > 0 && bytes(_auth).length <= 500, "Invalid auth length");
        require(bytes(_accessURI).length > 0 && bytes(_accessURI).length <= 500, "Invalid accessURI length");
        require(bytes(_accessKey).length > 0 && bytes(_accessKey).length <= 200, "Invalid accessKey length");
        
        AppStorage storage s = _s();
        
        // Calculate next lab ID (but don't increment storage yet)
        uint256 nextLabId = s.labId + 1;
        
        // Mint the NFT first (can fail if receiver rejects)
        _safeMint(msg.sender, nextLabId);
        
        // Only increment labId in storage after successful mint
        s.labId = nextLabId;
        
        // Store lab metadata
        s.labs[nextLabId] = LabBase(
            _uri,
            _price,
            _auth,
            _accessURI,
            _accessKey
        );
        
        emit LabAdded(
            nextLabId,
            msg.sender,
            _uri,
            _price,
            _auth,
            _accessURI,
            _accessKey
        );
    }

    /// @notice Adds a new Lab via intent and emmits event with requestId.
    function addLabWithIntent(
        bytes32 requestId,
        string calldata _uri,
        uint96 _price,
        string calldata _auth,
        string calldata _accessURI,
        string calldata _accessKey
    ) external isLabProvider {
        AppStorage storage s = _s();
        uint256 nextLabId = s.labId + 1;
        ActionIntentPayload memory payload = ActionIntentPayload({
            executor: msg.sender,
            schacHomeOrganization: "",
            puc: "",
            assertionHash: bytes32(0),
            labId: nextLabId,
            reservationKey: bytes32(0),
            uri: _uri,
            price: _price,
            maxBatch: 0,
            auth: _auth,
            accessURI: _accessURI,
            accessKey: _accessKey,
            tokenURI: ""
        });
        _consumeLabIntent(requestId, LibIntent.ACTION_LAB_ADD, payload);

        addLab(_uri, _price, _auth, _accessURI, _accessKey);
        uint256 newLabId = s.labId;
        emit LabIntentProcessed(requestId, newLabId, "LAB_ADD", msg.sender, true, "");
    }

    /// @notice Adds a new Lab and immediately lists it for reservations in a single transaction.
    /// @dev This is a convenience function that combines addLab() and listToken() functionality.
    ///      Requires the provider to have sufficient staked tokens based on listed labs count.
    ///      Formula: 800 base + max(0, listedLabs - 10) * 200
    ///      labId is incremented AFTER successful mint to avoid ID gaps on mint failures.
    /// @param _uri The URI of the Lab, providing metadata or additional information.
    /// @param _price The price of the Lab in the smallest unit of the currency.
    /// @param _auth The URI to the authentication service that issues session tokens for lab access
    /// @param _accessURI The URI used to access the laboratory's services.
    /// @param _accessKey TA public (non-sensitive) key or ID used for routing/access to the laboratory.
    /// @dev The caller of this function must have the role of a Lab provider.
    /// @dev Emits both {LabAdded} and {LabListed} events upon successful execution.
    /// @dev Reverts if the provider does not have sufficient staked tokens.
    function addAndListLab(
        string calldata _uri,
        uint96 _price,
        string calldata _auth,
        string calldata _accessURI,
        string calldata _accessKey
    ) public isLabProvider {
        // Validate string lengths to prevent DoS attacks
        require(bytes(_uri).length > 0 && bytes(_uri).length <= 500, "Invalid URI length");
        require(bytes(_auth).length > 0 && bytes(_auth).length <= 500, "Invalid auth length");
        require(bytes(_accessURI).length > 0 && bytes(_accessURI).length <= 500, "Invalid accessURI length");
        require(bytes(_accessKey).length > 0 && bytes(_accessKey).length <= 200, "Invalid accessKey length");
        
        AppStorage storage s = _s();
        
        // Calculate required stake for new listed count
        uint256 newListedCount = s.providerStakes[msg.sender].listedLabsCount + 1;
        uint256 requiredStake = calculateRequiredStake(msg.sender, newListedCount);
        
        if (s.providerStakes[msg.sender].stakedAmount < requiredStake) {
            revert("Insufficient stake to list lab");
        }
        
        // Calculate next lab ID (but don't increment storage yet)
        uint256 nextLabId = s.labId + 1;
        
        // Mint the NFT first (can fail if receiver rejects)
        _safeMint(msg.sender, nextLabId);
        
        // Only increment labId in storage after successful mint
        s.labId = nextLabId;
        
        // Store lab metadata
        s.labs[nextLabId] = LabBase(
            _uri,
            _price,
            _auth,
            _accessURI,
            _accessKey
        );
        
        // Update listed count and list the lab
        s.providerStakes[msg.sender].listedLabsCount = newListedCount;
        s.tokenStatus[nextLabId] = true;
        
        emit LabAdded(
            nextLabId,
            msg.sender,
            _uri,
            _price,
            _auth,
            _accessURI,
            _accessKey
        );
        emit LabListed(nextLabId, msg.sender);
    }

    /// @notice Adds and lists a lab via intent (emits LabIntentProcessed)
    function addAndListLabWithIntent(
        bytes32 requestId,
        string calldata _uri,
        uint96 _price,
        string calldata _auth,
        string calldata _accessURI,
        string calldata _accessKey
    ) external isLabProvider {
        AppStorage storage s = _s();
        uint256 nextLabId = s.labId + 1;
        ActionIntentPayload memory payload = ActionIntentPayload({
            executor: msg.sender,
            schacHomeOrganization: "",
            puc: "",
            assertionHash: bytes32(0),
            labId: nextLabId,
            reservationKey: bytes32(0),
            uri: _uri,
            price: _price,
            maxBatch: 0,
            auth: _auth,
            accessURI: _accessURI,
            accessKey: _accessKey,
            tokenURI: ""
        });
        _consumeLabIntent(requestId, LibIntent.ACTION_LAB_ADD_AND_LIST, payload);

        addAndListLab(_uri, _price, _auth, _accessURI, _accessKey);
        uint256 newLabId = s.labId;
        emit LabIntentProcessed(requestId, newLabId, "LAB_LIST", msg.sender, true, "");
    }

    /// @notice Sets the token URI for a specific lab, used for compliance with ERC721 standards.
    /// @dev This function allows a lab provider to update the URI of a lab.
    ///      The lab must already exist, and the new URI cannot be empty.
    /// @param _labId The ID of the lab whose URI is being updated.
    /// @param _tokenURI The new URI to be set for the lab.
    /// @dev  LabURISet Emitted when the URI of a lab is successfully updated.
    function setTokenURI(
        uint256 _labId,
        string memory _tokenURI
    ) public exists(_labId) onlyTokenOwner(_labId) {
        require(bytes(_tokenURI).length > 0, "Token URI cannot be empty");

        LabBase memory lab = _s().labs[_labId];
       
        lab.uri = _tokenURI;
        _s().labs[_labId] = lab;

        emit LabURISet(_labId, _tokenURI);
    }

    /// @notice Updates URI via intent and emits LabIntentProcessed
    function setTokenURIWithIntent(
        bytes32 requestId,
        uint256 _labId,
        string calldata _tokenURI
    ) external exists(_labId) onlyTokenOwner(_labId) {
        ActionIntentPayload memory payload = ActionIntentPayload({
            executor: msg.sender,
            schacHomeOrganization: "",
            puc: "",
            assertionHash: bytes32(0),
            labId: _labId,
            reservationKey: bytes32(0),
            uri: "",
            price: 0,
            maxBatch: 0,
            auth: "",
            accessURI: "",
            accessKey: "",
            tokenURI: _tokenURI
        });
        _consumeLabIntent(requestId, LibIntent.ACTION_LAB_SET_URI, payload);

        setTokenURI(_labId, _tokenURI);
        emit LabIntentProcessed(requestId, _labId, "LAB_SET_URI", msg.sender, true, "");
    }

    /// @notice Returns the URI for a given token ID.
    /// @dev Overrides the tokenURI function to provide the URI for the specified token ID.
    /// @param _labId The ID of the token for which to retrieve the URI.
    /// @return A string representing the URI of the specified token.
    /// @dev The Lab must exist for the given token ID (i.e., the URI must not be empty).
    /// @dev Used for compliance with ERC721 standards.
    function tokenURI(
        uint256 _labId
    ) public view override exists(_labId) returns (string memory) {
       
         return _s().labs[_labId].uri;
    }

    /// @notice Updates the Lab with the given ID.
    /// @dev This function can only be called by the Lab provider and the contract owner.
    /// @param _labId The ID of the Lab to update.
    /// @param _uri The new URI for the Lab.
    /// @param _price The new price for the Lab.
    /// @param _auth The new authentication URI for the Lab.
    /// @param _accessURI The new access URI for the Lab.
    /// @param _accessKey The new access key for the Lab.
    /// @dev Emits a {LabUpdated} event upon successful execution
    function updateLab(
        uint256 _labId,
        string calldata _uri,
        uint96 _price,
        string calldata _auth,
        string calldata _accessURI,
        string calldata _accessKey
    ) public onlyTokenOwner(_labId) {
        // Validate string lengths to prevent DoS attacks
        require(bytes(_uri).length > 0 && bytes(_uri).length <= 500, "Invalid URI length");
        require(bytes(_auth).length > 0 && bytes(_auth).length <= 500, "Invalid auth length");
        require(bytes(_accessURI).length > 0 && bytes(_accessURI).length <= 500, "Invalid accessURI length");
        require(bytes(_accessKey).length > 0 && bytes(_accessKey).length <= 200, "Invalid accessKey length");
       
        _s().labs[_labId] = LabBase(
            _uri,
            _price,
            _auth,
            _accessURI,
            _accessKey
        );
        emit LabUpdated(_labId, _uri, _price, _auth, _accessURI, _accessKey);
    }

    /// @notice Updates a lab via intent
    function updateLabWithIntent(
        bytes32 requestId,
        uint256 _labId,
        string calldata _uri,
        uint96 _price,
        string calldata _auth,
        string calldata _accessURI,
        string calldata _accessKey
    ) external onlyTokenOwner(_labId) {
        ActionIntentPayload memory payload = ActionIntentPayload({
            executor: msg.sender,
            schacHomeOrganization: "",
            puc: "",
            assertionHash: bytes32(0),
            labId: _labId,
            reservationKey: bytes32(0),
            uri: _uri,
            price: _price,
            maxBatch: 0,
            auth: _auth,
            accessURI: _accessURI,
            accessKey: _accessKey,
            tokenURI: ""
        });
        _consumeLabIntent(requestId, LibIntent.ACTION_LAB_UPDATE, payload);

        updateLab(_labId, _uri, _price, _auth, _accessURI, _accessKey);
        emit LabIntentProcessed(requestId, _labId, "LAB_UPDATE", msg.sender, true, "");
    }

    /// @notice Deletes a Lab identified by `_labId`.
    /// @dev This function can only be called by the Lab provider and the contract owner.
    /// It checks if the Lab exists before deleting it.
    /// SECURITY: Prevents deletion if there are uncollected reservations (CONFIRMED, IN_USE, or COMPLETED)
    /// @param _labId The ID of the Lab to be deleted.
    /// @custom:security Cannot delete lab with active reservations to protect user funds
    function deleteLab(uint256 _labId) public onlyTokenOwner(_labId) {
        AppStorage storage s = _s();
        
        // Security check: Prevent deletion if there are uncollected reservations
        // This protects provider's funds from being locked if lab is deleted before collection
        require(!_hasActiveBookings(_labId), "Cannot delete lab with uncollected reservations");
        
        // Clean up listing status if lab was listed
        // This prevents corruption of listedLabsCount and tokenStatus
        if (s.tokenStatus[_labId]) {
            s.tokenStatus[_labId] = false;
            
            // Decrement listed count for the provider
            if (s.providerStakes[msg.sender].listedLabsCount > 0) {
                s.providerStakes[msg.sender].listedLabsCount--;
            }
            
            emit LabUnlisted(_labId, msg.sender);
        }
        
        _burn(_labId);
        delete s.labs[_labId];
        emit LabDeleted(_labId);
    }

    /// @notice Deletes a lab via intent
    function deleteLabWithIntent(bytes32 requestId, uint256 _labId) external onlyTokenOwner(_labId) {
        ActionIntentPayload memory payload = ActionIntentPayload({
            executor: msg.sender,
            schacHomeOrganization: "",
            puc: "",
            assertionHash: bytes32(0),
            labId: _labId,
            reservationKey: bytes32(0),
            uri: "",
            price: 0,
            maxBatch: 0,
            auth: "",
            accessURI: "",
            accessKey: "",
            tokenURI: ""
        });
        _consumeLabIntent(requestId, LibIntent.ACTION_LAB_DELETE, payload);

        deleteLab(_labId);
        emit LabIntentProcessed(requestId, _labId, "LAB_DELETE", msg.sender, true, "");
    }

    /// @notice Checks if a lab has any uncollected reservations (CONFIRMED, IN_USE, or COMPLETED)
    /// @dev Uses the active reservation counter (labActiveReservationCount) for O(1) constant-time checks.
    ///      This counter is maintained by:
    ///      - Incremented when reservation is confirmed (PENDING → CONFIRMED)
    ///      - Decremented when reservation is collected (CONFIRMED/COMPLETED → COLLECTED)
    ///      - Decremented when reservation is cancelled (CONFIRMED/IN_USE/COMPLETED → CANCELLED)
    /// @param _labId The ID of the lab to check
    /// @return true if there are any reservations with CONFIRMED, IN_USE, or COMPLETED status
    function _hasActiveBookings(uint256 _labId) internal view returns (bool) {
        AppStorage storage s = _s();
        return
            s.labActiveReservationCount[_labId] > 0 ||
            s.pendingProviderPayout[_labId] > 0;
    }

    /// @notice Lists a lab via intent
    function listLabWithIntent(bytes32 requestId, uint256 _labId) external onlyTokenOwner(_labId) {
        ActionIntentPayload memory payload = ActionIntentPayload({
            executor: msg.sender,
            schacHomeOrganization: "",
            puc: "",
            assertionHash: bytes32(0),
            labId: _labId,
            reservationKey: bytes32(0),
            uri: "",
            price: 0,
            maxBatch: 0,
            auth: "",
            accessURI: "",
            accessKey: "",
            tokenURI: ""
        });
        _consumeLabIntent(requestId, LibIntent.ACTION_LAB_LIST, payload);

        listToken(_labId);
        emit LabIntentProcessed(requestId, _labId, "LAB_LIST", msg.sender, true, "");
    }

    /// @notice Unlists a lab via intent
    function unlistLabWithIntent(bytes32 requestId, uint256 _labId) external onlyTokenOwner(_labId) {
        ActionIntentPayload memory payload = ActionIntentPayload({
            executor: msg.sender,
            schacHomeOrganization: "",
            puc: "",
            assertionHash: bytes32(0),
            labId: _labId,
            reservationKey: bytes32(0),
            uri: "",
            price: 0,
            maxBatch: 0,
            auth: "",
            accessURI: "",
            accessKey: "",
            tokenURI: ""
        });
        _consumeLabIntent(requestId, LibIntent.ACTION_LAB_UNLIST, payload);

        unlistToken(_labId);
        emit LabIntentProcessed(requestId, _labId, "LAB_UNLIST", msg.sender, true, "");
    }

    /// @notice Retrieves the details of a Lab by its ID.
    /// @dev This function returns the Lab details, including its ID, URI, and price.
    /// @param _labId The ID of the Lab to retrieve.
    /// @return A Lab structure containing the details of the specified Lab.
    function getLab(uint _labId) external view exists(_labId) returns (Lab memory) {
        return Lab(_labId, _s().labs[_labId]);
    }

    /// @notice Retrieves a paginated list of lab token IDs
    /// @dev Returns a subset of lab IDs to avoid gas limit issues with large datasets
    /// @param offset The starting index for pagination (0-based)
    /// @param limit The maximum number of labs to return (max 100)
    /// @return ids Array of lab token IDs for the requested page
    /// @return total The total number of labs available
    /// @custom:example To get first 50 labs: getLabsPaginated(0, 50)
    /// @custom:example To get next 50 labs: getLabsPaginated(50, 50)
    function getLabsPaginated(uint256 offset, uint256 limit) external view returns (uint256[] memory ids, uint256 total) {
        require(limit > 0 && limit <= 100, "Limit must be between 1 and 100");
        
        total = totalSupply();
        
        // Calculate actual number of items to return
        uint256 remaining = total > offset ? total - offset : 0;
        uint256 count = remaining < limit ? remaining : limit;
        
        ids = new uint256[](count);
        
        for (uint256 i = 0; i < count;) {
            ids[i] = tokenByIndex(offset + i);
            unchecked { ++i; }
        }
        
        return (ids, total);
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
            reservationCount <= MAX_CLEANUP_PER_TRANSFER,
            "Too many active reservations to transfer"
        );

        bool hasActiveReservation;

        for (uint256 i = 0; i < reservationCount;) {
            bytes32 key = labReservations.at(i);

            // Cache status in memory to save SLOAD
            uint8 status = s.reservations[key].status;

            // Prevent transferring labs with pending reservations to avoid owner ambush
            if (status == PENDING) {
                revert("Pending reservations block transfer");
            }

            // Migrate CONFIRMED, IN_USE and COMPLETED reservations to new lab owner.
            // The new owner inherits the right to collect pending funds earned by the lab.
            // PENDING reservations don't have provider assigned yet.
            // COLLECTED/CANCELLED are terminal states and don't need migration.
            if (status == CONFIRMED || status == IN_USE || status == COMPLETED) {
                hasActiveReservation = true;
                s.reservations[key].labProvider = to;
                s.reservations[key].collectorInstitution =
                    s.institutionalBackends[to] != address(0) ? to : address(0);

                s.reservationsProvider[from].remove(key);
                s.reservationsProvider[to].add(key);

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
