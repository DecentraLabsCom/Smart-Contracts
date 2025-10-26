// SPDX-License-Identifier: GPL-3.0-or-later
pragma solidity ^0.8.23;

import "@openzeppelin/contracts-upgradeable/token/ERC721/extensions/ERC721EnumerableUpgradeable.sol";
import "@openzeppelin/contracts/token/ERC721/IERC721.sol";
import "@openzeppelin/contracts/utils/structs/EnumerableSet.sol";
import {LibAppStorage, AppStorage, Lab, LabBase} from "../libraries/LibAppStorage.sol";
import {LibAccessControlEnumerable} from "../libraries/LibAccessControlEnumerable.sol";
import "../abstracts/ReservableToken.sol";

using EnumerableSet for EnumerableSet.Bytes32Set;


/// @title LabFacet Contract
/// @author
/// - Juan Luis Ramos Villalón
/// - Luis de la Torre Cubillo
/// @notice This contract is part of a diamond architecture and implements the ERC721 standard.
/// @dev This contract is an ERC721 token implementation for managing Labs (Cyber Physical Systems).
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

    /// @dev Emitted when the URI of a lab is set.
    /// @param _labId The unique identifier of the lab.
    /// @param _uri The URI of the lab.
    event LabURISet(uint256 indexed _labId, string _uri);

    /// @dev Modifier to restrict access to functions to only the provider of a specific lab.
    /// @param _labId The ID of the lab whose ownership is being verified.
    /// @notice Ensures that only the LabProvider (owner of the lab) can perform the action.
    /// @custom:reverts "Only the LabProvider can perform this action" if the caller is not the provider of the lab.
    modifier onlyLabProvider(uint256 _labId) {
        require(
            ownerOf(_labId) == msg.sender,
            "Only the LabProvider can perform this action"
        );
        _;
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

    /// @notice Adds a new Lab (Cyber Physical System) with the specified details.
    /// @dev This function increments the Lab ID, mints a new token for the Lab,
    ///      and stores the Lab's details in the contract's state.
    /// @param _uri The URI of the Lab, providing metadata or additional information.
    /// @param _price The price of the Lab in the smallest unit of the currency.
    /// @param _auth The URI to the authentication service that issues session tokens for lab access
    /// @param _accessURI The URI used to access the laboratory's services.
    /// @param _accessKey TA public (non-sensitive) key or ID used for routing/access to the laboratory.
    /// @dev The caller of this function must have the role of a Lab provider.
    /// @dev Emits a {LabAdded} event upon successful execution.
    /// @dev Note: The lab is created but not listed. Use listToken() or addAndListLab() to make it available.
    function addLab(
        string memory _uri,
        uint96 _price,
        string memory _auth,
        string memory _accessURI,
        string memory _accessKey
    ) external isLabProvider {
        _s().labId++;
        _safeMint(msg.sender, _s().labId);
        _s().labs[_s().labId] = LabBase(
            _uri,
            _price,
            _auth,
            _accessURI,
            _accessKey
        );
        emit LabAdded(
            _s().labId,
            msg.sender,
            _uri,
            _price,
            _auth,
            _accessURI,
            _accessKey
        );
    }

    /// @notice Adds a new Lab and immediately lists it for reservations in a single transaction.
    /// @dev This is a convenience function that combines addLab() and listToken() functionality.
    ///      Requires the provider to have sufficient staked tokens based on listed labs count.
    ///      Formula: 800 base + max(0, listedLabs - 10) * 200
    /// @param _uri The URI of the Lab, providing metadata or additional information.
    /// @param _price The price of the Lab in the smallest unit of the currency.
    /// @param _auth The URI to the authentication service that issues session tokens for lab access
    /// @param _accessURI The URI used to access the laboratory's services.
    /// @param _accessKey TA public (non-sensitive) key or ID used for routing/access to the laboratory.
    /// @dev The caller of this function must have the role of a Lab provider.
    /// @dev Emits both {LabAdded} and {LabListed} events upon successful execution.
    /// @dev Reverts if the provider does not have sufficient staked tokens.
    function addAndListLab(
        string memory _uri,
        uint96 _price,
        string memory _auth,
        string memory _accessURI,
        string memory _accessKey
    ) external isLabProvider {
        AppStorage storage s = _s();
        
        // Calculate required stake for new listed count
        uint256 newListedCount = s.providerStakes[msg.sender].listedLabsCount + 1;
        uint256 requiredStake = calculateRequiredStake(msg.sender, newListedCount);
        
        if (s.providerStakes[msg.sender].stakedAmount < requiredStake) {
            revert("Insufficient stake to list lab");
        }
        
        // Create the lab
        s.labId++;
        _safeMint(msg.sender, s.labId);
        s.labs[s.labId] = LabBase(
            _uri,
            _price,
            _auth,
            _accessURI,
            _accessKey
        );
        
        // Update listed count and list the lab
        s.providerStakes[msg.sender].listedLabsCount = newListedCount;
        s.tokenStatus[s.labId] = true;
        
        emit LabAdded(
            s.labId,
            msg.sender,
            _uri,
            _price,
            _auth,
            _accessURI,
            _accessKey
        );
        emit LabListed(s.labId, msg.sender);
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
    ) external exists(_labId) onlyLabProvider(_labId) {
        require(bytes(_tokenURI).length > 0, "Token URI cannot be empty");

        LabBase memory lab = _s().labs[_labId];
       
        lab.uri = _tokenURI;
        _s().labs[_labId] = lab;

        emit LabURISet(_labId, _tokenURI);
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

    /// @notice Updates the Lab (Cyber Physical System) with the given ID.
    /// @dev This function can only be called by the Lab provider and the contract owner.
    /// @param _labId The ID of the Lab to update.
    /// @param _uri The new URI for the Lab.
    /// @param _price The new price for the Lab.
    /// @param _auth The new authentication URI for the Lab.
    /// @param _accessURI The new access URI for the Lab.
    /// @param _accessKey The new access key for the Lab.
    /// @dev Emits a {LabUpdated} event upon successful execution
    function updateLab(
        uint _labId,
        string memory _uri,
        uint96 _price,
        string memory _auth,
        string memory _accessURI,
        string memory _accessKey
    ) external onlyLabProvider(_labId) {
       
        _s().labs[_labId] = LabBase(
            _uri,
            _price,
            _auth,
            _accessURI,
            _accessKey
        );
        emit LabUpdated(_labId, _uri, _price, _auth, _accessURI, _accessKey);
    }

    /// @notice Deletes a Lab identified by `_labId`.
    /// @dev This function can only be called by the Lab provider and the contract owner.
    /// It checks if the Lab exists before deleting it.
    /// SECURITY: Prevents deletion if there are active (BOOKED) reservations to protect user funds
    /// @param _labId The ID of the Lab to be deleted.
    /// @custom:security Cannot delete lab with active BOOKED reservations
    function deleteLab(uint _labId) external  onlyLabProvider(_labId) {
        // Security check: Prevent deletion if there are active bookings
        // This protects users' funds from being locked if lab is deleted
        require(!_hasActiveBookings(_labId), "Cannot delete lab with active bookings");
       
        AppStorage storage s = _s();
        
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

    /// @notice Checks if a lab has any active (BOOKED status) reservations
    /// @dev Internal helper function to prevent lab deletion with active bookings
    /// @param _labId The ID of the lab to check
    /// @return true if there are any reservations with BOOKED status for this lab
    function _hasActiveBookings(uint256 _labId) internal view returns (bool) {
        AppStorage storage s = _s();
        EnumerableSet.Bytes32Set storage reservationKeys = s.reservationKeysByToken[_labId];
        uint256 length = reservationKeys.length();
        
        for (uint256 i = 0; i < length; i++) {
            bytes32 key = reservationKeys.at(i);
            // BOOKED = 1 (from ReservableToken.sol)
            if (s.reservations[key].status == 1) {
                return true;
            }
        }
        
        return false;
    }

    /// @notice Retrieves the details of a Lab (Cyber Physical System) by its ID.
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
        
        for (uint256 i = 0; i < count; i++) {
            ids[i] = tokenByIndex(offset + i);
        }
        
        return (ids, total);
    }

    /// @notice Approves a specific address to manage the given token ID.
    /// @dev Overrides the `approve` function from both IERC721 and ERC721Upgradeable.
    ///      Ensures that only a LabProvider can be approved for the token.
    /// @param _to The address to be approved.
    /// @param _tokenId The ID of the token to approve.
    /// @custom:require `_to` must be a LabProvider as determined by `_isLabProvider`.
    /// @custom:throws Reverts if `_to` is not a LabProvider.
    function approve(
        address _to,
        uint256 _tokenId
    ) public virtual override(IERC721, ERC721Upgradeable) {
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
    /// @custom:override Overrides the `setApprovalForAll` function from both `IERC721` and `ERC721Upgradeable`.
    function setApprovalForAll(
        address _operator,
        bool _approved
    ) public virtual override(IERC721, ERC721Upgradeable) {
        require(
            _s()._isLabProvider(_operator),
            "Only one LabProvider can be approved"
        );
        // Proceed with the standard approval process
        super.setApprovalForAll(_operator, _approved);
    }

    /// @dev Internal pure function to retrieve the application storage structure.
    ///      This function provides access to the `AppStorage` instance by calling
    ///      the `diamondStorage` function from the `LibAppStorage` library.
    /// @return s The storage instance of type `AppStorage`.
    function _s() internal pure returns (AppStorage storage s) {
        return LibAppStorage.diamondStorage();
    }

    /// @dev Internal function to update the ownership of a Lab token.
    /// Overrides the parent `_update` function to include additional validation.
    /// This function is called when transferring ownership of a Lab token.
    ///
    /// Requirements:
    /// - `_to` must be a valid Lab provider. Only one Lab owner can receive the Lab.
    ///
    /// @param _to The address of the new owner of the Lab token.
    /// @param _tokenId The ID of the Lab token being updated.
    /// @param _auth The address authorized for the update operation.
    ///
    /// @return The address of the new owner after the update.
    function _update(
        address _to,
        uint256 _tokenId,
        address _auth
    ) internal virtual override returns (address) {
        if (_to!= address(0))   //It's a burn operation
            require(_s()._isLabProvider(_to), "Only one Lab owner can receive Lab");
        // Proceed with the standard update process
        return super._update(_to, _tokenId, _auth);
    }
}
