# MyxVault v6 — Flap Vault Spec-Checker Findings

**Auditor:** Claude (Opus 4.8, 1M) via `flap-vault-spec-checker` skill
**Contracts:** `src/MyxVault.sol`, `src/MyxVaultFactory.sol`
**Spec rules:** Flap VaultPortal rules 001–009 (`.agents/skills/flap-vault-spec-checker/references/rules/`)
**Date:** 2026-06-14
**Scope:** Full fresh audit of the lean **v6** rewrite (uncommitted working tree). This document is
the first and only version for v6 — no historical (v1–v5) content is carried.

> NOTE: This report is AI-generated and should be reviewed by a human auditor.

---

## v6 design under audit

- `receive()` is accounting-only: `pendingBnb += msg.value; emit RevenueReceived(...)` (Rule 005).
- `process()` is **permissionless**: consumes all `pendingBnb`, buys back the tax token via the Flap
  Portal (BASE), deposits it into the myx base pool (LP = mBase minted to the vault), then feeds the
  whole LP balance into the token's native Flap Dividend contract (`dividendToken == mBase`).
- `_feedDividend` **defers** (keeps the LP, emits `DividendDeferred`) when the dividend contract is
  unwired (`address(0)`) or `deposit()` returns false (`totalShares == 0` early window) — Lista
  pattern, no swap, no price feeds, no fallback path.
- Holders claim mBase LP via `claimReward()` (proxy to `dividend.withdrawDividendsFor`) or directly
  on the Dividend contract, then earn myx rebates by holding the LP.
- Factory `computeDividendToken(predictedToken, hint)` (spec v2.3) delegates address math to the myx
  `PoolFactory.predictBasePoolToken` (verified byte-exact upstream; never recomputed locally).
- **No trigger / modes / operator** anymore. `process` is permissionless; fairness of the buyback is
  the same-block Portal `minOut` bound, and fairness of the REWARD is the Flap Dividend `setShare`
  transfer hooks (not gameable on-chain).

**Change vs. the prior (v4/v5) audit:** v4 integrated `IFlapTriggerService`/`ITriggerReceiver`
(Rule 008 was IN-SCOPE and PASS), and gated the buyback behind an `OPERATOR_ROLE`. v6 removed all of
it: no `trigger()` callback, no `Mode` enum, no `OPERATOR_ROLE`, no `setMode`. **Rule 008 is now N/A**
(see table). The buyback is now permissionless rather than operator-gated; this is accepted because
the tax token has no external price feed, and `minOut` derived from a same-block Portal quote bounds
per-call deviation (it cannot prevent a same-block sandwich — accepted, documented in-code).

---

## Per-rule results

