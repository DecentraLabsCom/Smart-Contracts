# DecentraLabs Smart Contracts

A comprehensive blockchain-based solution for managing access to worldwide server-based simulations, laboratory equipment, and other Cyber-Physical Systems through a decentralized platform. Built on Ethereum using the Diamond proxy pattern for maximum upgradeability and modularity.

## 🌟 Overview

DecentraLabs provides a blockchain infrastructure for managing access, reservations, and payments to lab resources and services. The system enables:

- **Lab Providers** to register and manage their laboratory equipment as NFTs
- **Users** to discover, reserve, and access laboratory equipment worldwide
- **Administrators** to oversee the platform and manage roles
- **Managed service credits** — a closed, non-transferable prepaid credit ledger for lab usage

## 🏗️ Architecture

This project implements a modular smart contract architecture using the **EIP-2535 Diamond Standard**, allowing for efficient upgrades and unlimited contract functionality.

### Core Components

```
Diamond Proxy (Main Contract)
├── DiamondCutFacet       (Upgrade management)
├── DiamondLoupeFacet     (Introspection)
├── OwnershipFacet        (Ownership management)
├── ServiceCreditFacet    (Lot-based credit ledger: mint, lock, capture, release, expire, adjust)
├── IntentRegistryFacet   (EIP-712 intent registration and consumption)
├── ProviderFacet         (Provider & institutional management)
├── LabFacet              (Lab/NFT management)
├── ProviderNetworkFacet  (Provider eligibility enforcement)
├── Reservation Facets    (Booking & credit settlement for labs)
├── WalletPayoutFacet     (Provider receivable lifecycle and settlement)
└── LabERC20              (External: restricted ERC-20 — non-transferable, non-approvable)
```

## ✨ Key Features

### 1. Diamond Proxy Pattern (EIP-2535)
- **Unlimited contract size**: Break through the 24KB Ethereum contract size limit
- **Upgradeable architecture**: Add, replace, or remove functionality without redeploying
- **Gas efficient**: Share storage across all facets
- **Modular design**: Organize code into logical facets

### 2. Lab Management (LabFacet)
- **NFT-based labs**: Each laboratory is represented as an ERC-721 token
- **Comprehensive metadata**: URI, pricing, authentication endpoints, and access keys
- **Provider control**: Lab owners can add, update, and delete their laboratories
- **Paginated queries**: Efficient retrieval of lab listings
- **Transfer restrictions**: Only lab providers can own lab NFTs

### 3. Reservation System (Reservation Facets)
- **Time-based booking**: Reserve labs for specific time periods
- **Interval tree calendar**: Efficient O(log n) calendar conflict detection
- **Multi-state workflow**: 
  - `PENDING` - User requests reservation
  - `CONFIRMED` - Admin confirms reservation, credits locked
  - `IN_USE` - Reservation is active
  - `COMPLETED` - Reservation finished, ready for settlement
  - `SETTLED` - Provider receivable accrued after use
  - `CANCELLED` - Cancelled by user or provider, credits released
- **Credit lock/capture/release**: Reservation lifecycle uses lot-based credit operations
- **Batch processing**: Providers can settle multiple completed reservations

### 4. Service Credit Ledger (ServiceCreditFacet)
- **Lot-based issuance**: Credits minted in lots with EUR funding-order reference, amount, and expiry
- **Non-transferable**: No `transfer`, `transferFrom`, or `approve` operations
- **Lock/capture/release**: Credits are locked on confirmation, captured on settlement, released on cancellation
- **Auditable movements**: Every credit operation recorded as a `CreditMovement` with kind, amount, balance, ref, and timestamp
- **Expiry support**: Individual lots can expire; batch expiry operations available
- **Administrative adjustments**: Signed ledger adjustments with audit trail

### 5. Provider Management (ProviderFacet)
- **Role-based access control**: Distinct roles for admins, providers, and institutions
- **Provider registry**: Track provider information (name, email, country)
- **Institutional credit management**: Manage credit balances for institutional users
- **Onboarding credit grants**: New providers receive non-monetary onboarding credits
- **Provider updates**: Providers can update their information
- **Limited-network eligibility**: Providers must be ACTIVE in the provider network to fulfill reservations

