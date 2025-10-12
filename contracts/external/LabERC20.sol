// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.23;

import "@openzeppelin/contracts-upgradeable/token/ERC20/ERC20Upgradeable.sol";
import "@openzeppelin/contracts-upgradeable/token/ERC20/extensions/ERC20BurnableUpgradeable.sol";
import "@openzeppelin/contracts-upgradeable/token/ERC20/extensions/ERC20PausableUpgradeable.sol";
import "@openzeppelin/contracts-upgradeable/token/ERC20/extensions/ERC20CappedUpgradeable.sol";
import "@openzeppelin/contracts-upgradeable/access/AccessControlUpgradeable.sol";
import "@openzeppelin/contracts-upgradeable/proxy/utils/Initializable.sol";

/// @title LabERC20 Token Contract - DecentraLabs Ecosystem Token
/// @author
/// - Juan Luis Ramos Villalón
/// - Luis de la Torre Cubillo
/// @notice A secure ERC20 token implementation with role-based access control, burning, emergency pause, and supply cap
/// @dev Inherits from Initializable, ERC20Upgradeable, ERC20BurnableUpgradeable, ERC20PausableUpgradeable, ERC20CappedUpgradeable, and AccessControlUpgradeable
/// @dev Uses MINTER_ROLE to restrict token minting and PAUSER_ROLE for emergency pause functionality
/// @dev Maximum supply is capped at 1,000,000 tokens (1,000,000,000,000 base units with 6 decimals)

