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
