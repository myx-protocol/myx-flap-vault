# Flap Vault Spec-Checker Compliance Audit

**Skill:** `flap-vault-spec-checker` (bundled, `.agents/skills/flap-vault-spec-checker/`)
**Repository:** `myx-flap-vault` — branch `feat/myx-vault`
**Audit targets:** `src/MyxVault.sol`, `src/MyxVaultFactory.sol`
**Base contracts:** `src/flap/VaultBaseV2.sol`, `src/flap/VaultFactoryBaseV2.sol` (verified against `references/prelude/` — interface-identical; the local `VaultBaseV2` adds only a benign `onlyGuardian()` helper modifier, which does not alter the required `vaultUISchema()` abstract surface)
**Test result:** `forge test` → **50 passed, 0 failed, 0 skipped** (49 unit/factory + 1 BSC-fork end-to-end)

> NOTE: This report is generated with AI assistance and should be reviewed by a human auditor before deployment/verification on flap.sh.

## Architecture summary (drives Rule 009 disposition)

- `MyxVault` is **upgradeable** — deployed as an OpenZeppelin `BeaconProxy` by the factory (`MyxVaultFactory.sol:82`), `Initializable` with `__gap` storage reserve. It therefore qualifies for the **Rule 009 upgradeable/proxy exception**.
- `MyxVaultFactory` is **non-upgradeable** itself; only the vault implementation (behind the beacon) is upgradeable, and that authority is **Guardian-only** (`onlyGuardian` on `upgradeVaultImplementation` / `lockVaultUpgrades`).
- `MyxVault` uses OpenZeppelin `AccessControlUpgradeable`; `MyxVaultFactory` uses a custom `onlyGuardian` modifier (so the OZ-specific `revokeRole()` override is required for the vault but **N/A** for the factory).

## Verdict table (Rules 001–009)

| Rule | Verdict | Evidence (file:line) | Action |
|------|---------|----------------------|--------|
| 001 — Vault inherits `VaultBaseV2`; `vaultUISchema()` + `description()` present | **PASS** | `MyxVault.sol:27` (inherit), `:293` (`vaultUISchema`), `:281` (`description`) | None |
| 001 — Guardian granted all privileged roles | **PASS** | `MyxVault.sol:115-118` (`_grantRole(DEFAULT_ADMIN_ROLE / EMERGENCY_ROLE, guardian)`) | None |
| 001 — Guardian role irrevocable by others (OZ AccessControl → `revokeRole` override) | **PASS** | `MyxVault.sol:128-131` (`revert CannotRevokeGuardianRole()` when `account == _getGuardian()`) | None |
| 001 — No DOS via dev parameter manipulation | **PASS** | All economic params (`maxSlippageBps`, `minProcessAmount`, feeds, `maxPriceStaleness`) set once in `initialize` (`:111-113`); no post-init setters exist | None |
| 002 — Factory inherits `VaultFactoryBaseV2` | **PASS** | `MyxVaultFactory.sol:15` | None |
| 002 — `newVault()` only callable by VaultPortal; `vaultData` decoded per schema | **PASS** | `:74` (`msg.sender != _getVaultPortal()` revert), `:77` (`abi.decode(vaultData,(address,MarketId))` matches `vaultDataSchema` `:134-137`) | None |
| 002 — `isQuoteTokenSupported()` implemented | **PASS** | `:111-113` (returns `quoteToken == address(0)`, native BNB only) | None |
| 002 — Factory non-upgradeable; beacon-upgrade authority Guardian-only | **PASS** | `beacon` immutable `:40`; `upgradeVaultImplementation`/`lockVaultUpgrades` are `onlyGuardian` `:141,:147,:63-66` | None |
| 002 — Commission fee follows recommendation **or** justification recorded | **PASS (no-commission, justified)** | No commission taken; full BNB → MYX liquidity via `processRevenue` `:135-150`, rebates → holders via `harvest` `:197-225` | See "Accepted deviations §1" |
| 003 — Fairness / sandwich-risk | **PASS** | `processRevenue`/`harvest` permissionless; swap `minOut` feed-derived internally, never caller input (`:163-166`, `:206-212`); no mutable privileged knob to pre-condition a sandwich | None |
| 004 — Reverts use literal `require` strings (no custom errors) | **FAIL (Medium)** | 12 custom errors declared (`MyxVault.sol:52-57`, `MyxVaultFactory.sol:29-34`); only one literal-string `require` (`MyxVault.sol:254`) | Documented, **not fixed** (Medium per task scope) — see "Accepted deviations §2" |
| 004 — Multi-language strings inline | **N/A** | Contract does not advertise multi-language support; UI-02 only applies when multiple languages are present | None |
| 005 — `receive()` ≤ 1,000,000 gas (accounting only) | **PASS** | `MyxVault.sol:122-125` — body is `pendingBnb += msg.value; emit RevenueReceived(...)`. No loop/external call/delegatecall; worst case ≈ 25k gas. Verified by `test_receive_gasUnder1M` and live on fork (`test_endToEnd_launchTradeDispatchProcess`, `Integration.fork.t.sol:123-126`) | None |
| 006 — Integration tests cover critical flows | **PASS** | `Integration.fork.t.sol` (real BSC fork: launch→trade→dispatch→`receive()`→`processRevenue()`→LP mint) + 49 unit/factory tests (receive-gas, write happy/revert, views, `description`, `vaultUISchema`, guardian access, role-revocation guard) | None |
| 007 — AI oracle (`IFlapAIProvider`) safety | **N/A** | Vault does not import or integrate `IFlapAIProvider` / `FlapAIConsumerBase`; no `fulfillReasoning`/`onFlapAIRequestRefunded` callbacks exist | None |
| 008 — Trigger service (`IFlapTriggerService`) safety | **N/A** | Vault does not import or integrate `IFlapTriggerService` / `ITriggerReceiver`; no `trigger(uint256)` callback exists | None |
| 009 — Emergency risk controls | **PASS (upgradeable exception)** | Vault is `BeaconProxy`-upgradeable (`MyxVaultFactory.sol:82`) → Rule 009 emergency-function signatures are waived; sole check is Guardian-only upgrade authority, satisfied by `onlyGuardian` beacon upgrade (`:141,:147`). Vault additionally provides `emergencyWithdraw`/`emergencySweepBnb` (both `nonReentrant`, `EMERGENCY_ROLE`) as a bonus (`MyxVault.sol:240-256`) | See "Accepted deviations §3" |

