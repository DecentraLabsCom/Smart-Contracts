// SPDX-License-Identifier: GPL-3.0-or-later
pragma solidity ^0.8.31;

import {AccessControlUpgradeable} from "@openzeppelin/contracts-upgradeable/access/AccessControlUpgradeable.sol";
import {TimelockController} from "@openzeppelin/contracts/governance/TimelockController.sol";
import {VestingWallet} from "@openzeppelin/contracts/finance/VestingWallet.sol";
import {ReentrancyGuardTransient} from "@openzeppelin/contracts/utils/ReentrancyGuardTransient.sol";
import {LabERC20} from "../external/LabERC20.sol";
import {LibAppStorage, AppStorage} from "../libraries/LibAppStorage.sol";

// Custom errors for gas-efficient reverts (Solidity 0.8.26+)
error DistributionNotAdmin();
error DistributionAlreadyInitialized();
error DistributionNotInitialized();
error DistributionZeroAddress();
error DistributionZeroAmount();
error DistributionSubsidiesCapReached();
error DistributionEcosystemCapReached();
error DistributionReserveCapReached();
error DistributionBalanceAboveThreshold();

/// @title DistributionFacet
/// @notice Handles one-time initial tokenomics mint and controlled top-ups for subsidies and ecosystem growth.
/// @dev Admin-only; addresses are provided at initialization and cannot be changed via setters.
contract DistributionFacet is AccessControlUpgradeable, ReentrancyGuardTransient {
    /// @dev Emitted when the initial pools are minted.
    event TokenPoolsInitialized(
        address projectTreasury,
        address treasuryTimelock,
        address subsidies,
        address liquidity,
        address ecosystemGrowth,
        address teamVesting
    );

    /// @dev Emitted when subsidies pool is topped up.
    event SubsidiesToppedUp(uint256 amount, uint256 totalMinted);

    /// @dev Emitted when ecosystem growth pool is topped up.
    event EcosystemToppedUp(uint256 amount, uint256 totalMinted);

    /// @dev Emitted when reserve tokens are minted via governance.
    event ReserveMinted(address indexed to, uint256 amount, uint256 totalMinted);

    modifier onlyDefaultAdminRole() {
        _onlyDefaultAdminRole();
        _;
    }

    function _onlyDefaultAdminRole() internal view {
        require(hasRole(DEFAULT_ADMIN_ROLE, msg.sender), DistributionNotAdmin());
    }

    constructor() {}

    /// @notice One-time initializer that mints the initial pools and sets destination wallets.
    /// @param projectTreasury Multisig that will own the treasury timelock controller.
    /// @param subsidies Wallet for subsidies pool.
    /// @param governance Wallet for governance incentives (used by revenue split, not minted here).
    /// @param liquidity Wallet intended for liquidity provisioning (tokens are timelocked).
    /// @param ecosystemGrowth Wallet for ecosystem growth.
    /// @param teamBeneficiary Beneficiary of the team vesting wallet.
    /// @param timelockDelay Seconds delay for the treasury timelock.
    function initializeTokenPools(
        address projectTreasury,
        address subsidies,
        address governance,
        address liquidity,
        address ecosystemGrowth,
        address teamBeneficiary,
        uint256 timelockDelay
    ) external onlyDefaultAdminRole nonReentrant {
        AppStorage storage s = _s();
        require(!s.tokenPoolsInitialized, DistributionAlreadyInitialized());
        require(projectTreasury != address(0), DistributionZeroAddress());
        require(subsidies != address(0), DistributionZeroAddress());
        require(governance != address(0), DistributionZeroAddress());
        require(liquidity != address(0), DistributionZeroAddress());
        require(ecosystemGrowth != address(0), DistributionZeroAddress());
        require(teamBeneficiary != address(0), DistributionZeroAddress());

        s.projectTreasuryWallet = projectTreasury;
        s.subsidiesWallet = subsidies;
        s.governanceWallet = governance;
        s.liquidityWallet = liquidity;
        s.ecosystemGrowthWallet = ecosystemGrowth;

        // Deploy timelock for treasury; proposer/executor as projectTreasury for now.
        address[] memory proposers = new address[](1);
        proposers[0] = projectTreasury;
        address[] memory executors = new address[](1);
        executors[0] = projectTreasury;
        TimelockController timelock = new TimelockController(timelockDelay, proposers, executors, projectTreasury);
        s.treasuryTimelock = address(timelock);
        s.liquidityTimelock = address(timelock);

        // Deploy vesting wallet for founding team: start after 6-month cliff, duration 36 months.
        VestingWallet vesting = new VestingWallet(
            teamBeneficiary,
            uint64(block.timestamp + 180 days), // cliff
            uint64(36 * 30 days) // approx 36 months
        );
        s.teamVestingWallet = address(vesting);

        // Mint initial pools in a helper to reduce stack footprint
        _mintInitialPools(s, s.labTokenAddress, address(timelock), address(vesting), subsidies, ecosystemGrowth);

        s.tokenPoolsInitialized = true;

        emit TokenPoolsInitialized(
            projectTreasury, address(timelock), subsidies, liquidity, ecosystemGrowth, address(vesting)
        );
    }

    /// @notice Admin-only top-up for subsidies in 3% tranches when balance is low.
    function topUpSubsidies() external onlyDefaultAdminRole nonReentrant {
        AppStorage storage s = _s();
        require(s.tokenPoolsInitialized, DistributionNotInitialized());
        require(s.subsidiesPoolMinted < LibAppStorage.SUBSIDIES_POOL_CAP, DistributionSubsidiesCapReached());

        uint256 currentBalance = LabERC20(s.labTokenAddress).balanceOf(s.subsidiesWallet);
        require(currentBalance < LibAppStorage.SUBSIDIES_TOPUP_THRESHOLD, DistributionBalanceAboveThreshold());

        uint256 remaining = LibAppStorage.SUBSIDIES_POOL_CAP - s.subsidiesPoolMinted;
        uint256 tranche = LibAppStorage.SUBSIDIES_TOPUP_TRANCHE;
        if (tranche > remaining) tranche = remaining;

        // record state before external mint to follow checks-effects-interactions
        s.subsidiesPoolMinted += tranche;
        LabERC20(s.labTokenAddress).mint(s.subsidiesWallet, tranche);
        emit SubsidiesToppedUp(tranche, s.subsidiesPoolMinted);
    }

    /// @notice Admin-only top-up for ecosystem growth in 2% tranches when balance is low.
    function topUpEcosystemGrowth() external onlyDefaultAdminRole nonReentrant {
        AppStorage storage s = _s();
        require(s.tokenPoolsInitialized, DistributionNotInitialized());
        require(s.ecosystemPoolMinted < LibAppStorage.ECOSYSTEM_POOL_CAP, DistributionEcosystemCapReached());

        uint256 currentBalance = LabERC20(s.labTokenAddress).balanceOf(s.ecosystemGrowthWallet);
        require(currentBalance < LibAppStorage.ECOSYSTEM_TOPUP_THRESHOLD, DistributionBalanceAboveThreshold());

        uint256 remaining = LibAppStorage.ECOSYSTEM_POOL_CAP - s.ecosystemPoolMinted;
        uint256 tranche = LibAppStorage.ECOSYSTEM_TOPUP_TRANCHE;
        if (tranche > remaining) tranche = remaining;

        // record state before external mint to follow checks-effects-interactions
        s.ecosystemPoolMinted += tranche;
        LabERC20(s.labTokenAddress).mint(s.ecosystemGrowthWallet, tranche);
        emit EcosystemToppedUp(tranche, s.ecosystemPoolMinted);
    }

    /// @notice Admin-only mint from the unminted 18% reserve.
    /// @dev Should be governed (e.g., via timelock/multisig) to avoid abuse.
    /// @param to Recipient address
    /// @param amount Amount to mint (base units, 6 decimals)
    function mintFromReserve(
        address to,
        uint256 amount
    ) external onlyDefaultAdminRole nonReentrant {
        require(to != address(0), DistributionZeroAddress());
        require(amount > 0, DistributionZeroAmount());

        AppStorage storage s = _s();
        require(s.tokenPoolsInitialized, DistributionNotInitialized());
        require(s.reservePoolMinted + amount <= LibAppStorage.RESERVE_POOL_CAP, DistributionReserveCapReached());

        LabERC20 token = LabERC20(s.labTokenAddress);
        // record state change before external mint
        s.reservePoolMinted += amount;
        // ERC20Capped enforces total cap; we also guard reserve portion.
        token.mint(to, amount);

        emit ReserveMinted(to, amount, s.reservePoolMinted);
    }

    /// @notice After initialization, hand over mint authority to governance (e.g., timelock/multisig) and remove it from the Diamond.
    /// @param newMinter Address that will hold MINTER_ROLE (governance/Timelock/DAO)
    function finalizeMinterGovernance(
        address newMinter
    ) external onlyDefaultAdminRole nonReentrant {
        require(newMinter != address(0), DistributionZeroAddress());
        AppStorage storage s = _s();
        require(s.tokenPoolsInitialized, DistributionNotInitialized());

        // No state changes needed before external calls - safe as-is
        LabERC20 token = LabERC20(s.labTokenAddress);
        token.grantRole(token.MINTER_ROLE(), newMinter);
        token.revokeRole(token.MINTER_ROLE(), address(this));
    }

    function _mintInitialPools(
        AppStorage storage s,
        address tokenAddr,
        address timelock,
        address vesting,
        address subsidies,
        address ecosystemGrowth
    ) internal {
        // EFFECTS: Update all state variables BEFORE external calls (CEI pattern)
        uint256 subsidiesInit = LibAppStorage.SUBSIDIES_TOPUP_TRANCHE;
        uint256 ecosystemInit = LibAppStorage.ECOSYSTEM_TOPUP_TRANCHE;
        
        s.treasuryPoolMinted = LibAppStorage.TREASURY_POOL_CAP;
        s.subsidiesPoolMinted = subsidiesInit;
        s.liquidityPoolMinted = LibAppStorage.LIQUIDITY_POOL_CAP;
        s.ecosystemPoolMinted = ecosystemInit;
        s.teamPoolMinted = LibAppStorage.TEAM_POOL_CAP;

        // INTERACTIONS: Execute all external calls AFTER state updates
        LabERC20 token = LabERC20(tokenAddr);
        token.mint(timelock, LibAppStorage.TREASURY_POOL_CAP);
        token.mint(subsidies, subsidiesInit);
        token.mint(timelock, LibAppStorage.LIQUIDITY_POOL_CAP);
        token.mint(ecosystemGrowth, ecosystemInit);
        token.mint(vesting, LibAppStorage.TEAM_POOL_CAP);
    }

    function _s() internal pure returns (AppStorage storage s) {
        return LibAppStorage.diamondStorage();
    }
}
