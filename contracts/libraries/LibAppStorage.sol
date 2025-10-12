// SPDX-License-Identifier: GPL-2.0-or-later
pragma solidity ^0.8.23;

import {EnumerableSet} from "@openzeppelin/contracts/utils/structs/EnumerableSet.sol";

/// @dev Constant representing the hash of the string "APP_STORAGE_POSITION".
///      This is used as a unique identifier for the application storage position.
bytes32 constant APP_STORAGE_POSITION = keccak256(
    "diamond.standard.app.storage"
);

/// @dev Constant representing the hash of the string "PROVIDER_ROLE".
///      This is used as a unique identifier for the provider role within the contract.
bytes32 constant PROVIDER_ROLE = keccak256("PROVIDER_ROLE");

/// @dev Struct representing a Lab Provider.
/// @param name The name of the Lab Provider.
/// @param email The email address of the Lab Provider.
/// @param country The country of the Lab Provider.
struct ProviderBase {
    string name;
    string email;
    string country;
}

/// @dev Struct representing an extended Lab provider.This structure is used exclusively
///      in contract query functions return a single variable containing the entire structure.
///      It provides a convenient way to encapsulate and retrieve related data in a single call.
/// @param account The address of the Lab provider.
/// @param base The base Lab provider information.
struct Provider {
    address account;
    ProviderBase base;
}

/// @dev Represents the base structure for a laboratory entity and is the part of the metadata associated with the laboratory stored on-chain.
/// @param uri The URI pointing to the laboratory's metadata or information.
/// @param price The price associated with the laboratory, stored as a uint96.
/// @param auth URI to the authentication service that issues session tokens for lab access
/// @param accessURI The URI used to access the laboratory's services.
/// @param accessKey A public (non-sensitive) key or ID used for routing/access to the laboratory.
struct LabBase {
    string uri;
    uint96 price;
    string auth;
    string accessURI;
    string accessKey;
}

/// @dev Represents a laboratory structure with a unique identifier and associated base information. This structure is used exclusively
///      in contract query functions return a single variable containing the entire structure.
///      It provides a convenient way to encapsulate and retrieve related data in a single call.
/// @param labId The unique identifier for the laboratory.
/// @param base The base information of the laboratory, represented by the `LabBase` structure.
struct Lab {
    uint labId;
    LabBase base;
}

/// @notice Struct representing a lab reservation
/// @dev Stores reservation details including lab ID, renter address, pricing and timestamps
/// @param labId Unique identifier of the lab being reserved
/// @param renter Address of the user making the reservation
/// @param price Cost of the reservation in wei
/// @param start Starting timestamp of the reservation (as uint32)
/// @param end Ending timestamp of the reservation (as uint32)
/// @param status Current state of the reservation:
///        0 = PENDING
///        1 = BOOKED
///        2 = USED
///        3 = COLLECTED
///        4 = CANCELLED
struct Reservation {
        uint256 labId;
        address renter;
        uint96 price;
        uint32 start;
        uint32 end; 
        uint status; 
}

/// @notice Represents a node in a red-black tree data structure, necessary for the library RivalIntervalTree Node data structure
/// @dev Used for interval tree implementation where each node represents a time interval
/// @param parent Index of the parent node in the tree
/// @param left Index of the left child node
/// @param right Index of the right child node
/// @param end The ending value of the interval (the beginning value is stored as the key)
/// @param red Boolean flag indicating if the node is red (true) or black (false)
struct Node {
        uint parent;
        uint left;
        uint right;
        uint end; // begin is implicit as the key
        bool red;
}

/// @notice Represents a red-black tree data structure, necessary for the library RivalIntervalTree Tree data structure
/// @dev Tree structure containing a root value and mapping of nodes
/// @param root The root hash/value of the Merkle Tree
/// @param nodes Mapping from uint keys to Node values representing the tree structure
struct Tree {
        uint root;
        mapping(uint => Node) nodes;
}

/// @notice Struct representing a provider's staking information
/// @dev Tracks staked tokens, slashing history, and lock periods
/// @param stakedAmount Current amount of tokens staked by the provider
/// @param slashedAmount Total amount of tokens slashed historically (for tracking)
/// @param lastReservationTimestamp Timestamp of the provider's last completed reservation
/// @param receivedInitialTokens Whether the provider received the initial 1000 token mint
///        (false if added after cap was reached)
struct ProviderStake {
    uint256 stakedAmount;
    uint256 slashedAmount;
    uint256 lastReservationTimestamp;
    bool receivedInitialTokens;
}

/// @dev This struct is used to define the storage layout for the application.
///       Contains all state variables used across the diamond contract. It contains the following fields:
/// @notice 
/// @custom:storage-layout This struct defines the storage layout for the diamond contract
/// @custom:member DEFAULT_ADMIN_ROLE Stores the keccak256 hash for admin role
/// @custom:member labTokenAddress Address of the LAB token contract
/// @custom:member roleMembers Mapping of roles to set of addresses that have that role
/// @custom:member providers Mapping of provider addresses to their base information
/// @custom:member labId Counter for lab tokens
/// @custom:member labs Mapping of lab IDs to their base information
/// @custom:member calendars Mapping of labs IDs to their availability trees
/// @custom:member reservations Mapping of reservation hashes to reservation details
/// @custom:member renters Mapping of renter addresses to their reservation hashes
/// @custom:member reservationKeys Set of all reservation hashes in the system
/// @custom:member reservationsProvider Mapping of provider addresses to their pending reservation hashes
/// @custom:member tokenStatus Mapping of token IDs to their listing status (true = listed, false = unlisted)
/// @custom:member providerStakes Mapping of provider addresses to their staking information
struct AppStorage {
    bytes32 DEFAULT_ADMIN_ROLE;
    address labTokenAddress;

    mapping(bytes32 role => EnumerableSet.AddressSet) roleMembers;
    mapping(address => ProviderBase) providers;
    uint256 labId;
    mapping(uint => LabBase) labs;

    mapping(uint256 => Tree) calendars;
    mapping(bytes32 => Reservation) reservations; 
    mapping(address => EnumerableSet.Bytes32Set) renters; 
    EnumerableSet.Bytes32Set reservationKeys; 
    mapping (address => EnumerableSet.Bytes32Set) reservationsProvider; 
    mapping (uint256 => bool) tokenStatus;
    mapping (uint256 => uint256) reservationCountByToken;
    mapping (uint256 => EnumerableSet.Bytes32Set) reservationKeysByToken;
    mapping (uint256 => mapping(address => bytes32)) activeReservationByTokenAndUser;
    mapping (address => ProviderStake) providerStakes;
}

/// @title LibAppStorage
/// @author Juan Luis Ramos Villalón
/// @author Luis de la Torre Cubillo
/// @dev This library defines the main storage structure (AppStorage) used in the Diamond pattern,
///     following the EIP-2535 specification. It enables centralized and secure storage that can be accessed
///     by multiple facets of the contract without memory slot collisions.
///
///     AppStorage is used to declare shared variables across the modular architecture of the contract,
///     facilitating state management, access control, configuration, and other cross-facet functionalities.
///
///     This library is essential for maintaining consistency and efficiency in Diamond contracts.
library LibAppStorage {
    /// @dev Provides access to the `AppStorage` struct stored at a specific slot in contract storage.
    /// This function uses inline assembly to set the storage pointer to the predefined `APP_STORAGE_POSITION`.
    /// @return ds A storage pointer to the `AppStorage` struct.
    function diamondStorage() internal pure returns (AppStorage storage ds) {
        bytes32 position = APP_STORAGE_POSITION;
        assembly {
            ds.slot := position
        }
    }
}
