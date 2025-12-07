// SPDX-License-Identifier: GPL-3.0-or-later
pragma solidity ^0.8.31;

import {EnumerableSet} from "@openzeppelin/contracts/utils/structs/EnumerableSet.sol";
import {IntentMeta} from "./IntentTypes.sol";

/// @dev Constant representing the hash of the string "APP_STORAGE_POSITION".
///      This is used as a unique identifier for the application storage position.
bytes32 constant APP_STORAGE_POSITION = keccak256(
    "diamond.standard.app.storage"
);

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
///      Optimized storage layout to minimize gas costs:
///      - Slot 0: labId (uint256 - 32 bytes)
///      - Slot 1: renter (address - 20 bytes) + price (uint96 - 12 bytes) = 32 bytes
///      - Slot 2: labProvider (address - 20 bytes) + status (uint8 - 1 byte) + start (uint32 - 4 bytes) + end (uint32 - 4 bytes) = 29 bytes
///      - Slot 3: puc (string - 32 bytes pointer)
///      - Slot 4: requestPeriodStart (uint64) + requestPeriodDuration (uint64) + padding
///      Total: 5 slots (vs 7 slots in unoptimized version)
/// @param labId Unique identifier of the lab being reserved
/// @param renter Address of the user making the reservation
/// @param price Cost of the reservation in wei
/// @param labProvider Address of the lab provider (owner at reservation time)
/// @param status Current state of the reservation (0=_PENDING, 1=_CONFIRMED, 2=_IN_USE, 3=_COMPLETED, 4=_COLLECTED, 5=_CANCELLED)
/// @param start Starting timestamp of the reservation (as uint32)
/// @param end Ending timestamp of the reservation (as uint32)
/// @param puc schacPersonalUniqueCode for institutional reservations (empty for wallet reservations)
/// @param requestPeriodStart Period start timestamp when institutional reservation was requested (0 for wallet, used for slippage protection)
/// @param payerInstitution Address of the institution paying for the reservation (zero for wallet payments)
/// @param collectorInstitution Address of the institution that should receive the payout (zero for direct wallet payouts)
struct Reservation {
        uint256 labId;           // Slot 0: 32 bytes
        address renter;          // Slot 1: 20 bytes
        uint96 price;            // Slot 1: +12 bytes = 32 bytes total
        address labProvider;     // Slot 2: 20 bytes
        uint8 status;            // Slot 2: +1 byte
        uint32 start;            // Slot 2: +4 bytes
        uint32 end;              // Slot 2: +4 bytes = 29 bytes total
        string puc;              // Slot 3: 32 bytes (pointer)
        uint64 requestPeriodStart; // Slot 4: +8 bytes
        uint64 requestPeriodDuration; // Slot 4: +8 bytes (0 for wallet reservations)
        address payerInstitution;   // Slot 5: 20 bytes
        address collectorInstitution; // Slot 5: +20 bytes (stored in separate slot)
        uint96 providerShare;      // Slot 6: Provider allocation cached at confirmation
        uint96 projectTreasuryShare; // Slot 6: +12 bytes
        uint96 subsidiesShare;     // Slot 7: Allocation for subsidies pool
        uint96 governanceShare;    // Slot 7: +12 bytes
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
    uint256 initialStakeTimestamp;
    uint256 listedLabsCount;
    bool receivedInitialTokens;
}

struct PendingSlash {
    uint256 amount;
    uint256 executeAfter;
    string reason;
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
/// @custom:member labTokenAddress Address of the LAB token contract
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
/// @custom:member providerStakes Mapping of provider addresses to their staking information
/// @custom:member institutionalTreasury Mapping of provider addresses to their institutional treasury balances
/// @custom:member institutionalUserLimit Mapping of provider addresses to their institutional user spending limits
/// @custom:member institutionalUserSpending Mapping of provider addresses to their institutional user spending data with period tracking
/// @custom:member institutionalBackends Mapping of provider addresses to their authorized backend addresses
/// @custom:member institutionalSpendingPeriod Duration of the spending period in seconds (default: 30 days)
/// @custom:member institutionalSpendingPeriodAnchor Optional anchor timestamp used to realign spending periods
/// @custom:member schacHomeOrganizationNames Canonical lower-case schacHomeOrganization string stored per hash
/// @custom:member organizationInstitutionWallet Mapping of normalized organization hashes to institution wallets
/// @custom:member institutionSchacHomeOrganizations Enumerable set of organization hashes registered by each institution wallet
struct AppStorage {
    // forge-lint: disable-next-line(mixed-case-variable)
    bytes32 DEFAULT_ADMIN_ROLE;
    address labTokenAddress;
    address projectTreasuryWallet;
    address subsidiesWallet;
    address governanceWallet;
    address liquidityWallet;
    address ecosystemGrowthWallet;
    address treasuryTimelock;
    address teamVestingWallet;
    address liquidityTimelock;

    mapping(bytes32 role => EnumerableSet.AddressSet) roleMembers;
    mapping(address => ProviderBase) providers;
    uint256 labId;
    mapping(uint => LabBase) labs;

