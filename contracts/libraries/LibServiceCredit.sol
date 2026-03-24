// SPDX-License-Identifier: GPL-3.0-or-later
pragma solidity ^0.8.33;

import {AppStorage, LibAppStorage} from "./LibAppStorage.sol";

library LibServiceCredit {
    error ZeroAccount();
    error ZeroAmount();
    error InsufficientServiceCredits();

    function balanceOf(
        address account
    ) internal view returns (uint256) {
        return LibAppStorage.diamondStorage().serviceCreditBalance[account];
    }

    function credit(
        address account,
        uint256 amount
    ) internal returns (uint256 newBalance) {
        if (account == address(0)) revert ZeroAccount();
        if (amount == 0) revert ZeroAmount();

        AppStorage storage s = LibAppStorage.diamondStorage();
        newBalance = s.serviceCreditBalance[account] + amount;
        s.serviceCreditBalance[account] = newBalance;
    }

    function debit(
        address account,
        uint256 amount
    ) internal returns (uint256 newBalance) {
        if (account == address(0)) revert ZeroAccount();
        if (amount == 0) revert ZeroAmount();

        AppStorage storage s = LibAppStorage.diamondStorage();
        uint256 currentBalance = s.serviceCreditBalance[account];
        if (currentBalance < amount) revert InsufficientServiceCredits();

        newBalance = currentBalance - amount;
        s.serviceCreditBalance[account] = newBalance;
    }
}