| # | Rule | Verdict | Evidence |
|---|------|---------|----------|
| 001 | Vault inherits `VaultBaseV2`; `vaultUISchema()` + `description()` present | **PASS** | `MyxVault.sol:36` inherits `VaultBaseV2`; `vaultUISchema()` (`:309`) lists the 5 user-facing methods; `description()` (`:297`) returns a non-empty dynamic string. v6-accurate (LP-as-dividend, permissionless process/feed). |
| 001 | Guardian granted every privileged role | **PASS** | `initialize` grants the guardian `DEFAULT_ADMIN_ROLE` + `EMERGENCY_ROLE` (`:118-119`); creator also gets `EMERGENCY_ROLE` (`:120`). Guardian can call every gated function (`emergencyWithdraw`, `emergencySweepBnb`, `emergencyRescueToken`). |
| 001 | Guardian role irrevocable by others | **PASS** | `revokeRole` override (`:131-134`) is role-agnostic — reverts `CannotRevokeGuardianRole` for any `account == _getGuardian()`. Only the guardian may `renounceRole` itself. Tested (`test_revokeGuardianRole_reverts`, `test_revokeGuardianAdminRole_reverts`, `test_guardianCanRenounceItself`). |
| 001 | No DOS via dev parameter manipulation | **PASS** | All economic params (`maxSlippageBps`, `minProcessAmount`) are set once in `initialize` from the factory `config`; **no post-init setter exists**. Nothing the creator can flip to brick or degrade the vault. |
| 002 | Factory inherits `VaultFactoryBaseV2` | **PASS** | `MyxVaultFactory.sol:15` inherits `VaultFactoryBaseV2`. |
| 002 | Commission fee recommendation | **DEVIATION (intentional — auto-trigger fee)** | Tax is still 100% holder-bound EXCEPT the FlapTriggerService fee, which `scheduleProcess` debits from `pendingBnb` only on a successful schedule (`pendingBnb -= fee`). This is an operational cost paid to Flap's scheduler, not a vault self-skim, but it breaks the literal "100% of tax → LP". Deliberate trade-off for the receive-scheduled auto-process (see `auto-trigger-design.md`). |
| 003 | Fairness / sandwich-risk | **PASS (accepted bounded-sandwich)** | `process()` is permissionless (`:143`). Buyback `minOut` is a same-block Portal quote × `(1 − maxSlippageBps)` (`_buyTaxToken`, `:262-285`) — bounds per-call deviation, cannot stop a same-block sandwich (honestly documented in-code, `:135-141`). No mutable privileged knob exists to pre-condition a sandwich (slippage/min frozen at init). The REWARD's fairness is the Flap Dividend `setShare` transfer hooks, not gameable on-chain. Accepted (no external feed exists for the tax token). |
| 004 | Literal `require` strings (no custom errors) | **FAIL (Medium — documented, not fixed)** | The vault/factory use Solidity custom errors (`CannotRevokeGuardianRole`, `ZeroMarketQuoteToken`, `BelowMinimumProcessAmount`, `ZeroQuote`, `ZeroDividendContract`, `UnsupportedQuoteToken`, `OnlyGuardian`, `UpgradesLocked`). The Flap UI cannot decode custom-error selectors, so revert reasons will not surface as strings. **Medium per Rule 004**, carried disposition (out of the Critical/High fix scope). The two literal `require`s are `emergencySweepBnb` (`"BNB_SWEEP_FAILED"`) and the new `emergencyRescueToken` (`"Zero address"`). |
| 005 | `receive()` ≤ 1,000,000 gas, no external calls | **DEVIATION (intentional — auto-trigger schedule)** | `receive()` does the Rule-005 accounting core (`pendingBnb += msg.value; emit RevenueReceived(...)`) then `try this.scheduleProcess(msg.value) {} catch {}`, which makes an external call (`requestTrigger`) — a deliberate deviation. The never-revert guarantee is preserved: scheduling is fully wrapped in try/catch, so any failure (service down, fee, OOG) degrades to "not scheduled" without reverting `receive()` or losing tax (`test_receive_serviceReverts_doesNotRevertReceive`). See `auto-trigger-design.md`. |
| 006 | Integration tests cover critical flows | **PASS** | `test/MyxVault.t.sol` + `test/MyxVaultFactory.t.sol` cover: `receive()` gas + accounting; `process` happy/permissionless/below-min/zero-quote/swap-revert/deposit-revert/DEX-tax-balance-delta; pool auto-deploy/skip/missing-market; `_feedDividend` defer-on-no-contract / defer-on-zero-shares / flush-deferred+new / no-LP no-op / permissionless; `claimReward`/`pendingReward` proxy + unwired guards; guardian access + revoke guard; all emergency paths incl. the new `emergencyRescueToken`; `vaultUISchema`/`description`; factory portal-gate, BNB-only quote, `computeDividendToken`, `factorySpecVersion`, upgrade-only-guardian + lock; marketId↔myx equivalence (concrete + fuzz). **64 non-fork tests, all green.** |
| 007 | AI oracle (`IFlapAIProvider`) | **N/A** | No `IFlapAIProvider` / `FlapAIConsumerBase` import; no `fulfillReasoning` / `onFlapAIRequestRefunded` callback in either contract. |
| 008 | Trigger service (`IFlapTriggerService`) | **PASS (re-added)** | The vault implements `ITriggerReceiver`. `receive()` schedules `requestTrigger(now + 60s)`; the `trigger(uint256)` callback (a) **authenticates** `msg.sender == _getTriggerService()` (reverts `OnlyTriggerService`), (b) is **replay-safe** — clears `pendingTriggerId`/`hasPendingTrigger` before running and ignores stale/unknown ids, (c) runs `process()` under try/catch **within `getMaxCallbackGas()`** (measured 581k incl. first `deployPool`). Tests: `test/MyxVaultAutoTrigger.t.sol` (10), incl. `test_trigger_wrongSender_reverts`, `test_trigger_staleId_ignored`, `test_trigger_gasWithinCallbackLimit`. |
| 009 | Emergency controls (proxy-exempt branch) | **PASS** | Vault is a **BeaconProxy** (factory deploys `new BeaconProxy(beacon, ...)`, `MyxVaultFactory.sol:62-80`), so the Rule 009 mandatory `emergencyWithdrawNative`/`emergencyWithdrawToken` signatures are **exempt** — the upgrade path is the emergency mechanism. Upgrade authority is **Guardian-only**: the beacon is owned by the factory, `upgradeVaultImplementation` (`:147`) and `lockVaultUpgrades` (`:153`) are `onlyGuardian` (`_getGuardian()`), factory is non-upgradeable, no proxy admin / upgrader role / non-guardian owner remains. The vault additionally ships discretionary `EMERGENCY_ROLE` escapes (`emergencyWithdraw`, `emergencySweepBnb`, and the **newly added** `emergencyRescueToken`). |

