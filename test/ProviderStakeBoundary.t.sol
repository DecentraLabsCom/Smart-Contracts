// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.33;

import "forge-std/Test.sol";
import "./BaseTest.sol";
import "../contracts/abstracts/ReservableToken.sol";
import "../contracts/libraries/LibAppStorage.sol";

contract DummyReservable is ReservableToken {
    // no overrides required — call the public implementation directly in tests
}

contract ProviderStakeBoundaryTest is BaseTest {
    DummyReservable token;

    function setUp() public override {
        super.setUp();
        token = new DummyReservable();
    }

    function test_free_count_and_additional_lab_boundaries() public {
        AppStorage storage s = LibAppStorage.diamondStorage();
        address p = makeAddr("providerX");

        // initial: no received initial tokens and listedLabsCount == 0 -> should be 0
        s.providerStakes[p].receivedInitialTokens = false;
        assertEq(token.calculateRequiredStake(p, 0), 0);

        // once provider lists 1 lab but still hasn't received initial tokens, requirement should be base stake
        assertEq(token.calculateRequiredStake(p, 1), LibAppStorage.BASE_STAKE);

        // at free labs count boundary
        uint256 freeCount = LibAppStorage.FREE_LABS_COUNT;
        assertEq(token.calculateRequiredStake(p, freeCount), LibAppStorage.BASE_STAKE);

        // one beyond free count
        assertEq(token.calculateRequiredStake(p, freeCount + 1), LibAppStorage.BASE_STAKE + LibAppStorage.STAKE_PER_ADDITIONAL_LAB);
    }
}