### 6. Provider Receivable & Settlement (WalletPayoutFacet)
- **EUR-denominated receivables**: Provider monetization through separate receivable lifecycle
- **Lifecycle buckets**: ACCRUED → QUEUED → INVOICED → APPROVED → PAID (with DISPUTED / REVERSED)
- **Settlement operator role**: Only authorized actors can transition receivable lifecycle states
- **Deterministic audit linkage**: Each accrual linked to reservation key via `ProviderReceivableAccrued` event
- **Transfer guard**: Lab NFT transfer blocked while unsettled receivables exist

### 6. Advanced Calendar Management
- **Red-Black Tree**: Self-balancing binary search tree for O(log n) operations
- **Rival interval management**: Prevents overlapping reservations
- **Efficient lookups**: Fast availability checking and booking confirmation
- **Space efficient**: Optimized storage using interval compression

### 7. Security Features
- **Access control**: OpenZeppelin's AccessControlUpgradeable
- **Input validation**: Comprehensive parameter checking
- **Reentrancy protection**: Safe token transfer patterns
- **Emergency controls**: Pausable token for critical situations
- **Immutable ownership**: Diamond ownership can be transferred but not renounced

## 📋 Smart Contract Details

### Diamond.sol
The main entry point implementing the EIP-2535 Diamond proxy pattern. Delegates all function calls to the appropriate facet using `delegatecall`.

### Facets

#### DiamondCutFacet
Manages the upgrade mechanism allowing addition, replacement, and removal of facet functions.

#### DiamondLoupeFacet
Provides introspection into the Diamond's structure, allowing queries about available functions and their corresponding facets.

#### OwnershipFacet
Manages the Diamond contract ownership following EIP-173.

#### DistributionFacet (Deprecated)
All distribution functions have been deprecated with unconditional revert. Treasury minting, subsidies, and ecosystem fund operations are no longer part of the target model.

#### IntentRegistryFacet
Manages EIP-712 based intent system for gasless operations:
- Intent registration with admin approval
- Secure execution of signed intents
- Nonce-based replay protection
- Support for reservation and provider actions

#### ProviderFacet
Manages lab providers, roles, and institutional credit management:
- Add/remove providers and institutions
- Institutional credit management for SAML users
- Role-based access control (admin, provider, institution)
- Onboarding credit grants for new providers

#### LabFacet
Implements ERC-721 for laboratory NFTs with additional features:
- Add/update/delete labs
- Set token URIs and metadata
- Paginated lab queries
- Provider-only transfer restrictions
- Provider-network eligibility enforcement for listing labs

**Sub-facets:**
- **LabAdminFacet**: Admin operations for lab management (minting, burning)
- **LabIntentFacet**: Lab operations via intent system
- **LabQueryFacet**: Read-only queries for lab data
- **LabReputationFacet**: Reputation-based lab features

#### StakingFacet (Deprecated)
Staking, unstaking, and slashing functions have been deprecated with unconditional revert. Provider eligibility is now enforced through the provider-network status model rather than token staking.

#### Reservation Facets
Handles the complete reservation lifecycle for labs:
- Reservation requests and admin confirmations
- Calendar conflict detection using interval trees
- Multi-state workflow (PENDING → CONFIRMED → IN_USE → COMPLETED → SETTLED)
- Credit lock on confirmation, capture on settlement, release on cancellation
- Support for institutional and wallet reservations

**Sub-facets:**
- **WalletReservationReleaseFacet**: Releases expired reservations, captures locked credits
- **WalletReservationCoreFacet**: Core reservation request flow for wallet users
- **WalletReservationConfirmationFacet**: Confirms wallet reservation requests, locks credits
- **ReservationDenialFacet**: Denies reservation requests (wallet + institutional)
- **WalletReservationCancellationFacet**: Cancellation logic — captures fees, releases remainder
- **WalletPayoutFacet**: Provider receivable accrual, lifecycle transitions, and settlement
- **InstitutionalReservationFacet**: Releases expired institutional reservations
- **InstitutionalReservationRequestFacet**: Entry point for institutional reservation requests
- **InstitutionalReservationRequestValidationFacet**: Validates institutional reservation requests
- **InstitutionalReservationRequestCreationFacet**: Creates institutional reservation records
- **InstitutionalReservationConfirmationFacet**: Confirms institutional reservation requests
- **InstitutionalReservationCancellationFacet**: Cancellation logic for institutional reservations
- **InstitutionalReservationQueryFacet**: Read-only queries for institutional reservations
- **InstitutionalTreasuryFacet**: Institutional treasury balances and transfers
- **InstitutionalOrgRegistryFacet**: Institutional organization registry
- **InstitutionFacet**: Institution role and organization management
- **ReservationIntentFacet**: Intent-based institutional reservation actions
- **ReservationCheckInFacet**: Check-in functionality for completed reservations

