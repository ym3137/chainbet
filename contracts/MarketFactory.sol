// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import "./PredictionMarket.sol";

/**
 * @title MarketFactory
 * @notice Factory contract to create and track multiple prediction markets
 * @dev Uses a default initial liquidity amount for each side of the AMM
 */
contract MarketFactory {
    using SafeERC20 for IERC20;

    address[] public markets;

    uint256 public constant DEFAULT_INITIAL_LIQUIDITY = 1_000_000;

    event MarketCreated(
        address indexed market,
        string question,
        address indexed token,
        address indexed oracle,
        uint256 lockTime
    );

    function createMarket(
        string memory question,
        address token,
        address oracle,
        uint256 lockTime
    ) external returns (address marketAddr) {
        require(bytes(question).length > 0, "Question required");
        require(token != address(0), "Invalid token");
        require(oracle != address(0), "Invalid oracle");
        require(lockTime > block.timestamp, "Lock time must be in future");

        PredictionMarket market = new PredictionMarket(
            question,
            lockTime,
            oracle,
            token,
            DEFAULT_INITIAL_LIQUIDITY
        );

        marketAddr = address(market);
        markets.push(marketAddr);

        IERC20(token).safeTransferFrom(
            msg.sender,
            marketAddr,
            DEFAULT_INITIAL_LIQUIDITY * 2
        );

        emit MarketCreated(marketAddr, question, token, oracle, lockTime);
    }

    function getMarkets() external view returns (address[] memory) {
        return markets;
    }

    function getMarketCount() external view returns (uint256) {
        return markets.length;
    }
}