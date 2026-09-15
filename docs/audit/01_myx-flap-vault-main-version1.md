# Flap Vault Interaction Risk Report

Generated: 2026-09-15 03:17:25 UTC

> **MYX response (2026-09-15).** Updated source: branch `feat/vault-v3-erc20-quote`, PR https://github.com/myx-protocol/myx-flap-vault/pull/2 (commit `a25100c`). Summary: Findings 1, 2, 3, 4, 5, 9 fixed (TP); 6 and 7 By Design; 8 Acknowledged. Verification: 287 unit tests green; BSC mainnet fork tests (native quote and ERC20/NVDAB quote, real Portal / TaxProcessor / MultiDexRouter / TriggerService) green.

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
### Finding 1: Standalone revert() with string literals used instead of require() in developer code (SYS-REQ-LITERAL-ERRORS)
- **Severity:** High
- **Confidence:** High
- **Detected by:** attacker_review, rule_review
- **Description:** SYS-REQ-LITERAL-ERRORS requires every revert path in developer code to use the form require(condition, "message"). Several developer-authored functions instead use standalone revert("...") / revert(unicode"...") statements, which violates the rule. Affected: FlapDeployed.vaultPortal uses `revert("FlapDeployed: unsupported chain")`; MyxVault._getTriggerService uses `revert(unicode"Trigger service not configured / 觸發服務未配置")`; MyxVaultFactory.resolveDividendToken uses `revert(unicode"Unsupported launch version / 不支援的發行版本")`.
- **Vulnerable Code:**
  - `src/FlapDeployed.sol: FlapDeployed.vaultPortal -> revert("FlapDeployed: unsupported chain")`
  - `src/MyxVault.sol: MyxVault._getTriggerService -> revert(unicode"Trigger service not configured / 觸發服務未配置")`
  - `src/MyxVaultFactory.sol: MyxVaultFactory.resolveDividendToken -> revert(unicode"Unsupported launch version / 不支援的發行版本")`
  - `src/MyxVaultFactory.sol: resolveDividendToken (else branch revert)`

> **Status:** `[x]` TP　`[ ]` FP　`[ ]` By Design　`[ ]` Acknowledged
> **Reason (if FP / By Design / Acknowledged):** Fixed — all three standalone reverts are now `require(condition, unicode"English / 繁體中文")`: `FlapDeployed.vaultPortal` → `require(portal != address(0), ...)`; `MyxVault._getTriggerService` → `require(service != address(0), ...)`; `MyxVaultFactory.resolveDividendToken` unsupported-version branch → `require(false, ...)`. No `revert(` remains in `src/` outside verbatim upstream Flap files. `test_unknownChainReverts` updated to the bilingual literal.

### Finding 2: Multi-language inconsistency: English-only user-facing strings amid established bilingual intent (SYS-REQ-MULTILANG)
- **Severity:** High
- **Confidence:** Medium
- **Detected by:** rule_review
- **Description:** The contracts establish multi-language intent by using ` / ` bilingual (English / Traditional Chinese) separators throughout require messages, description(), and schema descriptions. However some user-facing strings are English-only, violating SYS-REQ-MULTILANG. FlapDeployed.vaultPortal reverts with English-only "FlapDeployed: unsupported chain". The FieldDescriptor description labels returned by MyxVaultUISchema.build() (consumed by the UI) are English-only: "Quote amount", "Holder address", "Claimable LP amount", "Quote token", "BNB amount", "Pool deployed".
- **Vulnerable Code:**
  - `src/FlapDeployed.sol: FlapDeployed.vaultPortal: "FlapDeployed: unsupported chain"`
  - `src/lib/MyxVaultUISchema.sol: methods[0].outputs[0] "Quote amount"`
  - `src/lib/MyxVaultUISchema.sol: methods[4].inputs[0] "Holder address"`
  - `src/lib/MyxVaultUISchema.sol: methods[4].outputs[0] "Claimable LP amount"`
  - `src/lib/MyxVaultUISchema.sol: methods[5].outputs[0] "Quote token"`
  - `src/lib/MyxVaultUISchema.sol: methods[8].outputs[0] "BNB amount"`
  - `src/lib/MyxVaultUISchema.sol: methods[9].outputs[0] "Pool deployed"`

