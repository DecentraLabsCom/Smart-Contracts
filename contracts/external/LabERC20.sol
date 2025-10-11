// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.23;

import "@openzeppelin/contracts-upgradeable/token/ERC20/ERC20Upgradeable.sol";
import "@openzeppelin/contracts-upgradeable/proxy/utils/Initializable.sol";

/// @title LabERC20 Token Contract
/// @author
/// - Juan Luis Ramos Villalón
/// - Luis de la Torre Cubillo
/// @notice A simple ERC20 token implementation with minting capability
/// @dev Inherits from Initializable and ERC20Upgradeable

contract LabERC20 is Initializable, ERC20Upgradeable {

    /// @notice Initializes the token with given symbol
    /// @dev This function can only be called once due to the initializer modifier
    /// @param _symbol The symbol for the token
    /// @custom:initializer Sets the token name as "$<symbol>" and mints 10M tokens to the deployer
    function initialize(string memory _symbol) public initializer {
        __ERC20_init(string.concat("$", _symbol), _symbol);
        _mint(msg.sender, 10000000);
    }

    /// @notice Mints new tokens and assigns them to the specified account
    /// @dev Anyone can call this function as it is public
    /// @param account The address that will receive the minted tokens
    /// @param amount The amount of tokens to mint
    function mint(address account, uint256 amount) public {
        _mint(account, amount);
    }

    /// @notice Returns the number of decimal places used in token amounts
    /// @dev This implementation uses 6 decimal places for token precision
    /// @return uint8 The number of decimal places (6)
    function decimals() public pure override returns (uint8) {
        return 6; // or any other number
    }
}
