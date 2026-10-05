// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import "@openzeppelin/contracts/token/ERC20/ERC20.sol";

/**
 * @title MockUSDC
 * @notice Demo/test token for ChainBet
 * @dev Anyone can mint tokens to themselves for testing
 */
contract MockUSDC is ERC20 {
    uint8 private constant _DECIMALS = 6;

    constructor(uint256 initialSupply) ERC20("Mock USDC", "mUSDC") {
        if (initialSupply > 0) {
            _mint(msg.sender, initialSupply);
        }
    }

    /**
     * @notice Mint test tokens to yourself
     * @param amount Amount of mUSDC to mint
     */
    function mint(uint256 amount) external {
        require(amount > 0, "Amount must be > 0");
        _mint(msg.sender, amount);
    }

    /**
     * @notice Override decimals to mimic real USDC
     */
    function decimals() public pure override returns (uint8) {
        return _DECIMALS;
    }
}