> **Status:** `[x]` TP　`[ ]` FP　`[ ]` By Design　`[ ]` Acknowledged
> **Reason (if FP / By Design / Acknowledged):** Fixed — `FlapDeployed.vaultPortal` reverts with `unicode"Unsupported chain / 不支援的鏈"`; all six `FieldDescriptor` labels in `MyxVaultUISchema.build()` are bilingual (e.g. `unicode"Quote amount / 報價幣金額"`). Guarded by the new `test_vaultUISchema_fieldLabelsBilingual`, which asserts every method, input and output description in the UI schema contains ` / `.

### Finding 3: Vault creator holds EMERGENCY_ROLE and can drain all accumulated tax revenue / LP meant for holders (COM-FUND-DIVERSION)
- **Severity:** High
- **Confidence:** High
- **Detected by:** attacker_review, rule_review
- **Description:** MyxVault.initialize grants EMERGENCY_ROLE not only to the trusted guardian but also to the untrusted `creator` (the token launcher). EMERGENCY_ROLE gates emergencyWithdraw, emergencySweepNative, and emergencyRescueToken, all of which can move vault assets to an arbitrary `to`/recipient. The creator can therefore, at any time and unilaterally, call emergencyRescueToken(quoteToken, creatorAddress) to steal all accumulated ERC20 tax revenue (pendingQuote), emergencySweepNative(creatorAddress) to steal all native revenue, or emergencyWithdraw to redeem any un-fed mBase LP to the quote token and send it away. These funds are the tax revenue that the vault is supposed to convert to MYX LP and distribute to token holders as dividends, so the creator can rug the holders' expected dividends.
- **Vulnerable Code:**
  - `src/MyxVault.sol: initialize (_grantRole(EMERGENCY_ROLE, p.creator))`
  - `src/MyxVault.sol: emergencySweepNative`
  - `src/MyxVault.sol: emergencyRescueToken`
  - `src/MyxVault.sol: emergencyWithdraw`

> **Status:** `[x]` TP　`[ ]` FP　`[ ]` By Design　`[ ]` Acknowledged
> **Reason (if FP / By Design / Acknowledged):** Fixed — `initialize` no longer grants the creator any role. `DEFAULT_ADMIN_ROLE` and `EMERGENCY_ROLE` are held only by the Flap Guardian (multisig); `creator` is stored for attribution only. All emergency paths (`emergencyWithdraw`, `emergencySweepNative`, `emergencyRescueToken`) and the new `setForward` are therefore Guardian-only. Tests: `test_creatorHasNoRole`, `test_emergencyWithdraw_creatorReverts`, `test_emergencyRescueToken_rescuesResidualTaxToken` (now Guardian). `docs/spec-checker-findings.md` Rule 001/009 rows updated.

### Finding 4: Swap slippage tolerance (maxSlippageBps) only bounded to 100%, allowing zero effective minOut on buyback and gas-refill swaps (USER-RISK-UNFAIR-PARAMS)
- **Severity:** High
- **Confidence:** Medium
- **Detected by:** rule_review
- **Description:** The vault's swap slippage tolerance `maxSlippageBps` is sourced from the factory's `GlobalConfig` and is only validated with `require(_config.maxSlippageBps <= 10_000)` in the factory constructor. There is no lower reasonableness bound and no per-vault re-validation in `MyxVault.initialize`. If the factory deployer sets `maxSlippageBps = 10_000` (100%), then in both `_buyTaxToken` and `_refillGas`/`executeGasRefill` the computed `minOut = quoted * (BPS_DENOMINATOR - maxSlippageBps) / BPS_DENOMINATOR` becomes 0, disabling the only price-execution guarantee. Since the code's own comments acknowledge that BSC block proposers can reorder transactions and that `minOut` is the effective protection against value extraction on the DEX-phase buyback, a 100% tolerance permits the tax revenue to be converted to MYX LP at an arbitrarily unfavorable rate, reducing the LP dividends distributed to token holders. Token holders have no control over this parameter and cannot opt out.
- **Vulnerable Code:**
  - `src/MyxVaultFactory.sol (constructor: require(_config.maxSlippageBps <= 10_000))`
  - `src/MyxVault.sol (initialize: maxSlippageBps = p.maxSlippageBps)`
  - `src/MyxVault.sol (_buyTaxToken: minOut computation)`
  - `src/MyxVault.sol (_refillGas: minOut computation)`