### Severity roll-up

| Severity | Count | Items |
|----------|-------|-------|
| Critical | 0 | — |
| High     | 0 | — |
| Medium   | 1 | Rule 004 custom errors (documented, not fixed per task scope) |
| Low/Info | 2 | Unused `MarketNotInitialized` error; partial `vaultUISchema` method coverage (privileged/power-user methods omitted) |

**No Critical or High findings were identified. No source code changes were required.**

## Fixed issues

None. There were no Critical or High severity FAILs, so no source modifications were made and the 50-test suite remains untouched and green.

## Accepted deviations

### §1 — No commission (Rule 002 commission recommendation)

The factory intentionally takes **zero commission** from tax revenue. `MyxVaultFactory` sets no `commissionReceiver` and implements no fee skim in `MyxVault.receive()` (which is accounting-only). The recommended fee formula in Rule 002 is an upper-bound guidance ("if you don't follow the recommendation, justify it"); taking **less** than recommended (here, nothing) is strictly more user-favorable and requires no Flap-side concession.

**Rationale:** the entire tax inflow is recycled for the token's own holders — BNB is converted to MYX base-pool liquidity held by the vault (`processRevenue`), and the LP rebates harvested from that position are forwarded to the token's native Dividend contract (`harvest`). There is no developer revenue extraction path, which is the strongest possible posture under Rule 003 (Fairness). This is a deliberate product decision, not an oversight.

### §2 — Custom errors instead of literal `require` strings (Rule 004 / UI-01, Medium)

Both contracts use Solidity custom errors (e.g. `BelowMinimumProcessAmount`, `StalePrice`, `UnsupportedBaseToken`) rather than `require(cond, "literal")`. Rule 004 UI-01 classifies this as a **Medium** finding because the Flap UI renderer cannot decode custom-error selectors without ABI parsing, so revert reasons will not surface as human-readable strings in the generic vault UI.

**Disposition:** documented only, **not fixed**, per the audit task's directive (only Critical/High are remediated in-source; Medium/Low are recorded). Custom errors are gas-cheaper and carry structured args useful for off-chain tooling and the existing Foundry test suite (`vm.expectRevert(MyxVault.X.selector)`). If first-class UI error display is later required, the remediation is mechanical: replace each `revert CustomError(...)` with `require(cond, "literal message")`. This does not affect funds safety, access control, or the `receive()` gas budget.