### External Contracts

#### LabERC20
The native platform token with:
- 1 decimal precision
- 1,000,000 token supply cap
- Minter role (granted to Diamond)
- Pauser role (for emergencies)
- Burnable tokens

### Libraries

#### LibDiamond
Core Diamond Standard implementation managing facet storage and function selectors.

#### LibAppStorage
Diamond Storage pattern implementation providing shared storage across all facets.

#### LibAccessControlEnumerable
Enhanced access control with role enumeration capabilities.

#### LibInstitutionalOrg
Manages institutional organizations and SAML-based user associations.

#### LibIntent
Handles EIP-712 intent validation and execution logic.

#### LibReputation
Implements provider reputation system with check-in rewards and penalties.

#### LibRevenue
Manages revenue sharing and distribution calculations.

#### LibTracking
Provides tracking and analytics for reservations and usage.

#### RivalIntervalTreeLibrary
Red-Black tree implementation for efficient calendar management and conflict detection.

## 🔧 Technical Standards

This solution is built upon the following Ethereum standards and implementations:

1. **EIP-2535 Diamonds** - Diamond-1-Hardhat Implementation by Nick Mudge  
   https://github.com/mudgen/diamond-1-hardhat

2. **ERC-809** - Rental NFT implementation concept by Greg Taschuk  
   https://github.com/gtaschuk/erc809

3. **EIP-721** - NFT standard with OpenZeppelin upgradeable contracts  
   https://github.com/OpenZeppelin/openzeppelin-contracts-upgradeable

4. **EIP-2612** - Token permits (via OpenZeppelin ERC20)

5. **EIP-173** - Contract ownership standard

## 📊 Data Structures

### Provider Structure
```solidity
struct ProviderBase {
    string name;
    string email;
    string country;
    string authURI;
}

struct Provider {
    address account;
    ProviderBase base;
}
```

### Lab Structure
```solidity
struct LabBase {
    string uri;
    uint96 price;
    string accessURI;
    string accessKey;
    uint32 createdAt;
}

struct Lab {
    uint labId;
    LabBase base;
}
```

### Reservation Structure
```solidity
struct Reservation {
    uint256 labId;
    address renter;
    uint96 price;
    address labProvider;
    uint8 status;  // 0=PENDING, 1=CONFIRMED, 2=IN_USE, 3=COMPLETED, 4=COLLECTED, 5=CANCELLED
    uint32 start;
    uint32 end;
    string puc;  // schacPersonalUniqueCode for institutional
    uint64 requestPeriodStart;
    uint64 requestPeriodDuration;
    address payerInstitution;
    address collectorInstitution;
    uint96 providerShare;
    uint96 projectTreasuryShare;
    uint96 subsidiesShare;
    uint96 governanceShare;
}
```

### Pending Slash Structure
```solidity
struct PendingSlash {
    uint256 amount;
    uint256 executeAfter;
    string reason;
}
```

### Intent Meta Structure
```solidity
struct IntentMeta {
    bytes32 requestId;
    address signer;
    address executor;
    uint8 action;
    bytes32 payloadHash;
    uint256 nonce;
    uint64 requestedAt;
    uint64 expiresAt;
    IntentState state;
}
```

## 📝 License

This project is licensed under the GNU General Public License v3.0 - see the [LICENSE.txt](LICENSE.txt) file for details.

Portions of the code are also licensed under:
- MIT License (Diamond implementation)
- GPL-2.0-or-later (Custom facets)

## 👥 Authors

- **Luis de la Torre** - ldelatorre@dia.uned.es
- **Juan Luis Ramos Villalón** - juanluis@melilla.uned.es

## 🙏 Acknowledgments

- Nick Mudgen for the Diamond Standard implementation
- OpenZeppelin team for secure, audited contract libraries
- Greg Taschuk for the Rental NFT concept
- BokkyPooBah for the Red-Black Tree library foundation

## 📚 Additional Resources

- [EIP-2535: Diamond Standard](https://eips.ethereum.org/EIPS/eip-2535)
- [EIP-721: NFT Standard](https://eips.ethereum.org/EIPS/eip-721)
- [OpenZeppelin Documentation](https://docs.openzeppelin.com/)
- [Solidity Documentation](https://docs.soliditylang.org/)
