// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.23;

import "@openzeppelin/contracts-upgradeable/token/ERC20/ERC20Upgradeable.sol";
import "@openzeppelin/contracts-upgradeable/access/AccessControlUpgradeable.sol";
import "@openzeppelin/contracts-upgradeable/proxy/utils/Initializable.sol";

/// @title LabERC20 Token Contract
/// @author
/// - Juan Luis Ramos Villalón
/// - Luis de la Torre Cubillo
/// @notice A secure ERC20 token implementation with role-based access control
/// @dev Inherits from Initializable, ERC20Upgradeable, and AccessControlUpgradeable
/// @dev Uses MINTER_ROLE to restrict token minting to authorized addresses only

contract LabERC20 is Initializable, ERC20Upgradeable, AccessControlUpgradeable {

    /// @notice Role identifier for addresses authorized to mint new tokens
    /// @dev This role is required to call the mint() function
    bytes32 public constant MINTER_ROLE = keccak256("MINTER_ROLE");

    /// @notice Initializes the token with given symbol and sets up access control
    /// @dev This function can only be called once due to the initializer modifier
    /// @param _symbol The symbol for the token
    /// @param _diamondAddress The address of the Diamond contract that will receive MINTER_ROLE
    /// @custom:initializer Sets the token name as "$<symbol>", mints 10M tokens to deployer,
    ///                     grants DEFAULT_ADMIN_ROLE to deployer and MINTER_ROLE to Diamond
    function initialize(string memory _symbol, address _diamondAddress) public initializer {
        __ERC20_init(string.concat("$", _symbol), _symbol);
        __AccessControl_init();
        
        // Grant admin role to the deployer
        _grantRole(DEFAULT_ADMIN_ROLE, msg.sender);
        
        // Grant minter role to the Diamond contract (for ProviderFacet)
        _grantRole(MINTER_ROLE, _diamondAddress);
        
        // Mint initial supply to deployer
        _mint(msg.sender, 10000000);
    }

    /// @notice Mints new tokens and assigns them to the specified account
    /// @dev Can only be called by addresses with MINTER_ROLE
    /// @param account The address that will receive the minted tokens
    /// @param amount The amount of tokens to mint
    /// @custom:security Restricted to MINTER_ROLE to prevent unauthorized token creation
    function mint(address account, uint256 amount) public onlyRole(MINTER_ROLE) {
        _mint(account, amount);
    }

    /// @notice Returns the number of decimal places used in token amounts
    /// @dev This implementation uses 6 decimal places for token precision
    /// @return uint8 The number of decimal places (6)
    function decimals() public pure override returns (uint8) {
        return 6;
    }
}
