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
///      - Slot 4: requestPeriodStart (uint64) + requestPeriodDuration (uint64) + padding
///      Total: 5 slots (vs 7 slots in unoptimized version)
/// @param labId Unique identifier of the lab being reserved
/// @param renter Address of the user making the reservation
/// @param price Total cost of the reservation in LAB base units (uint96)
/// @param labProvider Address of the lab provider (owner at reservation time)
/// @param status Current state of the reservation (0=_PENDING, 1=_CONFIRMED, 2=_ACCESS_AUTHORIZED, 3=_SETTLED, 4=_CANCELLED)
/// @param start Starting timestamp of the reservation (as uint32)
/// @param end Ending timestamp of the reservation (as uint32)
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

struct ReservationSession {
    address signer;
    bytes32 gatewayIdHash;
    bytes32 sessionIdHash;
    bytes32 accessTypeHash;
    uint64 startedAt;
    bytes32 nonce;
    bytes32 credentialHash;
    bytes32 clientProofHash;
}

/// @notice Audit record for an emergency access authorization.
/// @dev Emergency check-ins remain excluded from provider settlement until an
///      explicit governance review releases the reservation.
struct EmergencyCheckInReview {
    bool settlementExcluded;
    uint8 reasonCode;
    address executor;
    uint64 checkedInAt;
    address reviewer;
    uint64 reviewedAt;
}

struct PayoutCandidate {
    uint32 end;
    // Reservation generation id. Legacy entries use the pre-generation key.
    bytes32 key;
}

/// @notice Individual provider settlement claim with immutable batch and
///      invoice scope plus an auditable payment proof.
struct ProviderSettlementClaim {
    uint256 labId;
    uint256 amount;
    bytes32 batchId;
    bytes32 invoiceReferenceHash;
    bytes32 paymentReferenceHash;
    bytes32 paymentAttestationHash;
    address submittedBy;
    address approvedBy;
    address paidBy;
    uint64 submittedAt;
    uint64 approvedAt;
    uint64 paidAt;
    uint8 status;
    bytes32 approvalReferenceHash;
    bytes32 resolutionReferenceHash;
    address resolutionActor;
    uint64 resolutionAt;
}

/// @notice Canonical provider receivable batch created when accrued value is
///      moved into the settlement queue.
struct ProviderSettlementBatch {
    uint256 labId;
    uint256 totalAmount;
    uint256 remainingAmount;
    bytes32 scopeRoot;
    uint64 createdAt;
    uint64 claimedAt;
    uint8 status;
    bytes32 resolutionReferenceHash;
    address resolutionActor;
    uint64 resolutionAt;
}

struct RecentReservationBuffer {
    // Reservation generation ids. Legacy entries use the pre-generation key.
    bytes32[50] keys;
    uint32[50] starts;
    uint8 size;
}

struct PastReservationBuffer {
    // Reservation generation ids. Legacy entries use the pre-generation key.
    bytes32[50] keys;
    uint32[50] ends;
    uint8 size;
}

struct UserActiveReservation {
    uint32 start;
    // Reservation generation id. Legacy entries use the pre-generation key.
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
///      lastUpdated: timestamp of last update
struct LabReputation {
    int32 score; // Total reputation points
    uint32 totalEvents;
    uint32 ownerCancellations;
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

/// @dev Shared application state for the diamond. Members are grouped by
///      domain so related state can be reviewed and evolved together.
/// @custom:storage-layout This struct defines the storage layout for the diamond contract
struct AppStorage {
    // Access control
    // forge-lint: disable-next-line(mixed-case-variable)
    bytes32 DEFAULT_ADMIN_ROLE;
    mapping(bytes32 role => EnumerableSet.AddressSet) roleMembers;

    // Provider and lab catalog
    mapping(address => ProviderBase) providers;
    mapping(address provider => ProviderNetworkStatus status) providerNetworkStatus;
    uint256 labId;
    mapping(uint256 => LabBase) labs;
    mapping(uint256 => bool) tokenStatus;
    uint256[] activeLabIds;
    mapping(uint256 labId => uint256 indexPlusOne) activeLabIndexPlusOne;
    mapping(uint256 => LabReputation) labReputation;
    mapping(uint256 labId => bytes32 pucHash) pucHashByLab;
    mapping(uint256 => Tree) calendars;