    mapping(uint256 => Tree) calendars;
    mapping(bytes32 => Reservation) reservations; 
    mapping(address => EnumerableSet.Bytes32Set) renters; 
    uint256 totalReservationsCount;
    mapping (uint256 => EnumerableSet.Bytes32Set) reservationKeysByToken;
    mapping (uint256 => mapping(address => bytes32)) activeReservationByTokenAndUser;
    mapping (uint256 => mapping(address => uint8)) activeReservationCountByTokenAndUser;
    mapping (uint256 => mapping(address => EnumerableSet.Bytes32Set)) reservationKeysByTokenAndUser;
    mapping (uint256 => RecentReservationBuffer) recentReservationsByToken;
    mapping (uint256 => mapping(address => RecentReservationBuffer)) recentReservationsByTokenAndUser;
    mapping (uint256 => UpcomingReservationBuffer) upcomingReservationsByToken;
    mapping (uint256 => mapping(address => UpcomingReservationBuffer)) upcomingReservationsByTokenAndUser;
    mapping (uint256 => PastReservationBuffer) pastReservationsByToken;
    mapping (uint256 => mapping(address => PastReservationBuffer)) pastReservationsByTokenAndUser;
    mapping (uint256 => mapping(address => UserActiveReservation[])) activeReservationHeaps;
    mapping (bytes32 => bool) activeReservationHeapContains;
    mapping (uint256 => bool) tokenStatus;
    mapping (uint256 => uint256) labActiveReservationCount;
    mapping (address => uint256) providerActiveReservationCount;
    mapping (uint256 => PayoutCandidate[]) payoutHeaps;
    mapping (bytes32 => bool) payoutHeapContains;
    mapping (uint256 => uint256) payoutHeapInvalidCount;
    
    mapping (address => ProviderStake) providerStakes;

    mapping(address provider => uint256 balance) institutionalTreasury;
    mapping(address provider => uint256 limit) institutionalUserLimit;
    mapping(address provider => mapping(string puc => InstitutionalUserSpending data)) institutionalUserSpending;
    mapping(address provider => address backend) institutionalBackends;
    mapping(address provider => uint256 duration) institutionalSpendingPeriod;
    mapping(address provider => uint256 anchor) institutionalSpendingPeriodAnchor;
    mapping(bytes32 orgHash => string name) schacHomeOrganizationNames;
    mapping(bytes32 orgHash => address wallet) organizationInstitutionWallet;
    mapping(address institution => EnumerableSet.Bytes32Set orgs) institutionSchacHomeOrganizations;

    // Revenue split buckets (new split replaces legacy pendingLabPayout/pendingInstitutionalLabPayout)
    mapping (uint256 => uint256) pendingProviderPayout; // per lab pending amount for provider withdrawals
    uint256 pendingProjectTreasury; // global pending amount for project treasury
    uint256 pendingSubsidies; // global pending amount for student subsidies
    uint256 pendingGovernance; // global pending amount for governance incentives
    // Tokenomics accounting
    uint256 providerPoolMinted;
    uint256 treasuryPoolMinted;
    uint256 subsidiesPoolMinted;
    uint256 liquidityPoolMinted;
    uint256 ecosystemPoolMinted;
    uint256 teamPoolMinted;
    uint256 reservePoolMinted;
    bool tokenPoolsInitialized;

    // Intent registry
    mapping(bytes32 => IntentMeta) intents; // requestId -> intent meta
    mapping(address => uint256) intentNonces; // per-signer nonce

    // Admin recovery helpers
    mapping(uint256 => uint256) pendingProviderLastUpdated; // labId -> last accrual timestamp for pending provider payout

    // Slashing timelock queue
    mapping(address => PendingSlash) pendingSlashes; // provider => pending slash data
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
    /// @notice Base stake required for providers who received initial tokens
    uint256 internal constant BASE_STAKE = 800_000_000; // 800 tokens with 6 decimals
    
    /// @notice Number of labs included in base stake (free labs)
    uint256 internal constant FREE_LABS_COUNT = 10;
    
    /// @notice Additional stake required per lab beyond the free count
    uint256 internal constant STAKE_PER_ADDITIONAL_LAB = 200_000_000; // 200 tokens with 6 decimals
    
    /// @notice Default spending limit for institutional users
    uint256 internal constant DEFAULT_INSTITUTIONAL_USER_LIMIT = 10_000_000; // 10 tokens with 6 decimals
    
    /// @notice Default spending period duration (120 days in seconds)
    uint256 internal constant DEFAULT_SPENDING_PERIOD = 120 days;

    // Tokenomics caps (base units, 6 decimals)
    uint256 internal constant MAX_SUPPLY_BASE = 1_000_000_000_000; // 1,000,000 * 1e6
    uint256 internal constant PROVIDER_POOL_CAP = 200_000_000_000; // 20%
    uint256 internal constant TREASURY_POOL_CAP = 150_000_000_000; // 15%
    uint256 internal constant SUBSIDIES_POOL_CAP = 150_000_000_000; // 15%
    uint256 internal constant LIQUIDITY_POOL_CAP = 120_000_000_000; // 12%
    uint256 internal constant ECOSYSTEM_POOL_CAP = 100_000_000_000; // 10%
    uint256 internal constant TEAM_POOL_CAP = 100_000_000_000; // 10%
    uint256 internal constant RESERVE_POOL_CAP = 180_000_000_000; // 18%

    uint256 internal constant SUBSIDIES_TOPUP_TRANCHE = 30_000_000_000; // 3%
    uint256 internal constant SUBSIDIES_TOPUP_THRESHOLD = 1_000_000_000; // 1,000 tokens (base units)
    uint256 internal constant ECOSYSTEM_TOPUP_TRANCHE = 20_000_000_000; // 2%
    uint256 internal constant ECOSYSTEM_TOPUP_THRESHOLD = 1_000_000_000; // 1,000 tokens (base units)

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
