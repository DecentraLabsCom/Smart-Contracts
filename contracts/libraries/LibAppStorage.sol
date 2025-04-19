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

/// @dev AppStorage
/// @dev This struct is used to define the storage layout for the application.
///      It contains the following fields:
///
/// @param DEFAULT_ADMIN_ROLE A bytes32 value representing the default admin role.
/// @param labTokenAddress The address of the lab token contract.
/// @param roleMembers A mapping that associates a role (bytes32) with a set of addresses (EnumerableSet.AddressSet)
///                    representing the members of that role.
/// @param providers A mapping that associates an address with a ProviderBase structure, representing the providers.
/// @param labId A uint256 value representing the current lab ID, which is used to uniquely identify labs as NFTs.
/// @param labs A mapping that associates a uint with a LabBase structure, representing the labs.
struct AppStorage {
    bytes32 DEFAULT_ADMIN_ROLE;
    address labTokenAddress;
    mapping(bytes32 role => EnumerableSet.AddressSet) roleMembers;
    mapping(address => ProviderBase) providers;
    uint256 labId;
    mapping(uint => LabBase) labs;
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
