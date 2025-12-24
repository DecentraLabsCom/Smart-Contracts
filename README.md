# DecentraLabs Smart Contracts

A comprehensive blockchain-based solution for managing access to worldwide laboratory equipment (Cyber-Physical Systems) through a decentralized platform. Built on Ethereum using the Diamond proxy pattern for maximum upgradeability and modularity.

## 🌟 Overview

DecentraLabs provides a blockchain infrastructure for managing remote laboratory access, reservations, and payments. The system enables:

- **Lab Providers** to register and manage their laboratory equipment as NFTs
- **Users** to discover, reserve, and access laboratory equipment worldwide
- **Administrators** to oversee the platform and manage roles
- **Transparent payments** using the native $LAB ERC20 token

## 🏗️ Architecture

This project implements a modular smart contract architecture using the **EIP-2535 Diamond Standard**, allowing for efficient upgrades and unlimited contract functionality.

### Core Components

```
Diamond Proxy (Main Contract)
├── DiamondCutFacet       (Upgrade management)
├── DiamondLoupeFacet     (Introspection)
├── OwnershipFacet        (Ownership management)
├── DistributionFacet     (Tokenomics distribution and subsidies)
├── IntentRegistryFacet   (EIP-712 intent registration and consumption)
├── ProviderFacet         (Provider & institutional treasury management)
├── LabFacet              (Lab/NFT management)
├── StakingFacet          (Staking, slashing, and unstaking)
├── ReservationFacet      (Booking & payments for labs)
└── LabERC20              (External: $LAB token)
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

### 3. Reservation System (ReservationFacet)
- **Time-based booking**: Reserve labs for specific time periods
- **Interval tree calendar**: Efficient O(log n) calendar conflict detection
- **Multi-state workflow**: 
  - `PENDING` - User requests reservation
  - `CONFIRMED` - Admin confirms reservation
  - `IN_USE` - Reservation is active
  - `COMPLETED` - Reservation finished, ready for collection
  - `COLLECTED` - Provider claims payment after use
  - `CANCELLED` - Cancelled by user or provider
- **Automatic refunds**: Failed or cancelled reservations are automatically refunded
- **Batch processing**: Providers can claim multiple completed reservations in batches

### 4. $LAB Token (LabERC20)
- **ERC-20 compliant**: Standard token interface
- **Supply cap**: Maximum supply of 1,000,000 tokens (1M tokens with 6 decimals)
- **Burnable**: Token holders can burn their tokens
- **Pausable**: Emergency pause functionality for security incidents
- **Role-based minting**: Only authorized contracts can mint new tokens
- **Initial distribution**: New providers receive initial token allocation

### 5. Provider Management (ProviderFacet)
- **Role-based access control**: Distinct roles for admins, providers, and institutions
- **Provider registry**: Track provider information (name, email, country)
- **Institutional treasury**: Manage token balances for institutional users
- **Automatic token grants**: New providers receive initial $LAB tokens
- **Provider updates**: Providers can update their information

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

#### DistributionFacet
Handles initial tokenomics distribution and controlled subsidies:
- One-time mint of treasury, subsidies, and ecosystem funds
- Admin-controlled top-ups with caps
- Timelock and vesting for large distributions
- Emergency pause for distribution controls

#### IntentRegistryFacet
Manages EIP-712 based intent system for gasless operations:
- Intent registration with admin approval
- Secure execution of signed intents
- Nonce-based replay protection
- Support for reservation and provider actions

#### ProviderFacet
Manages lab providers, roles, and institutional treasuries:
- Add/remove providers and institutions
- Institutional treasury management for SAML users
- Role-based access control (admin, provider, institution)
- Automatic token grants for new providers

#### LabFacet
Implements ERC-721 for laboratory NFTs with additional features:
- Add/update/delete labs
- Set token URIs and metadata
- Paginated lab queries
- Provider-only transfer restrictions
- Staking requirements for listing labs

**Sub-facets:**
- **LabAdminFacet**: Admin operations for lab management (minting, burning)
- **LabIntentFacet**: Lab operations via intent system
- **LabQueryFacet**: Read-only queries for lab data
- **LabReputationFacet**: Reputation-based lab features

#### StakingFacet
Implements provider staking mechanism for quality assurance:
- Token staking requirements for providers
- Slashing for misconduct with timelock recovery
- Unstaking with lock periods
- Reputation-based mechanisms

#### ReservationFacet
Handles the complete reservation lifecycle for labs:
- Reservation requests and admin confirmations
- Calendar conflict detection using interval trees
- Multi-state workflow (PENDING → CONFIRMED → IN_USE → COMPLETED → COLLECTED)
- Automatic refunds and batch fund collection
- Support for institutional and wallet reservations

**Sub-facets:**
- **WalletReservationFacet**: Manages reservations paid from user wallets
- **InstitutionalReservationFacet**: Handles reservations using institutional treasuries
- **WalletCancellationFacet**: Cancellation logic for wallet-based reservations
- **InstitutionalCancellationFacet**: Cancellation logic for institutional reservations
- **ReservationCheckInFacet**: Check-in functionality for completed reservations

### External Contracts

#### LabERC20
The native platform token with:
- 6 decimal precision
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

## 🚀 Use Cases

### For Lab Providers
1. Register as a provider through the admin
2. Receive initial $LAB token allocation
3. Add laboratory equipment as NFTs
4. Set pricing and access credentials
5. Manage reservations and collect payments
6. Update lab information as needed

### For Users
1. Browse available laboratories
2. Check availability using the calendar system
3. Request reservations with $LAB tokens
4. Wait for admin confirmation
5. Access laboratories during booked time
6. Cancel if needed (with automatic refunds)

### For Administrators
1. Manage provider registrations
2. Confirm or deny reservation requests
3. Monitor platform activity
4. Handle disputes
5. Emergency pause if needed

## 📊 Data Structures

### Lab Structure
```solidity
struct Lab {
    uint labId;              // Unique identifier
    string uri;              // Metadata URI
    uint96 price;            // Price per reservation
    string auth;             // Authentication service URI
    string accessURI;        // Lab access endpoint
    string accessKey;        // Public routing key
}
```

### Reservation Structure
```solidity
struct Reservation {
    uint256 labId;           // Lab identifier
    address renter;          // User address
    uint96 price;            // Reservation price
    uint32 start;            // Start timestamp
    uint32 end;              // End timestamp
    uint8 status;            // Reservation status (0=PENDING, 1=CONFIRMED, 2=IN_USE, 3=COMPLETED, 4=COLLECTED, 5=CANCELLED)
}
```

### Provider Structure
```solidity
struct Provider {
    address account;         // Provider address
    string name;             // Provider name
    string email;            // Contact email
    string country;          // Location
}
```

## 🔐 Security Considerations

- All contracts use OpenZeppelin's audited implementations
- Role-based access control prevents unauthorized actions
- Token transfers use safe transfer patterns
- Calendar system prevents double-booking
- Emergency pause capability for critical situations
- Comprehensive input validation throughout
- Supply cap prevents infinite token inflation

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
