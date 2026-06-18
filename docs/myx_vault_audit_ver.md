# Flap Vault Interaction Risk Report

Generated: 2026-06-18 10:26:56 UTC

## Vault Security Rating
**High**

## Status Guide / 状态说明

Please review each finding below and mark its status. / 请审阅以下每条发现并标记状态。

| Status | Meaning / 含义 |
|:---:|---|
| **TP** | True Positive — This is a real issue, we will fix it. / 确认问题，我们会修复。 |
| **FP** | False Positive — This is not a real issue, the analysis is incorrect. / 误报，分析有误。 |
| **By Design** | This is intentional behavior, not a bug. / 这是设计如此，非缺陷。 |
| **Acknowledged** | The issue is real but the impact is acceptable, will not fix. / 问题确实存在，但影响在可接受范围内，不修复。 |

Mark by replacing `[ ]` with `[x]`. If FP, By Design, or Acknowledged, please write a brief reason. / 在对应选项的 `[ ]` 中填入 `x` 标记。如标记 FP、By Design 或 Acknowledged，请简要说明理由。

---

## Risk Findings
### Finding 1: Custom errors used instead of require() with literal string messages (SYS-REQ-LITERAL-ERRORS)
- **Severity:** High
- **Confidence:** High
- **Detected by:** rule_review
- **Description:** MyxVault and MyxVaultFactory declare and revert with developer-authored custom errors and standalone revert("...") statements instead of using require() with literal string messages, violating the UI-compatibility mandate (SYS-REQ-LITERAL-ERRORS). Affected: MyxVault errors CannotRevokeGuardianRole, ZeroMarketQuoteToken, BelowMinimumProcessAmount, ZeroQuote, ZeroDividendContract, TriggerServiceNotConfigured, OnlySelf, OnlyTriggerService; MyxVaultFactory errors UnsupportedQuoteToken, OnlyGuardian, UpgradesLocked, plus revert("unsupported launchVersion").
- **Vulnerable Code:**
  - `MyxVault.revokeRole: revert CannotRevokeGuardianRole()`
  - `MyxVault.initialize: revert ZeroMarketQuoteToken()`
  - `MyxVault.process: revert BelowMinimumProcessAmount(amount, minProcessAmount)`
  - `MyxVault._buyTaxToken: revert ZeroQuote()`
  - `MyxVault.claimReward: revert ZeroDividendContract()`
  - `MyxVault._getTriggerService: revert TriggerServiceNotConfigured()`
  - `MyxVault.scheduleProcess: revert OnlySelf()`
  - `MyxVault.trigger: revert OnlyTriggerService()`
  - `MyxVaultFactory.newVault: revert UnsupportedQuoteToken()`
  - `MyxVaultFactory.onlyGuardian: revert OnlyGuardian()`
  - `MyxVaultFactory.upgradeVaultImplementation: revert UpgradesLocked()`
  - `MyxVaultFactory.resolveDividendToken: revert("unsupported launchVersion")`

> **Status:** `[x]` TP　`[ ]` FP　`[ ]` By Design　`[ ]` Acknowledged
> **Reason:** Fixed — all custom errors + single-language strings converted to bilingual literal `require`/`revert` (`unicode"English / 繁體中文"`); the Flap UI can now decode every revert reason. Also fixed the audit-missed `OnlyVaultPortal` use-site.

### Finding 2: Non-bilingual require/revert messages despite multi-language UI strings (SYS-REQ-MULTILANG)
- **Severity:** High
- **Confidence:** High
- **Detected by:** rule_review
- **Description:** The contracts establish multi-language intent (description() and vaultUISchema() use English/Chinese ` / ` separators), but several require() and revert() error strings are English-only, violating SYS-REQ-MULTILANG which mandates every user-facing string be bilingual when multi-language evidence exists.
- **Vulnerable Code:**
  - `MyxVault.scheduleProcess: "pending below min + fee"`
  - `MyxVault.emergencySweepBnb: "BNB_SWEEP_FAILED"`
  - `MyxVault.emergencyRescueToken: "Zero address"`
  - `MyxVaultFactory.resolveDividendToken: "expected V6 magic dividend"`
  - `MyxVaultFactory.resolveDividendToken: "expected V7 magic dividend"`
  - `MyxVaultFactory.resolveDividendToken: "no V7 dividend feeConfig"`
  - `MyxVaultFactory.resolveDividendToken: "unsupported launchVersion"`

> **Status:** `[x]` TP　`[ ]` FP　`[ ]` By Design　`[ ]` Acknowledged
> **Reason:** Fixed together with F1 — all messages bilingual (EN / 繁中). Note: `scheduleProcess` "pending below min + fee" and the `resolveDividendToken` asserts are technically not user-facing (self-call / staticcall) but were made bilingual anyway for consistency.

