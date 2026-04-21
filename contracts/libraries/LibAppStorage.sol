// SPDX-License-Identifier: GPL-3.0-or-later
pragma solidity ^0.8.33;

import {EnumerableSet} from "@openzeppelin/contracts/utils/structs/EnumerableSet.sol";
import {IntentMeta} from "./IntentTypes.sol";

/// @dev Constant representing the hash of the string "APP_STORAGE_POSITION".
///      This is used as a unique identifier for the application storage position.
bytes32 constant APP_STORAGE_POSITION = keccak256("diamond.standard.app.storage");

/// @dev Constant representing the hash of the string "PROVIDER_ROLE".
///      This is used as a unique identifier for the provider role within the contract.
bytes32 constant PROVIDER_ROLE = keccak256("PROVIDER_ROLE");

/// @dev Constant representing the hash of the string "INSTITUTION_ROLE".
///      This role gates access to institutional-only features such as domain registration.
bytes32 constant INSTITUTION_ROLE = keccak256("INSTITUTION_ROLE");

/// @dev Struct representing a Lab Provider.
/// @param name The name of the Lab Provider.
/// @param email The email address of the Lab Provider.
/// @param country The country of the Lab Provider.
/// @param authURI The base URL of the provider's authentication service (e.g., https://provider.example.com/auth)
struct ProviderBase {
    string name;
    string email;
    string country;
    string authURI;
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
/// @param price The price per second for the laboratory in LAB base units (uint96).
/// @param accessURI The URI used to access the laboratory's services.
/// @param accessKey A public (non-sensitive) key or ID used for routing/access to the laboratory.
/// @param createdAt Timestamp when the lab was registered, stored as uint32.
/// @param resourceType Type of resource: 0 = physical lab (default, exclusive calendar), 1 = FMU simulation (concurrent access).
struct LabBase {
    string uri;
    uint96 price;
    string accessURI;
    string accessKey;
    uint32 createdAt;
    uint8 resourceType;
}

/// @dev Represents a laboratory structure with a unique identifier and associated base information. This structure is used exclusively
///      in contract query functions return a single variable containing the entire structure.
///      It provides a convenient way to encapsulate and retrieve related data in a single call.
/// @param labId The unique identifier for the laboratory.
/// @param base The base information of the laboratory, represented by the `LabBase` structure.
struct Lab {
    uint256 labId;
    LabBase base;
}

/// @notice Struct representing a lab reservation
/// @dev Stores reservation details including lab ID, renter address, pricing and timestamps
///      Optimized storage layout to minimize gas costs:
///      - Slot 0: labId (uint256 - 32 bytes)
///      - Slot 1: renter (address - 20 bytes) + price (uint96 - 12 bytes) = 32 bytes
///      - Slot 2: labProvider (address - 20 bytes) + status (uint8 - 1 byte) + start (uint32 - 4 bytes) + end (uint32 - 4 bytes) = 29 bytes
///      - Slot 3: puc (string - 32 bytes pointer)
///      - Slot 4: requestPeriodStart (uint64) + requestPeriodDuration (uint64) + padding
///      Total: 5 slots (vs 7 slots in unoptimized version)
/// @param labId Unique identifier of the lab being reserved
/// @param renter Address of the user making the reservation
/// @param price Total cost of the reservation in LAB base units (uint96)
/// @param labProvider Address of the lab provider (owner at reservation time)
/// @param status Current state of the reservation (0=_PENDING, 1=_CONFIRMED, 2=_IN_USE, 3=_COMPLETED, 4=_SETTLED, 5=_CANCELLED)
/// @param start Starting timestamp of the reservation (as uint32)
/// @param end Ending timestamp of the reservation (as uint32)
/// @param puc schacPersonalUniqueCode for institutional reservations
/// @param requestPeriodStart Period start timestamp when institutional reservation was requested, used for slippage protection
/// @param payerInstitution Address of the institution paying for the reservation
/// @param collectorInstitution Address of the institution that should receive the payout
struct Reservation {
    uint256 labId; // Slot 0: 32 bytes
    address renter; // Slot 1: 20 bytes
    uint96 price; // Slot 1: +12 bytes = 32 bytes total
    address labProvider; // Slot 2: 20 bytes
    uint8 status; // Slot 2: +1 byte
    uint32 start; // Slot 2: +4 bytes
    uint32 end; // Slot 2: +4 bytes = 29 bytes total
    uint64 requestPeriodStart; // Slot 3: 8 bytes
    uint64 requestPeriodDuration; // Slot 3: +8 bytes
    address payerInstitution; // Slot 4: 20 bytes
    address collectorInstitution; // Slot 4: +20 bytes (stored in separate slot)
    uint96 providerShare; // Slot 5: Provider allocation cached at confirmation
}

struct PayoutCandidate {
    uint32 end;
    bytes32 key;
}

struct RecentReservationBuffer {
    bytes32[50] keys;
    uint32[50] starts;
    uint8 size;
}

struct UpcomingReservationBuffer {
    bytes32[50] keys;
    uint32[50] starts;
    uint8 size;
}

struct PastReservationBuffer {
    bytes32[50] keys;
    uint32[50] ends;
    uint8 size;
}

struct UserActiveReservation {
    uint32 start;
    bytes32 key;
}

/// @notice Represents a node in a red-black tree data structure, necessary for the library RivalIntervalTree Node data structure
/// @dev Used for interval tree implementation where each node represents a time interval
/// @param parent Index of the parent node in the tree
/// @param left Index of the left child node
/// @param right Index of the right child node
/// @param end The ending value of the interval (the beginning value is stored as the key)
/// @param red Boolean flag indicating if the node is red (true) or black (false)
struct Node {
    uint256 parent;
    uint256 left;
    uint256 right;
    uint256 end; // begin is implicit as the key
    bool red;
}

/// @notice Represents a red-black tree data structure, necessary for the library RivalIntervalTree Tree data structure
/// @dev Tree structure containing a root value and mapping of nodes
/// @param root The root hash/value of the Merkle Tree
/// @param nodes Mapping from uint keys to Node values representing the tree structure
struct Tree {
    uint256 root;
    // Test-only: when true the RivalIntervalTree emits traces and performs heavy consistency checks
    bool debug;
    mapping(uint256 => Node) nodes;
}

/// @notice Struct representing reputation stats for a lab (by labId)
/// @dev score: total points (completions - cancellations)
///      totalEvents: number of reputation events
///      ownerCancellations: cancellations by lab owner
///      institutionalCancellations: cancellations by institutions
///      lastUpdated: timestamp of last update
struct LabReputation {
    int32 score; // Total reputation points
    uint32 totalEvents;
    uint32 ownerCancellations;
    uint32 institutionalCancellations;
    uint64 lastUpdated;
}

/// @notice Struct representing institutional user spending in a period
/// @dev Tracks spending with automatic period reset
/// @param amount Amount spent in the current period (for limit enforcement)
/// @param periodStart Timestamp when the current spending period started
/// @param totalHistoricalSpent Total amount ever spent (never reset, used for refunds)
struct InstitutionalUserSpending {
    uint256 amount;
    uint256 periodStart;
    uint256 totalHistoricalSpent;
}

/// @dev This struct is used to define the storage layout for the application.
///       Contains all state variables used across the diamond contract. It contains the following fields:
/// @notice
/// @custom:storage-layout This struct defines the storage layout for the diamond contract
/// @custom:member DEFAULT_ADMIN_ROLE Stores the keccak256 hash for admin role
/// @custom:member roleMembers Mapping of roles to set of addresses that have that role
/// @custom:member providers Mapping of provider addresses to their base information
/// @custom:member labId Counter for lab tokens
/// @custom:member labs Mapping of lab IDs to their base information
/// @custom:member calendars Mapping of labs IDs to their availability trees
/// @custom:member reservations Mapping of reservation hashes to reservation details
/// @custom:member renters Mapping of renter addresses to their reservation hashes
/// @custom:member reservationKeysByToken Mapping of token IDs to their reservation hashes (use .length() for count)
/// @custom:member activeReservationByTokenAndUser Mapping of token IDs and user addresses to their active reservation hashes
/// @custom:member activeReservationCountByTokenAndUser Mapping of token IDs and user addresses to their active reservation count
/// @custom:member reservationKeysByTokenAndUser Mapping of token IDs and user addresses to their reservation keys (for efficient per-lab queries)
/// @custom:member tokenStatus Mapping of token IDs to their listing status (true = listed, false = unlisted)
/// @custom:member institutionalTreasury Mapping of provider addresses to their institutional treasury balances
/// @custom:member institutionalUserLimit Mapping of provider addresses to their institutional user spending limits
/// @custom:member institutionalUserSpending Mapping of provider addresses to their institutional user spending data with period tracking
/// @custom:member institutionalBackends Mapping of provider addresses to their authorized backend addresses
/// @custom:member institutionalSpendingPeriod Duration of the spending period in seconds (default: 30 days)
/// @custom:member institutionalSpendingPeriodAnchor Optional anchor timestamp used to realign spending periods
/// @custom:member schacHomeOrganizationNames Canonical lower-case schacHomeOrganization string stored per hash
/// @custom:member organizationInstitutionWallet Mapping of normalized organization hashes to institution wallets
/// @custom:member institutionSchacHomeOrganizations Enumerable set of organization hashes registered by each institution wallet
/// @custom:member organizationBackendUrls Backend URL per schacHomeOrganization hash
/// @custom:member activeLabIds Dense array of currently existing lab IDs (for efficient pagination)
/// @custom:member activeLabIndexPlusOne 1-based index of lab ID inside activeLabIds (0 means not indexed)
struct AppStorage {
    // forge-lint: disable-next-line(mixed-case-variable)
    bytes32 DEFAULT_ADMIN_ROLE;