**Summary:** 0 Critical, 0 High open. 1 High **fixed this audit** (deferred-LP rescue gap, H-01 below).
1 Medium documented-not-fixed (Rule 004 custom errors). Build green; 64 non-fork tests pass.

---

## Part 2 — holistic v6 review

### H-01 (High — FIXED this audit): deferred mBase LP had no generic rescue path

**Finding.** `_feedDividend` (`MyxVault.sol:180-198`) retains the **whole** LP balance in the vault
whenever the dividend is unwired or `deposit()` returns false (Lista deferral). The only escape
hatches were `emergencyWithdraw` — which can **only** move LP through `basePool.withdraw(poolId, ...)`
— and `emergencySweepBnb`, which handles native BNB only. There was **no generic ERC20 sweep**. So if
the myx pool's `withdraw` path were itself unusable (pool paused / wedged / migrated — exactly the
black-swan class emergency controls exist for), or if the dividend stayed permanently unwired, the
deferred LP would be **permanently stuck** with no recovery. The same gap stranded any residual tax
token left by a partially-filled buyback leg, or any token accidentally sent to the vault.

**State trace (the stuck scenario):**
`process()` mints LP to the vault → `_feedDividend` finds `dividendContract() == 0` (or `deposit()`
returns false forever) → LP retained, `DividendDeferred` emitted → if `basePool.withdraw` is also
unusable, no function can move that LP out → funds locked.

**Severity rationale.** The vault is BeaconProxy-upgradeable, so Rule 009's *signature* requirement is
formally exempt and an upgrade *could* in principle add a rescue. But relying on a code upgrade to
recover already-stuck user value is a poor escape hatch, and the task brief explicitly mandates
"deferred LP must be rescuable." Treated as **High** (fund-recovery gap on a value-holding path) and
fixed inline rather than deferred to an upgrade.

**Fix.** Added a guardian/creator-gated generic ERC20 rescue (`MyxVault.sol:249-256`), following the
Rule 009 `emergencyWithdrawToken` pattern verbatim — full-balance drain, `nonReentrant`,
`onlyRole(EMERGENCY_ROLE)`, zero-address guard, `safeTransfer`, `EmergencyTokenRescued` event
(`:69-72`):

```solidity
function emergencyRescueToken(address token, address to) external nonReentrant onlyRole(EMERGENCY_ROLE) {
    require(token != address(0) && to != address(0), "Zero address");
    uint256 bal = IERC20(token).balanceOf(address(this));
    if (bal > 0) {
        IERC20(token).safeTransfer(to, bal);
        emit EmergencyTokenRescued(token, to, bal);
    }
}
```

This recovers deferred mBase LP **without** depending on `basePool.withdraw`, plus any residual tax
token or stray ERC20. Guardian reachability (Rule 001) is preserved — guardian holds `EMERGENCY_ROLE`.

**Tests added** (`test/MyxVault.t.sol`, `MyxVaultEmergencyTest`): `test_emergencyRescueToken_rescuesDeferredLp`,
`test_emergencyRescueToken_rescuesResidualTaxToken`, `test_emergencyRescueToken_strangerReverts`,
`test_emergencyRescueToken_zeroAddressReverts`.

---

### Items reviewed — no change required

