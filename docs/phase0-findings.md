# Phase 0 — On-Chain Verification Findings (Flap Dividend Integration)

Date: 2026-06-11
Network: BSC mainnet (chainid 56), observed around block 103,575,000–103,597,000
Method: `cast` (foundry 1.5.0) read-only calls, `eth_call` simulations with state
overrides, event log scans, BscScan verified-ABI retrieval, and the official
NatSpec `IDividend` interface recovered from a vendored copy on GitHub.

---

## 1. Summary Verdict

| # | Our code's assumption | Verdict | Evidence |
|---|---|---|---|
| 1 | `deposit(uint256 amount)` pulls pre-approved WBNB from caller; external (arbitrary-caller) deposits allowed | **YES — HOLDS** | Signature exists exactly as assumed (`deposit(uint256) returns (bool success)`, selector `0xb6b55f25`). Full `eth_call` simulation from a random EOA with state-overridden WBNB balance + allowance **succeeds and returns `true`** on two independent RPCs and on BOTH deployed implementation versions. No caller gate. See §3.1. |
| 2 | `pending(address user) view returns (uint256)` is the per-holder claimable view | **NO (name) / YES (function)** | There is **no `pending(address)`** function. The functional equivalent exists with a different name: `withdrawableDividends(address user) view returns (uint256)` (canonical, per official `IDividend` NatSpec) and its alias `withdrawableDividendOf(address user) view returns (uint256)`. Empirically both return identical values for a real holder. **Our code must be renamed to call `withdrawableDividends(address)`.** See §3.2. |

Overall: **PARTIAL** — the deposit path is confirmed end-to-end; the pending view
must be re-pointed from `pending(address)` to `withdrawableDividends(address)`.

---

## 2. Live Contracts Inspected

Discovery path: scanned recent event logs of the Flap Portal
(`0xe2cE6ab80874Fa9Fa2aAE65D277Dd6B8e65C9De0`) and resolved per-token contracts
via `dividendContract()` / `taxProcessor()` on the tokens found.

| Role | Address | Notes |
|---|---|---|
| Flap V3 tax token "Predict" | `0x4A45c13924075BeCF6EC08Bb473FF777eC3E7777` | active, totalDividendsDistributed = 327186261986365708 (≈0.327 WBNB) |
| Predict Dividend (proxy) | `0xD5D6Ca1Eb5c7a3b63DF6EcDdE3B0fEd1bf85b510` | EIP-1167 minimal proxy |
| Predict Dividend implementation | `0xbd17a18c79b70187159870f9e09165a6c8132d91` | BscScan-verified, contract name **`Dividend`** |
| Predict TaxProcessor | `0x80F067fCA073C7ADF3c01B880F85A5af7baF402D` | `excludedFromDividends(taxProcessor) == true` |
| Flap V3 tax token "Goat" | `0x5501ea8aecc8eaeff8efde906775765e20c87777` | active, no dividends deposited yet |
| Goat Dividend (proxy) | `0x6696ffE28C4E94900ecb448778a23D14398dc446` | EIP-1167 minimal proxy |
| Goat Dividend implementation | `0x0bfa35e8e5a467c002fd5f0f692b362f4fdfb56a` | newer impl version: adds `setDividendToken(address)`, `getMagnifiedDividendPerShare()` |
| Goat TaxProcessor | `0x6f20a9541C393D6b8689dc6f431a7E1954773183` | |

Both Dividend proxies report:
- `dividendToken() == weth() == WBNB (0xbb4CdB9CBd36B01bD1cBaEBF2De08d9173bc095c)`
- `owner() == Flap Portal (0xe2cE6ab80874Fa9Fa2aAE65D277Dd6B8e65C9De0)`

Architecture: **one EIP-1167 clone per tax token**, pointing at a shared
`Dividend` implementation. Two implementation versions are live in the wild, so
the vault MUST resolve the dividend address at runtime via
`taxToken.dividendContract()` and never hardcode it.

Accounting model is MasterChef-style:
`userInfo(address) -> (uint256 share, uint256 rewardDebt, uint256 pendingBalance)`
plus a global `magnifiedDividendPerShare` updated on `deposit`.

---

## 3. Dividend Contract Analysis

Source-of-truth used:
1. Full verified ABI of impl `0xbd17a18c...2d91` retrieved from BscScan
   (contract name `Dividend`).
2. Official NatSpec interface `IDividend.sol` (recovered from a vendored copy of
   the Flap verified sources in `SynexSecure/Synex-Token-Smart-Contract`).
3. Live `eth_call` behavioral probes (the implementation's Solidity body itself
   is not directly retrievable through currently reachable channels; all
   security-relevant claims below are backed by on-chain behavioral evidence).

### 3.1 Deposit path (assumption 1) — VERIFIED OPEN TO EXTERNAL CALLERS