### Finding 3: Emergency roles: docs say guardian and creator can withdraw LP, but emergencyWithdraw grants no creator-specific exclusion — actually consistent; the harvest/rebate flow described in README has no implementation
- **Severity:** Medium
- **Confidence:** High
- **Detected by:** doc_review
- **Description:** The README architecture diagram describes a `harvest()` function: '[anyone] harvest(): claim LP rebates → swap → WBNB → Dividend contract'. The actual MyxVault.sol has NO `harvest()` function and NO logic that claims LP rebates, swaps them to WBNB, and forwards WBNB to the Dividend contract. Instead the implemented model (v6) feeds the mBase LP itself directly into the Dividend contract via `_feedDividend()`, with no swap and no WBNB path. The IMyxBasePool interface exposes `claimUserRebate`/`pendingUserRebates`, but the vault never calls them.
- **Vulnerable Code:**
  - `src/MyxVault.sol (no harvest function)`
  - `README.md (Architecture diagram: harvest())`

> **Status:** `[x]` TP　`[ ]` FP　`[ ]` By Design　`[ ]` Acknowledged
> **Reason:** Fixed — README architecture diagram updated to the v6 model (no harvest/swap/WBNB; `process()` buys back and `_feedDividend()` deposits the mBase LP directly). The CODE was already correct (v6); only the doc was stale.

### Finding 4: Permissionless process() buyback exposed to sandwich extraction within slippage tolerance and unbounded LP mint (COM-MEV-SANDWICH)
- **Severity:** Low
- **Confidence:** Low
- **Detected by:** attacker_review
- **Description:** MyxVault.process() is fully permissionless and converts all accumulated pendingBnb into the tax token via a same-block Portal quote then swapExactInput, then deposits the received tokens into the MYX base pool with minAmountOut=0. The buy leg minOut is computed from a quote taken in the same transaction and same pool state, so it only bounds single-call deviation and provides no protection against an attacker who manipulates the pool around the swap. Because anyone can call process() at any time and the auto-trigger timing is publicly observable, an MEV actor or BSC block proposer can sandwich the buyback, forcing the vault to buy the tax token at an inflated price up to the maxSlippageBps tolerance; the deposit leg with minAmountOut=0 gives zero on-chain protection on the LP mint. The extracted value reduces the LP minted and thus the dividend value distributed to all token holders.
- **Vulnerable Code:**
  - `src/MyxVault.sol: process()`
  - `src/MyxVault.sol: _buyTaxToken()`

> **Status:** `[ ]` TP　`[ ]` FP　`[ ]` By Design　`[x]` Acknowledged
> **Reason:** Known and accepted (spec-checker Rule 003). The tax token has no external oracle in the bonding phase, so the same-block quote × (1 − maxSlippageBps) is the only available bound; tightening it causes buyback reverts. The deposit `minAmountOut=0` is safe because the MYX LP mint is oracle-priced upstream (not an AMM spot — nothing to sandwich on the deposit leg). `process()` is permissionless by design; MEV exposure pre-exists the auto-trigger.

### Finding 5: Deferred LP can be disproportionately captured by the first/sole share holder via totalShares manipulation
- **Severity:** Low
- **Confidence:** Low
- **Detected by:** attacker_review
- **Description:** When MyxVault.process()/_feedDividend() runs while the Dividend contract has totalShares == 0, deposit() returns false and the freshly minted LP is retained in the vault and re-fed on the next permissionless call. Dividend.deposit increments magnifiedDividendPerShare by amount*MAGNITUDE/totalShares. An actor who becomes the first/only eligible shareholder when a large accumulated deferred LP balance is finally fed captures a disproportionate share of all previously-accumulated-but-deferred LP, because the per-share rate is computed against a tiny totalShares. Since process()/feedDividend() are permissionless and the trigger timing is observable, the actor can establish shares and then trigger the feed in a controlled sequence to sweep the accumulated LP at the inflated per-share rate.
- **Vulnerable Code:**
  - `src/MyxVault.sol: _feedDividend()`
  - `Dividend.sol: deposit()`
  - `Dividend.sol: setShare()`

> **Status:** `[ ]` TP　`[ ]` FP　`[ ]` By Design　`[x]` Acknowledged
> **Reason:** Theoretical but the window is self-limiting: deferral only occurs at `totalShares == 0`, yet accumulating a large deferred LP balance requires sustained tax = sustained trading = holders = `totalShares > 0`. The per-share math (`amount*MAGNITUDE/totalShares`) lives in Flap's Dividend contract, outside vault control. Confidence Low per the audit; extractable value is minimal.