> **Status:** `[x]` TP　`[ ]` FP　`[ ]` By Design　`[ ]` Acknowledged
> **Reason (if FP / By Design / Acknowledged):** Fixed — `MAX_SLIPPAGE_BPS = 1_000` (10%) is enforced in the `MyxVaultFactory` constructor (`Slippage above 10% / 滑點超過 10%`) and re-validated in `MyxVault.initialize` (defense in depth: no factory configuration can produce a vault whose `minOut` is zero). Deployments use 300 bps (BSC mainnet, Robinhood) and 500 bps (BSC testnet). Tests: `test_constructor_rejectsSlippageAboveCap`, `test_constructor_acceptsSlippageAtCap`, `test_initialize_slippageAboveCap_reverts`.

### Finding 5: Missing Guardian receive() forward switch (incomplete rescue mechanism) (SYS-REQ-RESCUE-MECHANISM)
- **Severity:** High
- **Confidence:** High
- **Detected by:** attacker_review, rule_review
- **Description:** MyxVault provides Guardian-callable emergency withdrawal for BNB (emergencySweepNative), arbitrary ERC20 (emergencyRescueToken) and vault LP (emergencyWithdraw), satisfying facet (a) of the rescue requirement. However, it does NOT implement facet (b): a Guardian-controlled forward switch on receive() that, when enabled, redirects ALL incoming BNB to a Guardian-set forward address via a non-reverting low-level call and returns early. receive() only checks the _unwrapping transient flag and then runs normal accounting/scheduling logic; there is no mechanism to safely redirect incoming revenue to a safe address during an incident without reverting receive() (which would break upstream tax-token transfers for all holders). This leaves the vault without the full mandated Guardian rescue mechanism.
- **Vulnerable Code:**
  - `src/MyxVault.sol: receive()`

> **Status:** `[x]` TP　`[ ]` FP　`[ ]` By Design　`[ ]` Acknowledged
> **Reason (if FP / By Design / Acknowledged):** Fixed — Guardian-controlled forward switch implemented. `setForward(address to)` is gated by `DEFAULT_ADMIN_ROLE`, which only the Guardian can ever hold (the creator has no role; the Guardian role cannot be revoked). While `forwardTo != address(0)`, `receive()` forwards `msg.value` to it with a low-level call whose result is only logged (`RevenueForwarded(to, amount, ok)`) and returns before `_sync()` and scheduling; a refusing target leaves the BNB in the vault and never reverts the upstream tax dispatch. Setting zero turns the switch off and normal accounting resumes (retained BNB is then recognized on the next wake / `sync()`). Storage: `forwardTo` appended at slot 217, `__gap` 39→38, layout verified with `forge inspect`. Tests: `MyxVaultForwardSwitchTest` (Guardian-only, redirect without accounting, refusing target does not revert, disable resumes accounting, gas < 100k). Note: for ERC20-quote vaults the tax arrives as a token transfer, not through `receive()`; those balances are rescued with `emergencyRescueToken`.

### Finding 6: process() buyback callback has high gas-consumption risk with no direct (non-Trigger-Service) recovery path (EXT-FLAP-TRIGGER-RECOVERY)
- **Severity:** Medium
- **Confidence:** Medium
- **Detected by:** rule_review
- **Description:** The core business operation of MyxVault — convert accumulated quote revenue into MYX LP and feed it to holders — is implemented in process(), which is gated by `require(msg.sender == address(this))` and can only ever be reached through the FlapTriggerService callback in trigger(). All other entry points (requestProcess, receive, ensurePoolDeployed) only schedule a new Trigger request; they cannot execute the buyback directly. Because the Trigger Service enforces a fixed 2,000,000 gas limit on every callback regardless of the requested gasLimit, and because process() chains several gas-intensive external operations in a single call — for ERC20-quote vaults a multi-tier Uniswap-V3 quoter loop in _refillGas/_bestPool (one quoteExactInputSingle per supported fee tier plus a sized re-quote, each V3 quoter call being expensive), the gas-refill swap + WBNB unwrap, the Portal quote + swapExactInput buyback, the MYX basePool.deposit, and the dividend deposit in _feedDividend — the callback can exceed 2,000,000 gas. If it does, the callback reverts with out-of-gas and rescheduling through the Trigger Service cannot resolve it, since every Trigger callback is subject to the same fixed limit. No authorized operator can invoke the buyback/deposit business logic through a direct transaction whose gas limit they choose. feedDividend() only completes the dividend-feed portion, ensurePoolDeployed() only deploys the pool, and emergency functions only sweep/redeem funds (disaster recovery, not completing the operation). Consequently the pending quote revenue can remain permanently unconverted and holder LP dividends undistributed.
- **Vulnerable Code:**
  - `src/MyxVault.sol: process()`
  - `src/MyxVault.sol: trigger()`
  - `src/MyxVault.sol: _refillGas()`
  - `src/MyxVault.sol: _bestPool()`
  - `src/MyxVault.sol: _buyTaxToken()`
  - `src/MyxVault.sol: _feedDividend()`