### §3 — Emergency-function shape differs from Rule 009 non-upgradeable template (PASS via exception)

Because `MyxVault` is deployed behind a `BeaconProxy`, Rule 009's mandatory non-upgradeable emergency functions (`emergencyWithdrawNative(address)`, `emergencyWithdrawToken(address,address)`, `autoForward*`) are **not required** — the Guardian-controlled beacon upgrade path is the sanctioned emergency mechanism, and that authority is Guardian-only (satisfied).

The vault nonetheless ships two *additional* recovery functions for operational convenience:
- `emergencyWithdraw(uint256 lpAmount, uint256 minAmountOut, address to)` — redeems vault-held LP back to quote token (`MyxVault.sol:240-247`), `nonReentrant`.
- `emergencySweepBnb(address to)` — sweeps stuck native BNB (`:250-256`), `nonReentrant`.

These intentionally diverge from the Rule 009 reference signatures (they carry an `lpAmount`/`minAmountOut`, since LP redemption is not a "drain full native balance" operation, and `emergencySweepBnb` does drain the full balance). They are gated by `EMERGENCY_ROLE`, which is granted to **both the Guardian and the creator** at init (`:117-118`). Guardian retention is therefore preserved (Rule 001 ✓); the creator's inclusion is an accepted design choice for a proxy-exempt vault, and any creator misuse on the LP-redeem path is bounded by `minAmountOut` slippage protection and does not touch user wallets (only vault-held assets). This is recorded as an accepted deviation, not a violation.

### §4 — Informational

- `MyxVault.sol:55` declares `error MarketNotInitialized()` which is unused (the live pool-readiness check uses `_ensurePoolExists()` + `ZeroDividendContract`). Dead declaration — Info-level; safe to remove in a future cleanup.
- `vaultUISchema()` lists 5 methods (`userLpShare`, `pendingBnb`, `processRevenue`, `harvest`, `pendingReward`). The privileged disaster-recovery functions (`emergencyWithdraw`, `emergencySweepBnb`) and the power-user `pendingVaultRebates(uint256 price)` view are intentionally omitted from the schema, as they are not normal end-user actions. Acceptable; Info-level.

## `forge test` summary

```
Ran 10 test suites: 50 tests passed, 0 failed, 0 skipped (50 total)
- Integration.fork.t.sol  → 1 passed  (BSC mainnet fork: launch→trade→dispatch→receive()→processRevenue)
- MyxVault.t.sol          → 37 passed (core, guardian, views, emergency, swap/oracle paths)
- MyxVaultFactory.t.sol   → 12 passed (newVault guards, quote-token support, beacon upgrade, lock)
```

No source was modified during this audit; the suite is unchanged and fully green.

## v3 Rework Delta Audit (2026-06-12)

**Scope of delta:** commits `c5a8b63` (operator-gated Portal buyback), `446aadb` (factory whitelist removal; `vaultData = (MarketId)` only), `1dc21b2` (fork e2e reworked to real Portal buyback). Re-audited `src/MyxVault.sol` + `src/MyxVaultFactory.sol` against rules 001-009 with focus on what v3 changed; rules unaffected by the delta (007/008) were re-confirmed N/A by import inspection.

**Test result:** `forge test --no-match-path test/Integration.fork.t.sol` → **49 passed, 0 failed** (48 pre-existing + 1 added by this audit; fork e2e not run locally, last reworked in `1dc21b2`).

### Per-rule delta verdicts

