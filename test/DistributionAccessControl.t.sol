// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.33;

import "forge-std/Test.sol";
import "../contracts/facets/DistributionFacet.sol";
import "../contracts/external/LabERC20.sol";
import "../contracts/libraries/LibAppStorage.sol";

contract DistributionHarness is DistributionFacet {
    // grant deployer the default admin role so tests can call admin-only functions
    constructor() {
        _grantRole(DEFAULT_ADMIN_ROLE, msg.sender);
    }

    // test-only setter
    function setLabTokenAddress(address tokenAddr) public {
        LibAppStorage.diamondStorage().labTokenAddress = tokenAddr;
    }

    function readTokenPoolsInitialized() public view returns (bool) {
        return LibAppStorage.diamondStorage().tokenPoolsInitialized;
    }

    function readSubsidiesPoolMinted() public view returns (uint256) {
        return LibAppStorage.diamondStorage().subsidiesPoolMinted;
    }

    function readReservePoolMinted() public view returns (uint256) {
        return LibAppStorage.diamondStorage().reservePoolMinted;
    }
}

contract DistributionAccessControlTest is Test {
    DistributionHarness internal dist;
    LabERC20 internal token;

    function setUp() public {
        dist = new DistributionHarness();
        token = new LabERC20();
        // initialize token and make the Distribution harness the minter
        token.initialize("LAB", address(dist));

        // wire token into app storage (test + harness)
        AppStorage storage s = LibAppStorage.diamondStorage();
        s.labTokenAddress = address(token);
        dist.setLabTokenAddress(address(token));
    }

    function test_initialize_reverts_for_non_admin() public {
        // deploy a plain DistributionFacet (no admin granted) and assert revert when calling initializer
        DistributionFacet plain = new DistributionFacet();
        vm.expectRevert();
        plain.initializeTokenPools(address(0x1), address(0x2), address(0x3), address(0x4), address(0x5), address(0x6), 1);
    }

    function test_admin_can_initialize_and_topup_and_mint_reserve() public {
        // Use this test contract as admin (DistributionHarness granted admin to this contract at construction)
        // addresses used for pools
        address projectTreasury = address(0x100);
        address subsidies = address(this); // use test contract so we can manipulate balances
        address governance = address(0x300);
        address liquidity = address(0x400);
        address ecosystem = address(0x500);
        address teamBeneficiary = address(0x600);

        // initialize pools (as admin)
        dist.initializeTokenPools(projectTreasury, subsidies, governance, liquidity, ecosystem, teamBeneficiary, 1);

        assertTrue(dist.readTokenPoolsInitialized());
        assertEq(dist.readSubsidiesPoolMinted(), LibAppStorage.SUBSIDIES_TOPUP_TRANCHE);

        // Ensure subsidies balance is currently > threshold, then move it below threshold to trigger topUp path
        uint256 bal = token.balanceOf(subsidies);
        assertTrue(bal >= LibAppStorage.SUBSIDIES_TOPUP_TRANCHE);

        // transfer out so current balance < SUBSIDIES_TOPUP_THRESHOLD
        uint256 keep = LibAppStorage.SUBSIDIES_TOPUP_THRESHOLD - 1;
        uint256 toSend = bal - keep;
        // send to some other address
        token.transfer(address(0xdead), toSend);

        uint256 preMinted = dist.readSubsidiesPoolMinted();
        uint256 preBal = token.balanceOf(subsidies);
        assertTrue(preBal < LibAppStorage.SUBSIDIES_TOPUP_THRESHOLD);

        // call topUpSubsidies (should succeed)
        dist.topUpSubsidies();

        uint256 postMinted = dist.readSubsidiesPoolMinted();
        uint256 postBal = token.balanceOf(subsidies);
        assertEq(postMinted, preMinted + LibAppStorage.SUBSIDIES_TOPUP_TRANCHE);
        assertEq(postBal, preBal + LibAppStorage.SUBSIDIES_TOPUP_TRANCHE);

        // mint from reserve tiny amount and check reserve accounting
        uint256 preReserve = dist.readReservePoolMinted();
        dist.mintFromReserve(address(0xBEEF), 1);
        assertEq(dist.readReservePoolMinted(), preReserve + 1);
        assertEq(token.balanceOf(address(0xBEEF)), 1);
    }
}