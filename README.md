# ChainBet — A Decentralized Sports Prediction Market

An on-chain prediction market where the odds are set by an automated market maker rather than a bookmaker. Users buy YES/NO outcome shares with an ERC-20 stablecoin; the price of each share *is* the market's implied probability. Settlement, payout and fee collection all happen on-chain.

Built as the final project for **APANPS5470 Blockchain Technology & Applications**, Columbia University, Feb–May 2026 (Group 7).

**Deployed and source-verified on Ethereum Sepolia.**

---

## My role

This was a team project. I was Member 1 and **wrote the core contract, [`contracts/PredictionMarket.sol`](contracts/PredictionMarket.sol)** — the AMM pricing, share trading, lifecycle state machine and payout settlement.

The rest of the repository is included so the system can actually be read and run end to end, and is credited to the team: `MarketFactory.sol`, `MockUSDC.sol` and `MockOracle.sol` were group deliverables, and the web frontend (vanilla HTML + ethers.js + MetaMask, deployed on Vercel) lives in a teammate's repository at [`hiharryyim/chainbet-frontend`](https://github.com/hiharryyim/chainbet-frontend).

---

## How the pricing works

The market holds two reserves, `yesPool` and `noPool`, and preserves the constant-product invariant:

```
yesPool × noPool = k
```

Buying YES means pushing collateral into the **opposite** reserve and taking YES shares out:

```
noPool'   = noPool + amountIn
yesPool'  = k / noPool'
sharesOut = yesPool − yesPool'
```

The implied probability falls straight out of the reserve ratio:

```
P(YES) = noPool / (yesPool + noPool)
```

No one quotes a line. If more collateral sits on the NO side, YES gets more expensive, which *is* the market saying YES is more likely. Worked example from the demo: in a 1,000 / 1,000 pool, spending 200 mUSDC on YES returns ≈167 shares and moves P(YES) from 50% to ≈59%.

`getPrice()` and `getSellPrice()` are `view` previews of the same math, so a frontend can quote a trade before the user signs it.

---

## Lifecycle

```
OPEN  ──────────►  LOCKED  ──────────►  RESOLVED  ──────────►  (claimed)
 buy / sell        no trading           oracle wrote           winners call
 shares            allowed              the outcome            claimWinnings()
                                   │
                         CLOSED ◄──┘  emergencyCancel() → pro-rata emergencyRefund()
```

- `lockMarket()` — anyone can call it once `lockTimestamp` has passed; the oracle and factory can call it early.
- `resolveMarket(uint8)` — `onlyOracle`, valid only from `LOCKED`, outcome must be 1 (YES) or 2 (NO).
- `claimWinnings()` — winners take a share of the collateral pool proportional to their winning-side shares, less a **2% protocol fee** (`FEE_BPS = 200`). Accrued fees are withdrawable by the factory via `withdrawFees()`.
- `emergencyCancel()` / `emergencyRefund()` — if an event is cancelled before resolution, collateral is returned pro rata across all shares held.

---

## Security choices

| Concern | What the contract does |
| --- | --- |
| Reentrancy | OpenZeppelin `ReentrancyGuard` on every state-changing external function (`buyShares`, `sellShares`, `claimWinnings`, `emergencyRefund`) |
| Token transfer failures | OpenZeppelin `SafeERC20` for all collateral movement |
| Double claiming | Checks-Effects-Interactions — `hasClaimed[msg.sender]` is set **before** the transfer, not after |
| Authorization | `onlyOracle` for resolution, `onlyFactory` for fee withdrawal and emergency cancellation, `inState` for every lifecycle transition |
| Timing | Trading reverts once `block.timestamp >= lockTimestamp`, independent of whether anyone has called `lockMarket()` |

---

## Known limitations

Written down deliberately — this is a course build, not production code.

1. **Payout depends on claim order.** `claimWinnings()` computes the pool from the contract's *current* collateral balance but never decrements the winning-side share total. Whoever claims first receives a larger payout than whoever claims last. The fix is to snapshot the pool at resolution and settle against that fixed number.
2. **The oracle is trusted.** `MockOracle` is an owner-controlled contract that writes the result by hand. A production version needs a real oracle or a dispute/escalation mechanism.
3. **No liquidity-provider economics.** The pool is seeded once by the factory and there is no LP position, no LP share token and no fee split to liquidity providers. The 2% fee accrues to the protocol and is withdrawn by the factory. (An LP revenue split appears in our business-model slide as a *design proposal only* — it is not implemented here.)
4. **No fee on trades.** Fees are taken at payout, not on each buy/sell, so round-tripping a position is close to free apart from AMM slippage.
5. **No automated test suite in this repository.** The contracts were exercised manually against Sepolia through the frontend.

---

## Deployments — Ethereum Sepolia (chain ID 11155111)

All three verified on Sourcify with an exact match (creation + runtime), 2026-04-19, solc `0.8.20+commit.a1b79de6`.

| Contract | Address |
| --- | --- |
| `MarketFactory` | [`0x801244447eACc650b9f417DfA8fB1CC9AE3F38DF`](https://sepolia.etherscan.io/address/0x801244447eACc650b9f417DfA8fB1CC9AE3F38DF) |
| `MockUSDC` | [`0xe889A9b22C062b2dBcf27a38452cA5BdCF8fDFf7`](https://sepolia.etherscan.io/address/0xe889A9b22C062b2dBcf27a38452cA5BdCF8fDFf7) |
| `MockOracle` | [`0x64593677f0983b3046E12cAe37D36A1719D46582`](https://sepolia.etherscan.io/address/0x64593677f0983b3046E12cAe37D36A1719D46582) |

Individual `PredictionMarket` instances are deployed by the factory at runtime; read them from `MarketFactory.getMarkets()`.

> Note: an early version of our slide deck labelled the network "Base Sepolia". That was wrong — the verified deployments above are on **Ethereum Sepolia**.

---

## Repository layout

```
contracts/
  PredictionMarket.sol   AMM pricing, share trading, lifecycle, settlement  (my deliverable)
  MarketFactory.sol      deploys and tracks markets, seeds initial liquidity
  MockUSDC.sol           6-decimal ERC-20 test stablecoin, open mint
  MockOracle.sol         owner-controlled oracle for demo settlement
docs/
  prediction-market-flow.pdf   contract interaction / state-flow diagram
```

External dependency: OpenZeppelin Contracts v5 (`Ownable(msg.sender)` constructor form). Solidity `^0.8.20`.

---

## Running it locally

There is no build configuration in this repository — the contracts were compiled and deployed outside it. To work with them in a project of your own:

```bash
npm install @openzeppelin/contracts
# copy contracts/ into your Hardhat or Foundry sources directory
```

Deployment order matters: `MockUSDC` → `MockOracle` → `MarketFactory`. Before calling `createMarket()`, approve the factory for `2 × DEFAULT_INITIAL_LIQUIDITY` of mUSDC, because the factory transfers that amount through to the new market to seed both sides of the pool.

---

## License

MIT — see [LICENSE](LICENSE).