contract LabERC20 is 
    Initializable, 
    ERC20Upgradeable, 
    ERC20BurnableUpgradeable,
    ERC20PausableUpgradeable,
    ERC20CappedUpgradeable,
    AccessControlUpgradeable 
{

    /// @notice Role identifier for addresses authorized to mint new tokens
    /// @dev This role is required to call the mint() function
    bytes32 public constant MINTER_ROLE = keccak256("MINTER_ROLE");
    
    /// @notice Role identifier for addresses authorized to pause/unpause the contract
    /// @dev This role is required to call pause() and unpause() functions
    bytes32 public constant PAUSER_ROLE = keccak256("PAUSER_ROLE");
    
    /// @notice Maximum supply cap for the token (1,000,000 tokens = 1,000,000,000,000 base units)
    /// @dev This cap prevents infinite inflation and limits total supply
    uint256 private constant MAX_SUPPLY = 1_000_000_000_000; // 1M tokens with 6 decimals
    
    /// @notice Emitted when tokens are minted by an authorized minter
    /// @param to The address that received the minted tokens
    /// @param amount The amount of tokens minted (in base units)
    /// @param minter The address that performed the mint operation
    /// @param totalSupply The new total supply after minting
    event TokensMinted(
        address indexed to, 
        uint256 amount, 
        address indexed minter,
        uint256 totalSupply
    );
    
    /// @notice Emitted when tokens are burned
    /// @param from The address whose tokens were burned
    /// @param amount The amount of tokens burned (in base units)
    /// @param totalSupply The new total supply after burning
    event TokensBurned(
        address indexed from, 
        uint256 amount,
        uint256 totalSupply
    );
    
    /// @notice Emitted when the contract is paused by an authorized address
    /// @param account The address that triggered the pause
    /// @param reason The reason for the emergency pause
    /// @param timestamp The timestamp when the pause occurred
    event EmergencyPause(
        address indexed account, 
        string reason,
        uint256 timestamp
    );
    
    /// @notice Emitted when the contract is unpaused by an authorized address
    /// @param account The address that triggered the unpause
    /// @param timestamp The timestamp when the unpause occurred
    event EmergencyUnpause(
        address indexed account,
        uint256 timestamp
    );

    /// @notice Initializes the token with given symbol and sets up access control
    /// @dev This function can only be called once due to the initializer modifier
    /// @param _symbol The symbol for the token
    /// @param _diamondAddress The address of the Diamond contract that will receive MINTER_ROLE
    /// @custom:initializer Sets the token name as "$<symbol>", mints 100K tokens to deployer,
    ///                     grants DEFAULT_ADMIN_ROLE, MINTER_ROLE to Diamond, and PAUSER_ROLE to deployer
    function initialize(string memory _symbol, address _diamondAddress) public initializer {
        require(_diamondAddress != address(0), "LabERC20: diamond address cannot be zero");
        
        __ERC20_init(string.concat("$", _symbol), _symbol);
        __ERC20Burnable_init();
        __ERC20Pausable_init();
        __ERC20Capped_init(MAX_SUPPLY);
        __AccessControl_init();
        
        // Grant admin role to the deployer
        _grantRole(DEFAULT_ADMIN_ROLE, msg.sender);
        
        // Grant minter role to the Diamond contract (for ProviderFacet)
        _grantRole(MINTER_ROLE, _diamondAddress);
        
        // Grant pauser role to the deployer (for emergency situations)
        _grantRole(PAUSER_ROLE, msg.sender);
        
        // Mint initial supply to deployer (100,000 tokens = 100,000,000,000 base units)
        _mint(msg.sender, 100_000_000_000);
    }

    /// @notice Mints new tokens and assigns them to the specified account
    /// @dev Can only be called by addresses with MINTER_ROLE
    /// @param account The address that will receive the minted tokens
    /// @param amount The amount of tokens to mint
    /// @custom:security Restricted to MINTER_ROLE to prevent unauthorized token creation
    function mint(address account, uint256 amount) public onlyRole(MINTER_ROLE) {
        _mint(account, amount);
        emit TokensMinted(account, amount, msg.sender, totalSupply());
    }
    
    /// @notice Burns tokens from the caller's account
    /// @dev Overrides ERC20Burnable to add extended event
    /// @param amount The amount of tokens to burn
    function burn(uint256 amount) public override {
        super.burn(amount);
        emit TokensBurned(msg.sender, amount, totalSupply());
    }
    
    /// @notice Burns tokens from a specified account (requires allowance)
    /// @dev Overrides ERC20Burnable to add extended event
    /// @param account The account from which to burn tokens
    /// @param amount The amount of tokens to burn
    function burnFrom(address account, uint256 amount) public override {
        super.burnFrom(account, amount);
        emit TokensBurned(account, amount, totalSupply());
    }
    
    /// @notice Pauses all token transfers and operations
    /// @dev Can only be called by addresses with PAUSER_ROLE
    /// @param reason The reason for pausing (e.g., "Security exploit detected")
    /// @custom:security Use this in emergency situations to prevent further damage
    function pause(string memory reason) public onlyRole(PAUSER_ROLE) {
        _pause();
        emit EmergencyPause(msg.sender, reason, block.timestamp);
    }
    
    /// @notice Unpauses the contract, allowing token transfers again
    /// @dev Can only be called by addresses with PAUSER_ROLE
    /// @custom:security Only unpause after verifying the issue has been resolved
    function unpause() public onlyRole(PAUSER_ROLE) {
        _unpause();
        emit EmergencyUnpause(msg.sender, block.timestamp);
    }

    /// @notice Returns the number of decimal places used in token amounts
    /// @dev This implementation uses 6 decimal places for token precision
    /// @return uint8 The number of decimal places (6)
    function decimals() public pure override returns (uint8) {
        return 6;
    }
    
    /// @notice Internal function called before any token transfer
    /// @dev Required override when using multiple inheritance with ERC20PausableUpgradeable and ERC20CappedUpgradeable
    /// @dev Checks if contract is paused and enforces supply cap before allowing transfers
    /// @param from Address tokens are transferred from
    /// @param to Address tokens are transferred to
    /// @param value Amount of tokens transferred
    function _update(
        address from,
        address to,
        uint256 value
    ) internal override(ERC20Upgradeable, ERC20PausableUpgradeable, ERC20CappedUpgradeable) {
        super._update(from, to, value);
    }
}