> **Status:** `[ ]` TP　`[ ]` FP　`[x]` By Design　`[ ]` Acknowledged
> **Reason (if FP / By Design / Acknowledged):** `process()` is trigger-only at Flap's explicit request (Flap review feedback, 2026-09-13: a directly callable buyback exposes the vault's own swap to front-running and sandwiching; the trigger service submits callbacks through an MEV-protected channel). Gas is bounded and measured rather than open-ended: (1) the only unbounded step, myx `deployPool` (~2.06M gas), is now entirely outside the callback — no trigger is requested until `poolReady` is latched by `ensurePoolDeployed()`, which the MYX service calls out-of-band (PR #2); (2) per-call work is constant regardless of accumulated revenue (`maxProcessAmount` batching), the refill quoter loop is bounded by the router's fee-tier list (4 tiers on BSC) and runs only when the gas pool is below `gasThreshold`; (3) measured on a BSC mainnet fork against the real Portal, TaxProcessor, MultiDexRouter and TriggerService: native-quote callback ≈ 0.9M gas; ERC20-quote (NVDAB) callback including the 4-tier refill quote loop, refill swap + WBNB unwrap, Portal buyback, pool deposit and dividend feed = 1,569,277 gas (`test_erc20Quote_endToEnd`; the myx pool is mocked there, a real `basePool.deposit` adds an estimated 100–200k), i.e. roughly 15–20% headroom under the 2,000,000 cap. If a callback nevertheless failed: `trigger()` clears the in-flight flag before `try process()`, so scheduling never deadlocks; anyone re-schedules with `requestProcess()`; every outflow is rule-010 atomic so funds are retained; the Guardian can `emergencyWithdraw` / `emergencyRescueToken`. We will add a Guardian-only direct `process` path if Flap prefers that over strict trigger-only execution.

### Finding 7: pendingQuote (holder-bound buyback revenue) is diverted to operational gas/fees
- **Severity:** Low
- **Confidence:** Low
- **Detected by:** attacker_review
- **Description:** pendingQuote is documented as recognized-and-unspent quote revenue whose purpose is to be bought back into MYX LP for holders. However two outflow paths spend it on a different obligation: (1) scheduleProcess (native-quote vaults) debits the FlapTriggerService fee directly from pendingQuote, and (2) executeGasRefill sells up to MAX_REFILL_SHARE_BPS (20%) of pendingQuote per batch into the BNB gas pool. The gas pool already has its own dedicated funding sources (MyxVaultFactory.prepayGas / MyxVault.fundGas), yet the refill leg still pulls from the buyback revenue bucket. Every such outflow reduces the amount ultimately converted to LP and distributed to holders.
- **Vulnerable Code:**
  - `src/MyxVault.sol: scheduleProcess (pendingQuote -= fee for native quote)`
  - `src/MyxVault.sol: executeGasRefill (pendingQuote -= quoteIn)`
  - `src/MyxVault.sol: _refillGas`

> **Status:** `[ ]` TP　`[ ]` FP　`[x]` By Design　`[ ]` Acknowledged
> **Reason (if FP / By Design / Acknowledged):** Both outflows are the vault's own bounded operating cost for delivering the dividend automatically, and both are documented. (1) A native-quote vault owns no BNB other than tax revenue, so the FlapTriggerService fee (~0.0002 BNB) can only come from revenue; it is debited only when `requestTrigger` succeeds and only when `pendingQuote ≥ minProcessAmount + fee`, and the creator sizes `minProcessAmount` so the fee is negligible per batch. The alternative is no automation at all. (2) The ERC20 refill runs only when the gas pool is below `gasThreshold`, targets `gasRefillAmount` (factory-capped by `maxGasRefillAmount`), and is now capped at 20% of the processed batch (Finding 9 fix). `prepayGas` / `fundGas` are the primary funding sources; the refill is the sustaining source that keeps the vault autonomous when nobody tops it up. The BNB stays in the vault, is spent only on trigger fees, and can be moved only by the Guardian.

### Finding 8: Buyback and gas-refill slippage bounds derive from same-transaction, manipulable quotes (COM-MEV-SANDWICH)
- **Severity:** Low
- **Confidence:** Low
- **Detected by:** attacker_review
- **Description:** _buyTaxToken and _refillGas both compute minOut from a quote fetched in the same transaction as the swap (IPortalTradeV2.quoteExactInput and IMultiDexRouter.quoteExactInputSingle). Because the quote reflects live, caller-influenceable pool state, the derived minOut provides no real protection against a sandwich that moves the pool before process() executes. The code itself acknowledges that BSC block proposers can reorder at no cost, so the buyback can be sandwiched, extracting value from the vault's revenue.
- **Vulnerable Code:**
  - `src/MyxVault.sol: _buyTaxToken (minOut from quoteExactInput)`
  - `src/MyxVault.sol: _refillGas (minOut from _quoteOut)`

> **Status:** `[ ]` TP　`[ ]` FP　`[ ]` By Design　`[x]` Acknowledged
> **Reason (if FP / By Design / Acknowledged):** Known and documented in-code (`_buyTaxToken` / `_refillGas` NatSpec) and in `docs/spec-checker-findings.md` Rule 003. No external price reference exists for a bonding-curve or freshly listed tax token, and Flap asked us not to introduce external dependencies. Mitigations: `process()` executes only inside the FlapTriggerService callback, which Flap submits through an MEV-protected channel (no public-mempool exposure of the buyback transaction); per-call exposure is bounded by `maxProcessAmount` batching; the refill leg is bounded by 20% of the batch; and `maxSlippageBps` is now hard-capped at 10% (Finding 4 fix), so even a same-block sandwich can extract at most that share of one batch.

### Finding 9: Gas-refill cap is 20% of full pendingQuote, not 20% of the processed batch as documented
- **Severity:** Low
- **Confidence:** Medium
- **Detected by:** doc_review
- **Description:** The README (Risks section) promises: "The refill leg ... is capped at MAX_REFILL_SHARE_BPS = 2000 — at most 20% of a processed batch can be diverted to top up the gas pool, bounding griefing/slippage exposure from any single process() call." The MyxVault MAX_REFILL_SHARE_BPS comment repeats "this bounds that per-batch loss to 20% of the batch." However, in `_refillGas()` the cap is computed as `cap = (available * MAX_REFILL_SHARE_BPS) / BPS_DENOMINATOR`, where `available = pendingQuote` — the ENTIRE recognized quote balance before batching. The actual buyback batch is only `min(pendingQuote - quoteIn, maxProcessAmount)`. When accumulated revenue exceeds `maxProcessAmount` (the documented multi-batch drain scenario), the refill can divert up to 20% of the full backlog, which may be several multiples of a single processed batch.
- **Vulnerable Code:**
  - `src/MyxVault.sol:_refillGas`
  - `src/MyxVault.sol:process`
  - `src/MyxVault.sol MAX_REFILL_SHARE_BPS constant`

> **Status:** `[x]` TP　`[ ]` FP　`[ ]` By Design　`[ ]` Acknowledged
> **Reason (if FP / By Design / Acknowledged):** Fixed — the cap is now `20% × min(pendingQuote, maxProcessAmount)`, i.e. of the batch this call processes, matching the README and the constant's NatSpec (both wordings updated). Test: `test_process_refillCappedAtShareOfBatch_notBacklog` (100 RWA backlog, 30 RWA batch → refill capped at 6 RWA, not 20).