    // Reservation records and bounded indexes
    mapping(bytes32 => Reservation) reservations;
    mapping(address => EnumerableSet.Bytes32Set) renters;
    uint256 totalReservationsCount;
    mapping(uint256 => EnumerableSet.Bytes32Set) reservationKeysByToken;
    mapping(uint256 => mapping(address => EnumerableSet.Bytes32Set)) reservationKeysByTokenAndUser;
    mapping(uint256 => mapping(address => bytes32)) activeReservationByTokenAndUser;
    mapping(uint256 => mapping(address => uint8)) activeReservationCountByTokenAndUser;
    mapping(uint256 => RecentReservationBuffer) recentReservationsByToken;
    mapping(uint256 => mapping(address => RecentReservationBuffer)) recentReservationsByTokenAndUser;
    mapping(uint256 => PastReservationBuffer) pastReservationsByToken;
    mapping(uint256 => mapping(address => PastReservationBuffer)) pastReservationsByTokenAndUser;
    mapping(uint256 => mapping(address => UserActiveReservation[])) activeReservationHeaps;
    mapping(bytes32 => bool) activeReservationHeapContains;
    mapping(uint256 => uint256) labActiveReservationCount;
    mapping(address => uint256) providerActiveReservationCount;
    mapping(bytes32 reservationId => bytes32 pucHash) reservationPucHash;

    // Provider settlement and payout processing
    mapping(uint256 => PayoutCandidate[]) payoutHeaps;
    mapping(bytes32 => bool) payoutHeapContains;
    mapping(uint256 => uint256) payoutHeapInvalidCount;
    mapping(uint256 => uint256) providerReceivableAccrued;
    mapping(uint256 => uint256) providerSettlementQueue;
    mapping(uint256 => uint256) providerReceivableLastAccruedAt;
    mapping(uint256 labId => uint256 amount) providerReceivableInvoiced;
    mapping(uint256 labId => uint256 amount) providerReceivableApproved;
    mapping(uint256 labId => uint256 amount) providerReceivablePaid;
    mapping(uint256 labId => uint256 amount) providerReceivableReversed;
    mapping(uint256 labId => uint256 amount) providerReceivableDisputed;

    // Institutional spending and organization registry
    mapping(address provider => uint256 limit) institutionalUserLimit;
    mapping(address provider => mapping(bytes32 pucHash => InstitutionalUserSpending data)) institutionalUserSpending;
    mapping(address provider => address backend) institutionalBackends;
    mapping(address provider => uint256 duration) institutionalSpendingPeriod;
    mapping(address provider => uint256 anchor) institutionalSpendingPeriodAnchor;
    mapping(bytes32 orgHash => string name) schacHomeOrganizationNames;
    mapping(bytes32 orgHash => address wallet) organizationInstitutionWallet;
    mapping(address institution => EnumerableSet.Bytes32Set orgs) institutionSchacHomeOrganizations;

    mapping(bytes32 orgHash => string backendUrl) organizationBackendUrls;

    // Intent registry
    mapping(bytes32 => IntentMeta) intents;
    mapping(address => uint256) intentNonces;

    // Closed customer credit ledger
    mapping(address account => uint256 balance) serviceCreditBalance;

    // Credit-lot ledger
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

    // Provider/gateway session-start attestations
    mapping(bytes32 reservationId => ReservationSession session) reservationSessionStarted;
    mapping(bytes32 reservationId => bool recorded) reservationSessionStartedRecorded;
    mapping(bytes32 nonce => bool used) sessionStartedNonceUsed;
    mapping(bytes32 observationKey => bool used) sessionStartedObservationUsed;

    // Original expiry carried through a reservation lock so refunds cannot
    // silently become perpetual credits.
    mapping(address account => mapping(bytes32 reservationRef => uint48 expiresAt)) creditReservationExpiry;

    // Spending period captured when a reservation charge is recorded. The value
    // is periodStart + 1 so zero remains the unset value for legacy reservations.
    mapping(bytes32 reservationId => uint256 periodStartPlusOne) institutionalReservationPeriodStartPlusOne;

    // Payout heap index. Zero means the candidate is not indexed (including legacy
    // entries); indexed entries store their zero-based array index plus one.
    mapping(bytes32 reservationId => uint256 indexPlusOne) payoutHeapIndexPlusOne;

    // Remaining EUR gross basis per lot. Kept separately so the existing CreditLot
    // layout remains stable while sequential consumption can preserve exact
    // proportional provenance, including rounding on the final source slice.
    mapping(uint256 lotId => uint256 remainingEurGrossAmount) creditLotRemainingEurGrossAmount;

    // Immutable source allocations recorded when a reservation consumes credits.
    mapping(address account => mapping(bytes32 reservationId => CreditReservationAllocation[]))
        creditReservationAllocations;

