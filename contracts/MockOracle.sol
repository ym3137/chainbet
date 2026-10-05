// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import "@openzeppelin/contracts/access/Ownable.sol";

interface IPredictionMarketOracle {
    function lockMarket() external;
    function resolveMarket(uint8 _outcome) external;
}

/**
 * @title MockOracle
 * @notice Admin-controlled oracle for demo settlement
 * @dev Owner can manually set market result, simulating real-world oracle update
 */
contract MockOracle is Ownable {
    // market => result
    // 0 = NONE, 1 = YES, 2 = NO
    mapping(address => uint8) public marketResults;

    event ResultSet(address indexed market, uint8 indexed outcome);

    constructor() Ownable(msg.sender) {}

    /**
     * @notice Set the result for a prediction market
     * @param market Address of the PredictionMarket contract
     * @param outcome 1 = YES, 2 = NO
     */
    function setResult(address market, uint8 outcome) external onlyOwner {
        require(market != address(0), "Invalid market");
        require(outcome == 1 || outcome == 2, "Outcome must be 1 or 2");

        marketResults[market] = outcome;

        IPredictionMarketOracle(market).lockMarket();
        IPredictionMarketOracle(market).resolveMarket(outcome);

        emit ResultSet(market, outcome);
    }
}