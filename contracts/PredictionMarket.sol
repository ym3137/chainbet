// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import "@openzeppelin/contracts/utils/ReentrancyGuard.sol";

/**
 * @title PredictionMarket
 * @notice Core AMM-based prediction market contract for ChainBet.
 *         Uses constant-product formula (x · y = k) to price Yes/No outcome shares.
 * @dev    Member 1 deliverable — APANPS5470 Final Project
 *
 *  Lifecycle:  OPEN  →  LOCKED  →  RESOLVED  →  CLOSED
 *              (buy/sell)  (no trading)  (claim winnings)  (all claimed)
 */
contract PredictionMarket is ReentrancyGuard {
    using SafeERC20 for IERC20;

    // ──────────────────────────────────────────────
    //  Enums & Structs
    // ──────────────────────────────────────────────

    enum MarketState { OPEN, LOCKED, RESOLVED, CLOSED }
    enum Outcome     { NONE, YES, NO }

    // ──────────────────────────────────────────────
    //  State Variables
    // ──────────────────────────────────────────────

    // --- Market metadata ---
    string  public  eventDescription;   // e.g. "Lakers vs Warriors — Mar 30"
    uint256 public  lockTimestamp;       // UNIX ts when trading stops
    address public  oracle;             // MockOracle address authorised to resolve
    address public  factory;            // MarketFactory that created this market

    // --- Token ---
    IERC20  public  collateralToken;    // MockUSDC (ERC-20)

    // --- AMM pools ---
    uint256 public  yesPool;            // reserve of YES side
    uint256 public  noPool;             // reserve of NO  side
    uint256 public  k;                  // invariant = yesPool * noPool

    // --- Protocol fee ---
    uint256 public  constant FEE_BPS = 200;       // 2 % protocol fee on winnings
    uint256 public  constant BPS     = 10_000;
    uint256 public  protocolFees;                  // accumulated fees

    // --- State ---
    MarketState public state;
    Outcome     public winningOutcome;

    // --- Shares tracking ---
    mapping(address => uint256) public yesShares;  // user → YES shares held
    mapping(address => uint256) public noShares;   // user → NO  shares held
    uint256 public totalYesShares;
    uint256 public totalNoShares;

    // --- Claim tracking ---
    mapping(address => bool) public hasClaimed;

    // ──────────────────────────────────────────────
    //  Events
    // ──────────────────────────────────────────────

    event SharesBought(
        address indexed buyer,
        bool    isYes,
        uint256 amountIn,
        uint256 sharesOut
    );

    event SharesSold(
        address indexed seller,
        bool    isYes,
        uint256 sharesIn,
        uint256 amountOut
    );

    event MarketLocked(uint256 timestamp);

    event MarketResolved(Outcome outcome, uint256 timestamp);

    event WinningsClaimed(
        address indexed user,
        uint256 payout
    );

    event LiquidityAdded(
        address indexed provider,
        uint256 yesAmount,
        uint256 noAmount
    );

    // ──────────────────────────────────────────────
    //  Modifiers
    // ──────────────────────────────────────────────

    modifier onlyOracle()  { require(msg.sender == oracle,  "Only oracle");  _; }
    modifier onlyFactory() { require(msg.sender == factory, "Only factory"); _; }
    modifier inState(MarketState _s) { require(state == _s, "Wrong state"); _; }

    // ──────────────────────────────────────────────
    //  Constructor / Initialiser
    // ──────────────────────────────────────────────

    /**
     * @notice Initialise a new prediction market.
     * @param _event          Human-readable event description
     * @param _lockTimestamp   UNIX timestamp after which trading is disabled
     * @param _oracle          Address allowed to call resolveMarket()
     * @param _collateral      MockUSDC token address
     * @param _initialLiquidity Amount of collateral to seed EACH side of the pool
     *                          (total collateral required = 2 × _initialLiquidity)
     *
     * The factory transfers (2 × _initialLiquidity) to this contract before calling.
     */
    constructor(
        string  memory _event,
        uint256 _lockTimestamp,
        address _oracle,
        address _collateral,
        uint256 _initialLiquidity
    ) {
        require(_initialLiquidity > 0, "Need initial liquidity");
        require(_lockTimestamp > block.timestamp, "Lock must be future");

        eventDescription = _event;
        lockTimestamp     = _lockTimestamp;
        oracle           = _oracle;
        factory          = msg.sender;
        collateralToken  = IERC20(_collateral);

        // Seed 50/50 pool
        yesPool = _initialLiquidity;
        noPool  = _initialLiquidity;
        k       = yesPool * noPool;

        state = MarketState.OPEN;
    }

    // ──────────────────────────────────────────────
    //  Core AMM — Buy Shares
    // ──────────────────────────────────────────────

    /**
     * @notice Buy YES or NO shares by depositing collateral.
     * @param _isYes    true = buy YES shares, false = buy NO shares
     * @param _amountIn Amount of collateral (MockUSDC) to spend
     * @return sharesOut Number of shares received
     *
     *  Math (constant-product):
     *    poolIn_new  = poolIn + amountIn
     *    poolOut_new = k / poolIn_new
     *    sharesOut   = poolOut - poolOut_new
     *
     *  After the trade the invariant is restored:
     *    yesPool * noPool == k  (always)
     */
    function buyShares(bool _isYes, uint256 _amountIn)
        external
        nonReentrant
        inState(MarketState.OPEN)
        returns (uint256 sharesOut)
    {
        require(block.timestamp < lockTimestamp, "Trading locked");
        require(_amountIn > 0, "Amount must be > 0");

        // Pull collateral from buyer
        collateralToken.safeTransferFrom(msg.sender, address(this), _amountIn);

        // AMM calculation
        if (_isYes) {
            uint256 newNoPool = noPool + _amountIn;   // collateral goes into opposite pool
            uint256 newYesPool = k / newNoPool;
            sharesOut = yesPool - newYesPool;

            yesPool = newYesPool;
            noPool  = newNoPool;

            yesShares[msg.sender] += sharesOut;
            totalYesShares        += sharesOut;
        } else {
            uint256 newYesPool = yesPool + _amountIn;
            uint256 newNoPool  = k / newYesPool;
            sharesOut = noPool - newNoPool;

            yesPool = newYesPool;
            noPool  = newNoPool;

            noShares[msg.sender] += sharesOut;
            totalNoShares        += sharesOut;
        }

        emit SharesBought(msg.sender, _isYes, _amountIn, sharesOut);
    }

    // ──────────────────────────────────────────────
    //  Core AMM — Sell Shares
    // ──────────────────────────────────────────────

    /**
     * @notice Sell YES or NO shares back to the pool for collateral.
     * @param _isYes     true = sell YES shares, false = sell NO shares
     * @param _sharesIn  Number of shares to sell
     * @return amountOut Collateral returned to seller
     *
     *  Math (reverse of buy):
     *    poolIn_new  = poolIn + sharesIn          // shares returned to pool
     *    poolOut_new = k / poolIn_new
     *    amountOut   = poolOut - poolOut_new       // collateral withdrawn
     */
    function sellShares(bool _isYes, uint256 _sharesIn)
        external
        nonReentrant
        inState(MarketState.OPEN)
        returns (uint256 amountOut)
    {
        require(block.timestamp < lockTimestamp, "Trading locked");
        require(_sharesIn > 0, "Shares must be > 0");

        if (_isYes) {
            require(yesShares[msg.sender] >= _sharesIn, "Insufficient YES shares");

            uint256 newYesPool = yesPool + _sharesIn;
            uint256 newNoPool  = k / newYesPool;
            amountOut = noPool - newNoPool;

            yesPool = newYesPool;
            noPool  = newNoPool;

            yesShares[msg.sender] -= _sharesIn;
            totalYesShares        -= _sharesIn;
        } else {
            require(noShares[msg.sender] >= _sharesIn, "Insufficient NO shares");

            uint256 newNoPool  = noPool + _sharesIn;
            uint256 newYesPool = k / newNoPool;
            amountOut = yesPool - newYesPool;

            yesPool = newYesPool;
            noPool  = newNoPool;

            noShares[msg.sender] -= _sharesIn;
            totalNoShares        -= _sharesIn;
        }

        // Transfer collateral back to seller
        collateralToken.safeTransfer(msg.sender, amountOut);

        emit SharesSold(msg.sender, _isYes, _sharesIn, amountOut);
    }

    // ──────────────────────────────────────────────
    //  Price & Probability Getters
    // ──────────────────────────────────────────────

    /**
     * @notice Get the current implied probability for YES outcome (in BPS).
     * @return probBps  e.g. 6000 = 60.00%
     *
     *  Formula:  P(YES) = noPool / (yesPool + noPool)
     *  Intuition: if more collateral is on the NO side, YES is more expensive → higher probability.
     */
    function getYesProbability() external view returns (uint256 probBps) {
        probBps = (noPool * BPS) / (yesPool + noPool);
    }

    /**
     * @notice Get the current implied probability for NO outcome (in BPS).
     */
    function getNoProbability() external view returns (uint256 probBps) {
        probBps = (yesPool * BPS) / (yesPool + noPool);
    }

    /**
     * @notice Preview how many shares a buyer would get for a given collateral amount.
     * @param _isYes    Which side
     * @param _amountIn Collateral to spend
     * @return sharesOut Expected shares (before any state change)
     */
    function getPrice(bool _isYes, uint256 _amountIn)
        external
        view
        returns (uint256 sharesOut)
    {
        if (_isYes) {
            uint256 newNoPool  = noPool + _amountIn;
            uint256 newYesPool = k / newNoPool;
            sharesOut = yesPool - newYesPool;
        } else {
            uint256 newYesPool = yesPool + _amountIn;
            uint256 newNoPool  = k / newYesPool;
            sharesOut = noPool - newNoPool;
        }
    }

    /**
     * @notice Preview how much collateral a seller would receive for given shares.
     * @param _isYes    Which side
     * @param _sharesIn Shares to sell
     * @return amountOut Expected collateral (before any state change)
     */
    function getSellPrice(bool _isYes, uint256 _sharesIn)
        external
        view
        returns (uint256 amountOut)
    {
        if (_isYes) {
            uint256 newYesPool = yesPool + _sharesIn;
            uint256 newNoPool  = k / newYesPool;
            amountOut = noPool - newNoPool;
        } else {
            uint256 newNoPool  = noPool + _sharesIn;
            uint256 newYesPool = k / newNoPool;
            amountOut = yesPool - newYesPool;
        }
    }

    // ──────────────────────────────────────────────
    //  Market Lifecycle
    // ──────────────────────────────────────────────

    /**
     * @notice Lock the market — called automatically when timestamp passes,
     *         or manually by oracle/factory.
     */
    function lockMarket()
        external
        inState(MarketState.OPEN)
    {
        require(
            block.timestamp >= lockTimestamp ||
            msg.sender == oracle ||
            msg.sender == factory,
            "Not yet lockable"
        );
        state = MarketState.LOCKED;
        emit MarketLocked(block.timestamp);
    }

    /**
     * @notice Oracle writes the match result on-chain.
     * @param _outcome  1 = YES, 2 = NO (0 reverts)
     */
    function resolveMarket(uint8 _outcome)
        external
        onlyOracle
        inState(MarketState.LOCKED)
    {
        require(_outcome == 1 || _outcome == 2, "Invalid outcome");
        winningOutcome = Outcome(_outcome);
        state = MarketState.RESOLVED;
        emit MarketResolved(winningOutcome, block.timestamp);
    }

    // ──────────────────────────────────────────────
    //  Claim Winnings
    // ──────────────────────────────────────────────

    /**
     * @notice Winners call this to claim their payout.
     *
     *  Payout formula:
     *    totalPool    = contract's full collateral balance
     *    userShares   = user's winning-side shares
     *    totalShares  = total winning-side shares outstanding
     *    grossPayout  = totalPool × (userShares / totalShares)
     *    fee          = grossPayout × FEE_BPS / BPS
     *    netPayout    = grossPayout − fee
     */
    function claimWinnings()
        external
        nonReentrant
        inState(MarketState.RESOLVED)
    {
        require(!hasClaimed[msg.sender], "Already claimed");

        uint256 userShares;
        uint256 totalShares;

        if (winningOutcome == Outcome.YES) {
            userShares  = yesShares[msg.sender];
            totalShares = totalYesShares;
        } else {
            userShares  = noShares[msg.sender];
            totalShares = totalNoShares;
        }

        require(userShares > 0, "No winning shares");

        uint256 totalPool   = collateralToken.balanceOf(address(this)) - protocolFees;
        uint256 grossPayout = (totalPool * userShares) / totalShares;

        // Deduct protocol fee
        uint256 fee       = (grossPayout * FEE_BPS) / BPS;
        uint256 netPayout = grossPayout - fee;
        protocolFees += fee;

        hasClaimed[msg.sender] = true;

        collateralToken.safeTransfer(msg.sender, netPayout);

        emit WinningsClaimed(msg.sender, netPayout);
    }

    // ──────────────────────────────────────────────
    //  Admin / Factory Helpers
    // ──────────────────────────────────────────────

    /**
     * @notice Factory withdraws accumulated protocol fees.
     */
    function withdrawFees(address _to)
        external
        onlyFactory
    {
        uint256 amount = protocolFees;
        require(amount > 0, "No fees");
        protocolFees = 0;
        collateralToken.safeTransfer(_to, amount);
    }

    /**
     * @notice Emergency: factory can close a market if it was never resolved
     *         (e.g. event cancelled). Refunds all collateral proportionally.
     */
    function emergencyCancel()
        external
        onlyFactory
    {
        require(state != MarketState.RESOLVED && state != MarketState.CLOSED, "Cannot cancel");
        state = MarketState.CLOSED;
        // In a cancelled market, users can call emergencyRefund()
    }

    /**
     * @notice Refund after emergency cancellation.
     *         Returns collateral proportional to total shares held.
     */
    function emergencyRefund()
        external
        nonReentrant
    {
        require(state == MarketState.CLOSED && winningOutcome == Outcome.NONE, "Not cancelled");
        require(!hasClaimed[msg.sender], "Already refunded");

        uint256 userTotal  = yesShares[msg.sender] + noShares[msg.sender];
        uint256 grandTotal = totalYesShares + totalNoShares;
        require(userTotal > 0, "No shares");

        uint256 pool   = collateralToken.balanceOf(address(this));
        uint256 refund = (pool * userTotal) / grandTotal;

        hasClaimed[msg.sender] = true;
        collateralToken.safeTransfer(msg.sender, refund);
    }

    // ──────────────────────────────────────────────
    //  View Helpers
    // ──────────────────────────────────────────────

    /// @notice Returns pool reserves and invariant
    function getPoolInfo()
        external
        view
        returns (uint256 _yesPool, uint256 _noPool, uint256 _k)
    {
        return (yesPool, noPool, k);
    }

    /// @notice Returns a user's share balances
    function getUserShares(address _user)
        external
        view
        returns (uint256 _yes, uint256 _no)
    {
        return (yesShares[_user], noShares[_user]);
    }
}