    mapping(bytes32 role => EnumerableSet.AddressSet) roleMembers;
    mapping(address => ProviderBase) providers;
    uint256 labId;
    mapping(uint256 => LabBase) labs;

    mapping(uint256 => Tree) calendars;
    mapping(bytes32 => Reservation) reservations;
    mapping(address => EnumerableSet.Bytes32Set) renters;
    uint256 totalReservationsCount;
    mapping(uint256 => EnumerableSet.Bytes32Set) reservationKeysByToken;
    mapping(uint256 => mapping(address => bytes32)) activeReservationByTokenAndUser;
    mapping(uint256 => mapping(address => uint8)) activeReservationCountByTokenAndUser;
    mapping(uint256 => mapping(address => EnumerableSet.Bytes32Set)) reservationKeysByTokenAndUser;
    mapping(uint256 => RecentReservationBuffer) recentReservationsByToken;
    mapping(uint256 => mapping(address => RecentReservationBuffer)) recentReservationsByTokenAndUser;
    mapping(uint256 => UpcomingReservationBuffer) upcomingReservationsByToken;
    mapping(uint256 => mapping(address => UpcomingReservationBuffer)) upcomingReservationsByTokenAndUser;
    mapping(uint256 => PastReservationBuffer) pastReservationsByToken;
    mapping(uint256 => mapping(address => PastReservationBuffer)) pastReservationsByTokenAndUser;
    mapping(uint256 => mapping(address => UserActiveReservation[])) activeReservationHeaps;
    mapping(bytes32 => bool) activeReservationHeapContains;
    mapping(uint256 => bool) tokenStatus;
    mapping(uint256 => uint256) labActiveReservationCount;
    mapping(address => uint256) providerActiveReservationCount;
    mapping(uint256 => PayoutCandidate[]) payoutHeaps;
    mapping(bytes32 => bool) payoutHeapContains;
    mapping(uint256 => uint256) payoutHeapInvalidCount;