    // Independent stop-selling switch. It defaults to false so legacy listed
    // labs keep accepting reservations until their provider explicitly stops
    // new intake; tokenStatus remains the public listing state.
    mapping(uint256 labId => bool) labReservationIntakeStopped;

    // Individual settlement claims.
    mapping(bytes32 claimId => ProviderSettlementClaim claim) providerSettlementClaims;
    mapping(bytes32 paymentReferenceHash => bool used) providerSettlementPaymentReferenceUsed;

    // FMU concurrency index.
    mapping(uint256 labId => EnumerableSet.Bytes32Set) activeConcurrentReservationKeysByLab;

    // Settlement reference indexes
    mapping(bytes32 invoiceReferenceHash => bool used) providerSettlementInvoiceReferenceUsed;
    mapping(bytes32 approvalReferenceHash => bool used) providerSettlementApprovalReferenceUsed;
    mapping(bytes32 resolutionReferenceHash => bool used) providerSettlementResolutionReferenceUsed;

    // Reservation generation identity. The public reservation key continues
    // to identify the currently occupied slot, while every accepted request
    // receives a unique immutable id for economic and historical sidecars.
    uint256 reservationIdNext;
    mapping(bytes32 slotKey => bytes32 reservationId) reservationIdByKey;
    mapping(bytes32 reservationId => bytes32 slotKey) reservationKeyById;
    mapping(bytes32 reservationId => Reservation) reservationHistoryById;

    // Cursor used by batched refunds for legacy reservations whose allocation
    // list predates the allocation cap.
    mapping(address account => mapping(bytes32 reservationRef => uint256 allocationIndex))
        creditReservationRefundCursor;

    // Cursor for bounded payout-heap scans. It advances across grace-pending
    // entries so later settleable candidates cannot be starved by a fixed scan
    // prefix.
    mapping(uint256 labId => uint256 heapScanIndex) payoutHeapScanCursor;

    // Canonical settlement batches. The scope root is an on-chain hash chain
    // over the actual accrual events, in their transaction/log order.
    mapping(uint256 labId => bytes32 scopeRoot) providerReceivableAccruedScopeRoot;
    uint256 providerSettlementBatchNextNonce;
    mapping(bytes32 batchId => ProviderSettlementBatch batch) providerSettlementBatches;
    mapping(uint256 labId => bytes32 batchId) providerSettlementLatestBatchId;

    // Emergency check-ins require governance review before they can affect
    // provider settlement. Keyed by immutable reservation generation.
    mapping(bytes32 reservationId => EmergencyCheckInReview review) emergencyCheckInReviews;

    // Credit-lot provenance sidecars. These mappings are appended to preserve
    // the storage slots of the deployed AppStorage layout.
    mapping(uint256 lotId => uint256 refundableAllocationCount) creditLotRefundReferences;
    mapping(uint256 lotId => bool initialized) creditLotRemainingEurGrossAmountInitialized;
    mapping(address account => mapping(bytes32 reservationId => mapping(uint256 allocationIndex => bool)))
        creditReservationAllocationLotIdSet;

    // Pending reservation count. Appended to preserve every deployed storage slot.
    mapping(uint256 labId => uint256) labPendingReservationCount;
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

/// @notice Portion of a reservation charge attributable to one source credit lot.
/// @dev The original allocation remains immutable; refund fields track how much
///      of that allocation has already been restored without losing provenance.
struct CreditReservationAllocation {
    bytes32 fundingOrderId;
    uint256 amount;
    uint256 refundedAmount;
    uint256 eurGrossAmount;
    uint256 refundedEurGrossAmount;
    uint48 expiresAt;
    uint256 lotId;
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
    uint8 internal constant CREDIT_DECIMALS = 7;

    /// @notice Number of raw units that make up one full service credit
    uint256 internal constant RAW_PER_CREDIT = 10_000_000;

    /// @notice Fixed commercial exchange rate used off-chain and for accounting
    uint256 internal constant CREDITS_PER_EUR = 10;

    /// @notice Number of raw credit units equivalent to one full EUR
    uint256 internal constant RAW_PER_EUR = RAW_PER_CREDIT * CREDITS_PER_EUR; // 100_000_000

    /// @notice Number of raw credit units equivalent to one euro cent
    uint256 internal constant RAW_PER_EUR_CENT = RAW_PER_EUR / 100; // 1_000_000

    /// @notice Default spending limit for institutional users
    uint256 internal constant DEFAULT_INSTITUTIONAL_USER_LIMIT = 100_000_000; // 10 credits with 7 decimals

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
