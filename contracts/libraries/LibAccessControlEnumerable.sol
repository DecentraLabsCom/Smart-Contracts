// SPDX-License-Identifier: GPL-3.0-or-later

pragma solidity ^0.8.23;

/**
 * @title LibAccessControlEnumerable
 * @author Juan Luis Ramos Villalón
 * @author Luis de la Torre Cubillo
 * @dev A library that extends the functionality of AccessControl to include enumeration of role members.
 * 
 * This library provides utility functions for managing and querying accounts with specific roles, 
 * particularly the "Lab Provider" role. It allows adding, removing, and retrieving lab providers 
 * along with their associated metadata.
 * 
 * The library relies on OpenZeppelin's EnumerableSet for efficient management of role members 
 * and assumes the existence of an `AppStorage` structure that holds role and provider data.
 * 
 * Usage:
 * This library is intended to be used in conjunction with a contract that implements the `AppStorage` structure 
 * and manages role-based access control.
 */

import {EnumerableSet} from "@openzeppelin/contracts/utils/structs/EnumerableSet.sol";
import {AppStorage, PROVIDER_ROLE, Provider, ProviderBase} from "./LibAppStorage.sol";


library LibAccessControlEnumerable {
    using EnumerableSet for EnumerableSet.AddressSet;

    /**
     * @dev Checks if a given account has the "Lab Provider" role.
     * @param _self The storage reference to the application state.
     * @param _account The address of the account to check.
     * @return bool Returns `true` if the account has the "Lab Provider" role, otherwise `false`.
     */
    function _isLabProvider(AppStorage storage _self, address _account) internal view returns (bool) {
        return _self.roleMembers[PROVIDER_ROLE].contains(_account);
    }


    /**
     * @dev Internal function to add a provider role to a specified account.
     * 
     * This function assigns the `PROVIDER_ROLE` to the given `_account` and stores
     * additional provider information such as `_name`, `_email`, and `_country` 
     * in the `AppStorage` structure.
     *
     * @param _self The storage reference to the `AppStorage` structure.
     * @param _account The address of the account to be assigned the provider role.
     * @param _name The name of the provider.
     * @param _email The email address of the provider.
     * @param _country The country of the provider.
     * 
     * @return bool Returns `true` if the provider role was successfully added.
     */
    function _addProviderRole(AppStorage storage _self, address _account, string memory _name, string memory _email, string memory _country) internal returns (bool) {
     
        _self.roleMembers[PROVIDER_ROLE].add(_account);
        _self.providers[_account] = ProviderBase(_name, _email, _country);
        return true;
    }

    
    /**
     * @dev Internal function to remove the provider role from a given account.
     * 
     * This function removes the specified account from the `PROVIDER_ROLE` members
     * and deletes the associated provider data from the `providers` mapping in the
     * AppStorage structure.
     * 
     * @param _self The AppStorage structure containing role and provider data.
     * @param _account The address of the account to remove the provider role from.
     * @return bool Returns `true` if the operation is successful.
     */
    function _removeProviderRole(AppStorage storage _self, address _account) internal returns (bool) {
    
        _self.roleMembers[PROVIDER_ROLE].remove(_account);
        delete _self.providers[_account];
        return true;
    }


    /**
     * @dev Retrieves the list of lab providers from the application storage.
     * 
     * This function fetches all the accounts associated with the `PROVIDER_ROLE` 
     * and constructs an array of `Provider` structs containing the account address 
     * and its corresponding provider data.
     * 
     * @param _self The application storage containing role members and provider data.
     * @return An array of `Provider` structs representing all lab providers.
     */
    function _getLabProviders(AppStorage storage _self) internal view returns (Provider[] memory) {
       
        uint256 totalLabProviders = _self.roleMembers[PROVIDER_ROLE].length();
        Provider[] memory providers = new Provider[](totalLabProviders);
        for (uint256 i; i < totalLabProviders; i++) {
            address account = _self.roleMembers[PROVIDER_ROLE].at(i);
            providers[i] = Provider(account, _self.providers[account]);
        }
        return providers;
    }


}