    mapping(address provider => uint256 balance) institutionalTreasury;
    mapping(address provider => uint256 limit) institutionalUserLimit;
    mapping(address provider => mapping(string puc => InstitutionalUserSpending data)) institutionalUserSpending;
    mapping(address provider => address backend) institutionalBackends;
    mapping(address provider => uint256 duration) institutionalSpendingPeriod;
    mapping(address provider => uint256 anchor) institutionalSpendingPeriodAnchor;
    mapping(bytes32 orgHash => string name) schacHomeOrganizationNames;
    mapping(bytes32 orgHash => address wallet) organizationInstitutionWallet;
    mapping(address institution => EnumerableSet.Bytes32Set orgs) institutionSchacHomeOrganizations;

    // Revenue split buckets
    mapping(uint256 => uint256) providerReceivableAccrued; // per-lab provider debt accrued onchain and not yet queued
    mapping(uint256 => uint256) providerSettlementQueue; // per-lab provider debt already queued for off-chain settlement

    // Intent registry
    mapping(bytes32 => IntentMeta) intents; // requestId -> intent meta
    mapping(address => uint256) intentNonces; // per-signer nonce

    // Admin recovery helpers
    mapping(uint256 => uint256) providerReceivableLastAccruedAt; // labId -> last accrual timestamp for provider debt

    // Lab reputation
    mapping(uint256 => LabReputation) labReputation; // labId -> reputation stats

    // Institutional org backend registry (appended to preserve storage layout)
    mapping(bytes32 orgHash => string backendUrl) organizationBackendUrls;