1. **`process()` permissionless — griefing/MEV.** Beyond the accepted bounded-sandwich (Rule 003),
   no new griefing vector. `minProcessAmount` (frozen at init) prevents dust-griefing of the buyback.
   `pendingBnb` accounting is sound: `receive()` only **adds**; `process()` reads `amount = pendingBnb`,
   **zeroes it before** the external buyback (`:144-146`), and on any revert in the buy/deposit legs
   the whole tx reverts and `pendingBnb` is restored (verified by `test_process_swapReverts_retainsBnb`,
   `test_process_failedDepositLeavesBnbPending`, `test_process_marketMissing_revertsAndRetainsBnb`).
   No stranded-BNB or double-spend: BNB that arrives between the read and a same-block second call is
   simply included next cycle. No accounting drift.

2. **`_feedDividend` deferral.** Reentrancy-safe: both entry points (`process`, `feedDividend`) are
   `nonReentrant` sharing one guard slot, so the dividend `deposit()` (which pulls LP via
   `transferFrom`, possibly triggering the mBase token's `setShare` hook) cannot reenter any mutating
   path. `forceApprove(div, bal)` residue is harmless — re-set via `forceApprove` on every retry. The
   permanent-stuck risk (LP never accepted) is now closed by **H-01's** `emergencyRescueToken`.

3. **`claimReward()` / `pendingReward()` proxy.** `dividendContract() == 0` handled: `claimReward`
   reverts `ZeroDividendContract` (`:210-211`), `pendingReward` returns 0 (`:219-221`). `claimReward`
   is `nonReentrant` around the external `withdrawDividendsFor`. Correct.

4. **`computeDividendToken` hint decode.** `abi.decode(hint, (address, string))` (`:106`) reverts
   cleanly on a malformed hint — acceptable for a `view` function called by VaultPortal off the hot
   path. marketId is derived from the **launch quoteToken** (`MyxMarketId.derive(chainId, quoteToken)`),
   then `predictBasePoolToken(marketId, predictedToken, symbol)` — distinct quoteToken → distinct
   market → distinct LP, asserted by `test_computeDividendToken_marketIdFromQuoteToken`.

5. **CREATE2 dependency.** No local address recomputation: the factory delegates **all** LP-address
   math to the authoritative myx `PoolFactory.predictBasePoolToken` (`:108`). No drift risk — the only
   on-chain derivation the vault does itself is `marketId`/`poolId` keccak hashing, which is
   fuzz-verified equivalent to upstream `MarketIdLib.toId`/`PoolKey` (`MyxMarketIdEquivalenceTest`).

6. **Storage / upgrade safety.** `__gap[44]` (`:92`) preserved; the fix added **no** storage
   variables (only an event + a function), so the layout is unchanged and BeaconProxy upgrade-safe.
   `initialize` is `initializer`-guarded; the implementation constructor calls `_disableInitializers()`
   (`:95`); re-init reverts (`test_initialize_revertsOnSecondCall`).

7. **Stale wording — FIXED.** Corrected the v4-era "(paid in this quote token) distribute to holders
   directly" text in the factory `vaultDataSchema` (`MyxVaultFactory.sol:127-145`) to v6 reality: the
   `quoteToken` field derives the myx market/pool only; the **dividend asset is the resulting myx LP
   (mBase)**, resolved via `computeDividendToken` and set from the `MAGIC_DIVIDEND_COMPUTED` sentinel
   at launch — it is NOT the quote token. Also corrected the matching stale NatSpec on the vault's
   `marketQuoteToken` state var (`MyxVault.sol:76-79`), which previously claimed
   `marketQuoteToken == dividendToken`. The vault `description()` and `vaultUISchema()` were already
   v6-accurate (LP-as-dividend, permissionless, no trigger/USDT-direct wording) — no change needed.

---

## Files changed this audit

| File | Change |
|------|--------|
| `src/MyxVault.sol` | Added `emergencyRescueToken(address,address)` + `EmergencyTokenRescued` event (H-01 fix); corrected stale `marketQuoteToken` NatSpec |
| `src/MyxVaultFactory.sol` | Rewrote `vaultDataSchema` description + field text to v6 reality (LP-as-dividend, not quote-token-direct) |
| `test/MyxVault.t.sol` | Added 4 `emergencyRescueToken` tests (deferred-LP rescue, residual-tax-token rescue, stranger-revert, zero-address-revert) |

## Verification

- `forge build` — **green** (warnings are pre-existing upstream lint notes only).
- `forge test --no-match-path "test/Integration.fork.t.sol"` — **64 passed, 0 failed, 0 skipped.**

## Disclaimer

This audit does not guarantee the absence of bugs. Contracts should undergo independent human review
and extensive testing before mainnet deployment.