```solidity
/// @notice Deposit dividends to be distributed
/// @param amount The amount of dividend tokens to deposit
/// @return success Whether the deposit was successful
function deposit(uint256 amount) external returns (bool success);
```

- Mechanism: **approve-then-pull**. The contract executes a SafeERC20
  `transferFrom(msg.sender, ...)` of `dividendToken` (WBNB). Direct
  transfer + sync is NOT the model; there is no `sync()`-style function.
- Gate: **none.** Behavioral proof (Predict Dividend `0xD5D6...b510`):
  - `deposit(1)` from random EOA `0x1111...1234` with no approval reverts with
    `"SafeERC20: low-level call failed"` — i.e. execution reached the WBNB
    `transferFrom`, so no caller check precedes it.
  - `deposit(0)` from the same random EOA returns `false` (no revert).
  - `deposit(1e18)` from the same random EOA with state-overridden WBNB
    balance + allowance (`--override-state-diff`) **returns `true`** — full
    success path. Confirmed identically on `bsc-rpc.publicnode.com` and
    `bsc-dataseed.binance.org`, and on the Goat Dividend (newer impl) as well.
- Contrast (proving gates exist where intended):
  - `setShare(address,uint256)` from random EOA reverts:
    `"Dividend: caller is not the tax token"` (NatSpec: "only callable by
    FlapTaxToken").
  - `emergencyWithdraw(address,uint256,address)` from random EOA reverts:
    `"Ownable: caller is not the owner"` (owner = Flap Portal).
- Event emitted on success:
  `FlapDividendDeposited(address indexed taxToken, uint256 amount, uint256 magnifiedDividendPerShare)`
  (topic0 `0xf27ab1f08a81fd83c11906204a427fc8161b153ac4f9ec99dbfdd179770667dc`)
  — usable for harvest reconciliation.

**Conclusion: our `harvest()` can `WBNB.approve(dividend, amt)` then
`dividend.deposit(amt)`. The vault MUST check the `bool` return value
(`require(success)`), since failure modes return `false` instead of reverting.**

### 3.2 Frontend-facing pending view (assumption 2)

There is no `pending(address)`. Actual signatures (verified ABI):

```solidity
// canonical, defined in official IDividend:
function withdrawableDividends(address user) external view returns (uint256);
// alias also present on the implementation:
function withdrawableDividendOf(address user) external view returns (uint256);
// supporting views:
function accumulativeDividendOf(address user) external view returns (uint256);
function withdrawnDividends(address user) external view returns (uint256);
function userInfo(address) external view returns (uint256 share, uint256 rewardDebt, uint256 pendingBalance);
```

Empirical check on a real Predict holder `0x5aed19903c0b11b5713feccaf93d32c9e2bdd72b`:
`userInfo = (share 0, rewardDebt 0, pendingBalance 3379911027180381)`;
`withdrawableDividendOf == withdrawableDividends == accumulativeDividendOf
== 3379911027180381` (≈0.00338 WBNB), `withdrawnDividends == 0`.
The two pending views agreed in every state sampled. Recommendation: use
`withdrawableDividends(address)` (the interface-canonical name).

### 3.3 Claim path (holders)

```solidity
/// User self-claim; unwraps WBNB to native BNB
function withdrawDividends() external returns (bool success);
/// Permissionless third-party push (verified: callable by any address)
function withdrawDividendsFor(address user) external returns (bool success);
function withdrawDividendsFor(address user, bool unwrapWETH) external returns (bool success);
/// Permissionless batch push
function distributeDividend(address[] calldata users) external returns (uint256 successCount);
```

Behavioral check: `withdrawDividends()` and `withdrawDividendsFor(user)` called
from random EOAs both execute without permission reverts (no-op `false` when
nothing is claimable). The contract has `receive() payable` and a
`FlapDividendWithdrawalFailed` event, consistent with unwrap-to-BNB payout with
a failure-tolerant send.

### 3.4 Eligibility constraint worth noting

`minimumShareBalance()` gates share registration: Predict = `2e24`
(2,000,000 tokens with 18 decimals), Goat = `1e22` (10,000 tokens) — it is
per-token configuration. Holders below the threshold have `share == 0` and
accrue nothing from future deposits. Implication for MyxVault: if the vault
itself ever holds the tax token and is not excluded
(`excludedFromDividends(vault)`), it will itself accrue dividends once above
the threshold; conversely small holders receive nothing from our forwarded
rewards.

---

## 4. Canonical Address Table (verified outputs)

RPC used for these reads: `https://bsc-dataseed.binance.org`.

| Contract | Address | Call | Output | OK |
|---|---|---|---|---|
| WBNB | `0xbb4CdB9CBd36B01bD1cBaEBF2De08d9173bc095c` | `symbol()` | `"WBNB"` | YES |
| USDT (BSC) | `0x55d398326f99059fF775485246999027B3197955` | `symbol()` / `decimals()` | `"USDT"` / `18` | YES |
| PancakeSwap V2 Router | `0x10ED43C718714eb63d5aA57B78B54704E256024E` | `WETH()` | `0xbb4CdB9CBd36B01bD1cBaEBF2De08d9173bc095c` (= WBNB) | YES |
| Chainlink BNB/USD | `0x0567F2323251f0Aab15c8dFb1967E4e8A7D42aeE` | `decimals()` | `8` | YES |
| Chainlink USDT/USD | `0xB97Ad0E74fa7d920791E90258A6E2085088b4320` | `decimals()` | `8` | YES |
| Flap Portal | `0xe2cE6ab80874Fa9Fa2aAE65D277Dd6B8e65C9De0` | EIP-1967 impl slot | impl `0x9ddd09e0da193948f085adb8e32323b4af35d53e` | proxy, live |
| Flap VaultPortal | `0x90497450f2a706f1951b5bdda52B4E5d16f34C06` | EIP-1967 impl slot | impl `0x4b51f65bc19c998b5cd2237b6b918b9ce98a87a4` | proxy, live |
| GiftV4VaultFactoryV2 | `0x6909aD1822Ece349CDDAb98E6F62EeeD9fAa2e10` | `eth_getCode` | ~13 KB runtime code | live (not needed for discovery) |

---

## 5. Network / Transport Notes

- Working RPCs: `https://bsc-dataseed.binance.org` and
  `https://bsc-dataseed1.defibit.io` (plain `eth_call` only; `eth_getLogs`
  rejected with `-32005 limit exceeded` at any range). State-override
  `eth_call` worked on `bsc-dataseed.binance.org` but timed out intermittently.
- `https://rpc.ankr.com/bsc`: **unusable** — requires API key (`-32000 Unauthorized`).
- `https://bsc-rpc.publicnode.com` and `https://bsc.drpc.org`: support
  `eth_getLogs` (~2,000–20,000 block ranges) and state-override `eth_call`;
  intermittent timeouts, retries needed. `https://1rpc.io/bnb` limits
  `eth_getLogs` to 50 blocks.
- BscScan API v1 is **deprecated**; Etherscan API v2 requires a key. Sourcify
  has no match for the impl. `anyabi.xyz` returned the ABI once, then
  rate-limited. Direct WebFetch of `bscscan.com` timed out consistently; the
  **`r.jina.ai` reader proxy** succeeded and returned the full verified ABI and
  contract name. `flap.sh` was unreachable from this network.
- The official `IDividend.sol` NatSpec interface was recovered from GitHub repo
  `SynexSecure/Synex-Token-Smart-Contract` (a vendored copy of the Flap
  verified sources; found via code search for the unique event name
  `FlapDividendDeposited`).

---

## 6. Open Issues

1. **`deposit` returns `bool` instead of reverting.** `harvest()` MUST
   `require(dividend.deposit(amount), ...)`. A `false` return appears to mean
   "nothing was pulled" (`deposit(0)` did not revert and pulled nothing), but
   silent-false handling must be explicit in our code.
2. **`totalShares == 0` deposit behavior unverified at source level.** Both
   live pools had `totalShares > 0`. By symmetry with `deposit(0) -> false` the
   expected behavior is `return false` without pulling funds, but this is a
   medium-confidence inference. Mitigation: check `totalShares() > 0` before
   depositing, and always check the return value. Add an integration/fork test.
3. **Two implementation versions are live** (`0xbd17...2d91` and
   `0x0bfa...b56a`). The integration surface we use (`deposit`,
   `withdrawableDividends`, `withdrawDividends*`) is identical across both,
   but new tokens may clone newer impls — always resolve via
   `taxToken.dividendContract()` at runtime.
4. **Custody/trust surface:** `owner()` of every Dividend clone is the Flap
   Portal, and `emergencyWithdraw(token, amount, to)` is `onlyOwner` and can
   drain deposited-but-unclaimed WBNB. Funds forwarded by our `harvest()` sit
   under Flap admin-key risk until holders claim. This must be stated in our
   risk docs; it is not mitigable on our side.
5. **`withdrawableDividendOf` vs `withdrawableDividends` equivalence** was
   confirmed only on states with `share == 0` (pure `pendingBalance`). For a
   holder with active share and unsettled accrual the equality is
   high-confidence (alias pattern) but not source-verified — cover with a fork
   test if the frontend reads it pre-claim.
6. **`minimumShareBalance` exclusion** (per-token, e.g. 2M tokens for Predict):
   small holders receive nothing from our forwarded rewards; deposits are
   socialized only across registered shares. Product/docs should disclose this.
