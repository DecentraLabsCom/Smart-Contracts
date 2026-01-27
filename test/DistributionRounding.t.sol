// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.33;

import "forge-std/Test.sol";
import "../contracts/facets/DistributionFacet.sol";
import "../contracts/external/LabERC20.sol";
import "../contracts/libraries/LibAppStorage.sol";

contract DistributionHarness is DistributionFacet {
    constructor() {
        _grantRole(DEFAULT_ADMIN_ROLE, msg.sender);
    }

    function readLabTokenAddress() public view returns (address) {
        return LibAppStorage.diamondStorage().labTokenAddress;
    }

    // test-only setter to wire the token into the harness' own app storage
    function setLabTokenAddress(
        address tokenAddr
    ) public {
        LibAppStorage.diamondStorage().labTokenAddress = tokenAddr;
    }

    function readSubsidiesPoolMinted() public view returns (uint256) {
        return LibAppStorage.diamondStorage().subsidiesPoolMinted;
    }

    function readEcosystemPoolMinted() public view returns (uint256) {
        return LibAppStorage.diamondStorage().ecosystemPoolMinted;
    }
}

contract DistributionRoundingTest is Test {
    DistributionHarness internal dist;
    LabERC20 internal token;

    function setUp() public {
        dist = new DistributionHarness();
        token = new LabERC20();
        token.initialize("LAB", address(dist));
        // wire token into both test and harness app storage
        AppStorage storage s = LibAppStorage.diamondStorage();
        s.labTokenAddress = address(token);
        dist.setLabTokenAddress(address(token));
    }

    function test_lab_token_wired() public {
        AppStorage storage s = LibAppStorage.diamondStorage();
        assertEq(s.labTokenAddress, address(token));
        assertEq(dist.readLabTokenAddress(), address(token));
    }

    // Top-up tiny balance edge-case: ensure top-up uses tranche and doesn't overshoot cap
    function test_subsidies_topup_respects_cap_and_tranche() public {
        address projectTreasury = address(0x100);
        address subsidies = address(this);
        address governance = address(0x300);
        address liquidity = address(0x400);
        address ecosystem = address(0x500);
        address teamBeneficiary = address(0x600);

        // initialize pools
        dist.initializeTokenPools(projectTreasury, subsidies, governance, liquidity, ecosystem, teamBeneficiary, 1);

        uint256 initialMinted = dist.readSubsidiesPoolMinted();
        assertEq(initialMinted, LibAppStorage.SUBSIDIES_TOPUP_TRANCHE);

        // drain subsidies wallet to force topUp
        uint256 balance = token.balanceOf(subsidies);
        uint256 keep = LibAppStorage.SUBSIDIES_TOPUP_THRESHOLD - 1;
        token.transfer(address(0xfeed), balance - keep);
        assertTrue(token.balanceOf(subsidies) < LibAppStorage.SUBSIDIES_TOPUP_THRESHOLD);

        // Top up once and assert minted increased and cap respected
        dist.topUpSubsidies();
        uint256 currentMinted = dist.readSubsidiesPoolMinted();
        assertEq(currentMinted, initialMinted + LibAppStorage.SUBSIDIES_TOPUP_TRANCHE);
        assertTrue(currentMinted <= LibAppStorage.SUBSIDIES_POOL_CAP);
    }

    function test_ecosystem_topup_respects_threshold_and_tranche() public {
        address projectTreasury = address(0x100);
        address subsidies = address(0x200);
        address governance = address(0x300);
        address liquidity = address(0x400);
        address ecosystem = address(this);
        address teamBeneficiary = address(0x600);

        // init
        dist.initializeTokenPools(projectTreasury, subsidies, governance, liquidity, ecosystem, teamBeneficiary, 1);

        uint256 initial = dist.readEcosystemPoolMinted();
        assertEq(initial, LibAppStorage.ECOSYSTEM_TOPUP_TRANCHE);

        uint256 bal = token.balanceOf(ecosystem);
        uint256 keep = LibAppStorage.ECOSYSTEM_TOPUP_THRESHOLD - 1;
        token.transfer(address(0x777), bal - keep);
        assertTrue(token.balanceOf(ecosystem) < LibAppStorage.ECOSYSTEM_TOPUP_THRESHOLD);

        dist.topUpEcosystemGrowth();
        assertEq(dist.readEcosystemPoolMinted(), initial + LibAppStorage.ECOSYSTEM_TOPUP_TRANCHE);
    }
}