    // Reservation PUC hashes (appended to preserve storage layout)
    mapping(bytes32 reservationKey => bytes32 pucHash) reservationPucHash;

    // Active labs index (appended to preserve storage layout)
    uint256[] activeLabIds;
    mapping(uint256 labId => uint256 indexPlusOne) activeLabIndexPlusOne;

    // Closed customer credit ledger
    mapping(address account => uint256 balance) serviceCreditBalance;

    // Lab creator identity binding (historical tail preserved; append new fields after this point only)
    mapping(uint256 labId => bytes32 pucHash) pucHashByLab;

    // Provider receivable lifecycle buckets
    mapping(uint256 labId => uint256 amount) providerReceivableInvoiced;
    mapping(uint256 labId => uint256 amount) providerReceivableApproved;
    mapping(uint256 labId => uint256 amount) providerReceivablePaid;
    mapping(uint256 labId => uint256 amount) providerReceivableReversed;
    mapping(uint256 labId => uint256 amount) providerReceivableDisputed;

    // Limited-network participation status (appended to preserve storage layout)
    mapping(address provider => ProviderNetworkStatus status) providerNetworkStatus;

    // ── Credit-lot ledger (8.3.A + 8.3.B) ──────────────────────────────────
    // Locked credit balance (reserved for pending reservations, not yet captured)
    mapping(address account => uint256 locked) creditLockedBalance;
    // Per-account array of funding lots
    mapping(address account => CreditLot[]) creditLots;
    // Per-account cursor to the first lot that may still be consumable
    mapping(address account => uint256 index) creditLotCursor;
    // Global auto-incrementing lot ID counter
    uint256 creditLotNextId;
    // Per-account credit movement log
    mapping(address account => CreditMovement[]) creditMovements;
}

/// @notice Provider participation status within the limited service network
/// @dev NONE = default (not activated); ACTIVE = contracted and active;
///      SUSPENDED = temporarily removed from active network; TERMINATED = permanently deactivated
enum ProviderNetworkStatus {
    NONE,
    ACTIVE,
    SUSPENDED,
    TERMINATED
}

/// @notice A funding lot representing a discrete credit issuance with traceability
/// @dev Lots are consumed FIFO by remaining amount. Expired lots can be swept.
struct CreditLot {
    uint256 lotId; // Unique lot identifier
    bytes32 fundingOrderId; // External funding order reference
    uint256 creditAmount; // Original credit amount issued
    uint256 remaining; // Remaining unconsumed credits
    uint256 eurGrossAmount; // EUR gross amount that funded this lot (informational, euro cents)
    uint48 issuedAt; // Timestamp of lot creation
    uint48 expiresAt; // Expiry timestamp (0 = no expiry)
    bool expired; // Whether the lot has been marked expired
}

/// @notice Type of credit movement for audit trail
enum CreditMovementKind {
    MINT,
    LOCK,
    CAPTURE,
    RELEASE,
    CANCEL,
    EXPIRE,
    ADJUST
}

/// @notice An auditable credit movement entry
struct CreditMovement {
    CreditMovementKind kind;
    uint256 amount;
    uint256 balanceAfter; // Available balance after movement
    uint256 lockedAfter; // Locked balance after movement
    bytes32 ref; // External reference (reservation key, funding order, etc.)
    uint48 timestamp;
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
    /// @notice Number of decimal places used by service credits
    uint8 internal constant CREDIT_DECIMALS = 5;

    /// @notice Number of raw units that make up one full service credit
    uint256 internal constant RAW_PER_CREDIT = 100_000;

    /// @notice Fixed commercial exchange rate used off-chain and for accounting
    uint256 internal constant CREDITS_PER_EUR = 10;

    /// @notice Number of raw credit units equivalent to one full EUR
    uint256 internal constant RAW_PER_EUR = RAW_PER_CREDIT * CREDITS_PER_EUR; // 1_000_000

    /// @notice Number of raw credit units equivalent to one euro cent
    uint256 internal constant RAW_PER_EUR_CENT = RAW_PER_EUR / 100; // 10_000

    /// @notice Default spending limit for institutional users
    uint256 internal constant DEFAULT_INSTITUTIONAL_USER_LIMIT = 1_000_000; // 10 credits with 5 decimals

    /// @notice Default spending period duration (120 days in seconds)
    uint256 internal constant DEFAULT_SPENDING_PERIOD = 120 days;

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