| Rule | Delta verdict | Evidence (file:line) |
|------|---------------|----------------------|
| 001 — Inheritance / `vaultUISchema()` / `description()` | **PASS** | `MyxVault.sol:31` inherits `VaultBaseV2`; `description()` (`:289-299`) rewritten for v3 — accurately states Portal buyback, vault-held LP, "processRevenue() is operator-only; harvest() is permissionless" |
| 001 — Guardian granted every privileged role incl. new `OPERATOR_ROLE` | **PASS** | `initialize` grants guardian `DEFAULT_ADMIN_ROLE` + `EMERGENCY_ROLE` + `OPERATOR_ROLE` (`MyxVault.sol:115-120`); creator gets `EMERGENCY_ROLE` + `OPERATOR_ROLE` |
| 001 — Guardian role irrevocable, incl. `OPERATOR_ROLE` | **PASS** | `revokeRole` override (`:129-132`) is **role-agnostic** — reverts for any `account == _getGuardian()` regardless of role, so `OPERATOR_ROLE` is covered; test added this audit (`test_revokeGuardianOperatorRole_reverts`). Only the guardian itself may `renounceRole` |
| 001 — No DOS via dev parameter manipulation | **PASS** | Still no post-init setters; all economic params fixed in `initialize` from immutable-in-practice factory `config` (set once in factory constructor, no setter) |
| 002 — Factory structural compliance after whitelist removal | **PASS** | `vaultDataSchema()` (`MyxVaultFactory.sol:108-113`) declares a single `bytes32 marketId` field matching `abi.decode(vaultData, (MarketId))` (`:60`; `MarketId` is a UDVT over `bytes32`); `newVault` portal-gated (`:57`); `isQuoteTokenSupported` native-only (`:91-93`); factory non-upgradeable, beacon upgrade `onlyGuardian` + lockable (`:115-124`). Zero-commission posture unchanged (v1 §1 still applies) |
| 003 — Fairness / sandwich-risk under operator gating | **PASS (with Medium operational advisory M-02)** | `processRevenue` is `OPERATOR_ROLE`-gated (`MyxVault.sol:139`) — exactly the pattern VaultBase prescribes for "buyback which may be sandwich attacked": permissioned callers + guardian as irrevocable backup. No mutable privileged knob exists to pre-condition a sandwich (slippage/feeds/min-amount frozen at init). Residual mempool exposure documented as M-02 below |
| 004 — Literal `require` strings | **FAIL (Medium, unchanged)** | v3 kept custom errors and added `ZeroQuote` (`:60`); disposition unchanged from v1 §2 (documented, not fixed — Medium per task scope). v1 Info item `MarketNotInitialized` dead declaration **fixed this audit** (removed) |
| 004 — `vaultUISchema` accuracy for v3 | **PASS** | Schema description (`:303-305`) matches v3 mechanics; `processRevenue` method description ends "Operator only." (`:320-323`) with `isWriteMethod = true`; `harvest` marked "Anyone can call." — both correct |
| 005 — `receive()` ≤ 1M gas | **PASS (no regression)** | `receive()` byte-identical in behavior to v1 (`:123-127`): `pendingBnb += msg.value` + event, no external calls/loops; `test_receive_gasUnder1M` asserts < 100k gross |
| 006 — Integration test coverage of v3 flows | **PASS** | Operator gate happy/stranger/guardian paths, balance-delta under DEX-phase tax, zero-quote revert, swap/deposit failure → BNB retained, pool auto-deploy/skip/missing-market all covered (`MyxVault.t.sol:147-288`); fork e2e reworked to real Portal buyback (`1dc21b2`). Gap found and fixed: guardian revoke-guard was only tested for `EMERGENCY_ROLE` — added `test_revokeGuardianOperatorRole_reverts` |
| 007 / 008 — AI oracle / trigger service | **N/A (unchanged)** | No `IFlapAIProvider` / `IFlapTriggerService` imports or callbacks in either contract |
| 009 — Emergency controls | **PASS (upgradeable exception, unchanged)** | Vault still `BeaconProxy`-deployed (`MyxVaultFactory.sol:63-87`); upgrade authority guardian-only + lockable; bonus `emergencyWithdraw`/`emergencySweepBnb` unchanged (`MyxVault.sol:249-265`, both `nonReentrant` + `EMERGENCY_ROLE`) |

### Focused v3 code review (Part 2)

#### M-02 (Medium, operational — accepted with advisory): same-block Portal quote cannot bound a pre-pump; operator txs should avoid the public mempool

`_buyTaxToken` (`MyxVault.sol:161-184`) derives `minOut` from `quoteExactInput` **in the same transaction** as the swap. A front-runner (or a creator-operator self-sandwiching) who pumps the tax-token price in an earlier tx of the same block moves the quote and `minOut` together, so `maxSlippageBps` only bounds quote→execution deviation *within* the call, not deviation from the pre-attack fair price. The contract comments state this honestly ("minOut … cannot prevent sandwiches on its own — the caller gate is the real protection"), and the `OPERATOR_ROLE` gate does eliminate permissionless adversarial triggering — but it does not protect an operator tx transiting the public BSC mempool.

**Disposition: accepted, no code change.** (a) No price feed exists for the tax token, so an in-contract fair-price bound is impossible — this is precisely the case VaultBase's guidance designates for permissioned buyback + guardian backup; (b) loss per call is bounded by attacker capital vs. curve/DEX depth and by `pendingBnb` batch size; (c) the creator-operator self-sandwich variant is dominated by powers the creator already holds and v1 already accepted (`EMERGENCY_ROLE` LP redemption to an arbitrary address, v1 §3). **Operational mitigations (recommended, off-chain):** submit `processRevenue` via a private relay (e.g. bloXroute/48Club on BSC), and/or process frequently to keep per-call `pendingBnb` small.

#### R-01 (resolved — no issue): reentrancy via tax-token `_afterTokenTransfer → dividendContract.setShare` during the buy

During `portal.swapExactInput`, the tax token's transfer hook calls `dividendContract.setShare(vault, …)` (docs/phase0-v3-findings.md caveat 1), handing execution to the dividend contract mid-`processRevenue`. Verified containment: `processRevenue`, `harvest`, `emergencyWithdraw`, `emergencySweepBnb` all share one `ReentrancyGuardUpgradeable` slot, so reentry into any of them reverts; `processRevenue` is additionally role-gated (the dividend contract holds no role); `receive()` is reachable but accounting-only, and `pendingBnb` is zeroed before any external call (CEI, `:140-142`), so a mid-swap `receive()` would merely register new revenue. A reverting `setShare` makes the whole buy revert and BNB stays pending — safe failure path (covered by `test_processRevenue_swapReverts_retainsBnb`). No finding.

#### R-02 (resolved — no issue, one Info note): tax-token custody between buy and deposit

The buy leg is accounted via balance delta (`:173-183`, correct in both bonding-curve and net-of-tax DEX phases per docs/phase0-v3-findings.md §2), and the deposit leg is untaxed (§1: the MYX pool can never become a Flap-registered pool), so `forceApprove(basePool, received)` + `deposit(poolId, received, …)` moves exactly `received` and leaves allowance at 0 — no residual balance from the processing path. **Info:** tokens *donated* directly to the vault land below `balanceBefore` and are never swept (no `emergencyWithdrawToken`); recoverable only via beacon upgrade — acceptable under the Rule 009 proxy exception, recorded here.

#### N-01 (Info — intended design, noted): operator-grant authority sits with the guardian, not the creator

`OPERATOR_ROLE` is granted at init to guardian + creator; its role admin is `DEFAULT_ADMIN_ROLE`, held **only by the guardian**. The creator can call `processRevenue` but cannot delegate it (e.g. to a keeper bot) without a guardian grant. This matches the design intent ("creator + Guardian + grantable" — the grant authority is the guardian as DEFAULT_ADMIN) and is the safer default: a compromised creator key cannot mint new operators. Recorded as intended; if creator-managed delegation is wanted later, the guardian grants `DEFAULT_ADMIN_ROLE` is **not** required — a per-address `OPERATOR_ROLE` grant suffices.

#### N-02 (clean): factory dead-code sweep after whitelist removal

No leftover whitelist state, imports, errors, or script parameters: `src/`, `script/mainnet/`, `script/testnet/` contain no `whitelist`/`allowedBase`/`UnsupportedBaseToken` references; every remaining factory import, error, and `GlobalConfig` field is used. The only dead declaration found repo-wide was the vault's `MarketNotInitialized` error (pre-existing v1 Info) — removed this audit.

### Changes made by this audit

| Change | File | Rationale |
|--------|------|-----------|
| Removed dead `error MarketNotInitialized();` | `src/MyxVault.sol` | v1 Info item §4; confirmed still unused after v3 rework |
| Added `test_revokeGuardianOperatorRole_reverts` | `test/MyxVault.t.sol` | Delta mandate: guardian's `OPERATOR_ROLE` must be irrevocable; guard code was role-agnostic but only `EMERGENCY_ROLE` was tested |

### Delta severity roll-up

| Severity | Count | Items |
|----------|-------|-------|
| Critical | 0 | — |
| High     | 0 | — |
| Medium   | 2 | Rule 004 custom errors (carried, unchanged); M-02 mempool sandwich advisory (accepted, operational mitigation) |
| Low/Info | 3 | R-02 donated-token note; N-01 operator-grant authority note; v1 schema-coverage note (carried) |

**No Critical or High findings. v3 rework is spec-compliant; suite green at 49/49 non-fork tests.**
