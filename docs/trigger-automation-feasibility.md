# Trigger-Service Automation Feasibility Assessment

> Date: 2026-06-13
> Scope: Can the Flap `IFlapTriggerService` (BSC mainnet `0xcf4EE25035CF883895110f367F5BA8172416a7F9`)
> drive `MyxVault` so that (a) `processRevenue` (add-liquidity) runs automatically via trigger
> callbacks, and (b) `harvest` reward settlement fires on a timer via trigger?
> Read-only feasibility study. No source/test changes were made.

---

## 1. Verdict

| Goal | Verdict | One-line reason |
|---|---|---|
| **(a) Auto add-liquidity** (`processRevenue` via trigger) | **FEASIBLE-WITH-CAVEATS** | The buyback+deposit path fits the 2M callback budget comfortably **only after the pool exists**. The **first** `processRevenue` per token also runs the real myx `deployPool` (deploys 4 BeaconProxies + 4 `initialize()` calls) inside the same call — that branch is at material risk of blowing the 2M cap and is unmeasured (myx not on BSC yet). Bootstrap the pool out-of-band; trigger only the steady-state path. |
| **(b) Timed harvest** (`harvest` via trigger) | **FEASIBLE-WITH-CAVEATS** | `harvest` is a single claim + one Pancake hop + Dividend deposit, well under 2M gas. The caveat is semantic, not gas: the service only guarantees execution **after** `executeAfter`, never *at* it — "timed harvest" must be read as "no-sooner-than", and the vault must self-reschedule (chained re-`requestTrigger`) since there is no native recurrence. |

Net recommendation (see §7): **add a third `TRIGGERED` mode rather than replacing `AUTO`**, gate `requestTrigger` behind the operator, never bootstrap the pool inside a callback, and re-validate market conditions at callback time.

---

## 2. Live TriggerService numbers (BSC mainnet, queried 2026-06-13)

RPC `https://bsc-dataseed.binance.org`, target `0xcf4EE25035CF883895110f367F5BA8172416a7F9`:

| Call | Raw output | Meaning |
|---|---|---|
| `getFee()(uint256)` | `200000000000000` (`2e14`) | **0.0002 BNB per request** sent as `msg.value` to `requestTrigger`. |
| `getMaxCallbackGas()(uint256)` | `2000000` (`2e6`) | **Hard 2,000,000-gas ceiling** on our `trigger()` callback. THE decisive number. |
| `getRequestCount()(uint256)` | `3029` | Service is **live and actively used** (3,029 requests created). |

`getRoleMember(...)` / `getRoleMemberCount(...)` **revert** → the contract is not `AccessControlEnumerable`, so role membership is not publicly enumerable. Role membership could not be read on-chain, and the verified source could not be fetched without an Etherscan V2 API key. The interface (`src/flap/IFlapTriggerService.sol`) is nonetheless authoritative on the trust model:

- `error OnlyTriggerRole();` + NatSpec "`trigger(requestId)` ... called by backend with TRIGGER_ROLE" → **`trigger()` is role-gated; only the Flap backend can drive normal execution.** Execution timing is backend-dependent.
- `retryTrigger(uint256)` NatSpec: "Retry a previously failed trigger request (**callable by anyone**)." → **no role gate on retry; any address (incl. MEV bots) can re-run a `FAILED` callback.** Per rule 008, retry runs with **no gas cap**.
- `struct TriggerRequest { ... uint128 feePaid; }` + `FlapTriggerRequested(..., gasFeesPaid)` → fee is recorded per request. The interface does not expose a refund path; on `FAILED` the fee is effectively **sunk** (consumed regardless of callback success). This was not contradicted by any readable source, so treat fee as **non-refundable on failure**.

---

## 3. Gas budget analysis — the decisive comparison

### 3.1 Measured: steady-state `processRevenue` (fork test, real Portal)

`test/Integration.fork.t.sol` runs `processRevenue()` against the **real** Flap Portal on a BSC fork. Trace (`forge test -vvvv --isolate`) at the top-level `MyxVault::processRevenue()` frame:

```
[680427] MyxVault::processRevenue()
  ├─ [294317] Portal::swapExactInput{value}(...)     // real bonding-curve buyback
  ├─ [106935] MockPoolManager::deployPool(...)       // MOCK — not real myx
  └─ [116507] MockBasePool::deposit(...)             // MOCK — not real myx
```

**Total `processRevenue` = 680,427 gas** in this configuration. But the myx side (`PoolManager`, `BasePool`) is **mocked**: the mock `deployPool` is 107K and the mock `deposit` is 117K. These are floor numbers, not the production cost. myx is **not deployed on BSC**, so the real path cannot be fork-measured today.

| Component | Source | Gas | Trustworthy? |
|---|---|---|---|
| Portal buyback (`quoteExactInput` + `swapExactInput{value}`) | real Portal on fork | ~294K | **Yes** — real |
| `deployPool` | mock | 107K | **No** — see §3.2 |
| `BasePool.deposit` | mock | 117K | **No** — see §3.3 |
| Vault overhead (nonReentrant, approve, accounting, event) | real | ~70K | Yes |

### 3.2 Estimated: real myx `deployPool` (the budget-killer)

Real `PoolManager.deployPool` (`/Users/simple/Documents/project/myx/myx-contract-v2/src/pool/PoolManager.sol:152`) → `PoolFactory.deployPoolComponents` (`.../src/pool/PoolFactory.sol:47`) deploys **four `BeaconProxy` contracts**, each immediately `initialize()`-d:

1. `_deployPoolVault` → `new BeaconProxy` + `IPoolVault.initialize`
2. `_deployTradingVault` → `new BeaconProxy` + `ITradingVault.initialize`
3. `_deployBasePoolToken` → `new BeaconProxy` + `IPoolToken.initialize`
4. `_deployQuotePoolToken` → `new BeaconProxy` + `IPoolToken.initialize`

then `_poolData.createPool(...)` writes the full `PoolMetadata` struct (8 fields → multiple cold `SSTORE`s) and `emitPoolDeployed` fires an event through a separate Emiter contract.

First-principles bound: a single `BeaconProxy` deployment is ~150K–250K gas (CREATE + ~50-byte runtime + reading the beacon + a `delegatecall` into `initialize`); each `initialize()` for a pool token / vault writes several cold storage slots (name/symbol/poolId/underlying/addressManager → ~5–10 cold `SSTORE` at 22.1K each after the warm/cold accounting). **Four proxy deploys + four initializers + the `createPool` struct write + cross-contract reads (AddressManager dependency lookups) plausibly land in the 1.2M–2.5M+ gas range.**

**Conclusion: the `deployPool` branch is at serious risk of exceeding — or sitting dangerously close to — the 2,000,000-gas callback cap.** Combined with the ~294K Portal buyback and ~200K+ real deposit that run in the *same* `processRevenue` call, the **first** `processRevenue` per token (which is exactly the one that triggers auto-deploy — `_ensurePoolExists`) is the single most likely call to OOG inside a trigger callback. This is unmeasurable today (no myx-on-BSC), so it must be treated as **High risk**, not assumed-fine.

### 3.3 Estimated: real `BasePool.deposit`

Real `deposit` (`.../src/pool/BasePool.sol:156`) does: `getPool` read, `_validateDeposit`, conditional oracle read (`safeOraclePrice` — external) + `_updatePool`/`_updateUserData`, `safeTransferFrom`, `reserveInfo()` external read, reserve/exchange-rate math, `forceApprove`, `depositBaseToken` (external, writes), `mint` (external), and `emitPoolDeposited` (external). Bounded external calls, no unbounded loops → realistic **200K–400K gas**. **Fits the budget on its own** with wide margin.

### 3.4 `harvest` gas

`harvest()` = `claimUserRebate` (1 external claim) + USDT balance read + 2 Chainlink `latestRoundData` reads + one `swapExactTokensForTokens` (single `[USDT,WBNB]` hop, BSC's deepest pair) + `forceApprove` + `_forwardToDividend` (1 `dividendContract()` read + `forceApprove` + `deposit`). No deploys, no loops. Realistic **250K–450K gas**. **Comfortably within 2M.**

### 3.5 Decisive verdict

| Operation | Real gas (est.) | vs 2M cap | Fits? |
|---|---|---|---|
| `processRevenue` — **pool already exists** (buyback + deposit) | ~294K + ~300K + ~70K ≈ **~700K** | 35% of cap | **YES, comfortable** |
| `processRevenue` — **first call, includes `deployPool`** | ~700K + **1.2M–2.5M+** ≈ **~1.9M–3.2M** | 95%–160% of cap | **NO / borderline — High risk** |
| `harvest` | **~250K–450K** | 12%–22% of cap | **YES, comfortable** |

---

## 4. Rule 008 compliance — MUST list vs current code

Rule `008-trigger-service-integration.md` (High; unauthorized callback = Critical). Current `MyxVault` has **no** trigger integration at all, so every requirement below is net-new.

| # | Rule 008 MUST | Current `MyxVault` | Gap to add |
|---|---|---|---|
| 1 | `trigger(uint256)` **MUST** verify `msg.sender == triggerService` | absent | Add `trigger(uint256)` entrypoint with `require(msg.sender == address(triggerService))`; store the service address at init. **Critical if omitted.** |
| 2 | Bind each `requestId` → intended action; reject unknown/consumed/canceled; delete on consume (replay protection) | absent | Add `mapping(uint256 => Action) triggerData`; populate on `requestTrigger`, `delete` in `trigger()`. **High if omitted.** |
| 3 | Delay-aware: do not assume callback at `executeAfter`; re-validate market-sensitive constraints at callback time; fail safe if stale | partial — `_buyTaxToken` already recomputes `minOut` from a *same-block* `quoteExactInput` at execution time (good), and `harvest` reads Chainlink fresh at execution (good) | The minOut is recomputed at callback time, so the slippage bound stays current. But AUTO-mode sandwich exposure (already documented) persists — a triggered buyback is still a public, sandwichable tx. **Medium.** |
| 4 | Callback **MUST** complete < 2,000,000 gas on **all** paths | n/a | The `deployPool` branch (§3.2) violates this on first-call. **MUST** exclude `_ensurePoolExists`/`deployPool` from the callback path (bootstrap pool out-of-band). **High.** |
| 5 | Reentrancy protection on callbacks doing external calls; bounded/deterministic | `processRevenue` and `harvest` are already `nonReentrant`; bodies are loop-free and bounded | The `trigger()` wrapper must also be `nonReentrant` and dispatch into the existing guarded logic. Mostly satisfied. **Low.** |

Rule 005 (`receive()` ≤ 1M gas, **no external calls**): `requestTrigger{value:fee}` is an external call with value → **MUST NOT** live in `receive()`. Current `receive()` is accounting-only (`pendingBnb += msg.value`) and compliant; any scheduling call must stay out of it (see §5).

**Already satisfied:** nonReentrant bodies, fresh execution-time price basis, accounting-only `receive()`.
**Net-new required:** `trigger(uint256)` entrypoint + sender check (1), request→action binding + replay delete (2), gas-bounded callback that excludes `deployPool` (4), scheduling/re-scheduling logic that lives outside `receive()` (§5).

---

## 5. Architecture sketch — a `TRIGGERED` mode

### 5.1 Where `requestTrigger` is called (NOT in `receive()`)

Rule 005 forbids the value-bearing external `requestTrigger` in `receive()`. Three viable kick-off points:

1. **Operator kick-off (recommended seed):** operator calls a new `scheduleProcess()` / `scheduleHarvest()` that does `triggerService.requestTrigger{value: fee}(executeAfter)` and records `triggerData[requestId]`. One-time bootstrap.
2. **Chained self-rescheduling (recurrence):** at the **end** of the `trigger()` callback, the vault calls `requestTrigger` again for the next interval (`executeAfter = block.timestamp + period`). This is the only way to get "timed" recurrence — the service has no native cron. ⚠ The re-`requestTrigger` is another external value call inside the callback; it adds to the 2M budget and **must not** be reached if the main work already neared the cap (guard with a gas check or schedule from a fixed-cost tail).
3. **Piggyback on `processRevenue`:** an operator-run `processRevenue` could enqueue the next trigger. Couples two concerns; not recommended.

For harvest-on-timer: **operator seeds once (option 1), callback re-schedules (option 2).** For auto-add-liquidity: seed per token **after** the pool exists; do **not** self-reschedule blindly (only re-arm when `pendingBnb >= minProcessAmount`, else you sink the fee on a no-op revert).

### 5.2 Who pays `getFee()` — quantify the drain

The fee (`2e14` = 0.0002 BNB) must be sent as `msg.value` by whoever calls `requestTrigger`. Options:

- **From the vault's own BNB (`pendingBnb`):** each scheduled request consumes 0.0002 BNB of revenue. At the test's dispatched amount (~0.071 BNB per `processRevenue`), one fee is **~0.28%** of the processed BNB — non-trivial but tolerable for add-liquidity. For harvest the fee is pure overhead (harvest processes USDT rebate, not BNB) and would have to be funded separately or from `pendingBnb`. **Funding fees from `pendingBnb` corrupts the revenue accounting** (`pendingBnb` is the swap input) unless explicitly subtracted — a dedicated `feeReserve` balance is cleaner.
- **From the operator's wallet:** operator pre-funds the vault or pays per `scheduleX()` call. Keeps revenue accounting clean; shifts cost off-chain to the operator. **Recommended.**

Fee-drain failure mode: if callbacks repeatedly `FAILED` (slippage, pool inactive, OOG on the deploy branch), each scheduling attempt still sinks 0.0002 BNB with no work done. Over N failed re-schedules that is `N * 2e14` BNB bled. Bound N (max retries / circuit-breaker) before self-rescheduling.

### 5.3 Callback dispatch

```
trigger(uint256 requestId):
    require(msg.sender == address(triggerService))          // Rule 008 #1
    Action a = triggerData[requestId]; require(a != NONE)   // Rule 008 #2
    delete triggerData[requestId]                            // replay delete
    // nonReentrant wrapper
    if a == PROCESS:
        require(_poolExists())                              // Rule 008 #4: never deploy here
        require(pendingBnb >= minProcessAmount)             // fail-safe, avoid fee-sink revert
        _processRevenueLogic()                              // buyback + deposit only (~700K)
    if a == HARVEST:
        _harvestLogic()                                     // ~300K
    // optional: re-arm next interval from a fixed-cost tail (option 2)
```

The `deployPool` step stays in an operator-only `bootstrapPool()` (or the existing first manual `processRevenue`), **outside** any callback.

---

## 6. Failure modes

| Mode | Mechanism | Impact | Mitigation |
|---|---|---|---|
| **Callback reverts** (slippage, pool not Cooked/active, OOG on deploy branch) | Portal minOut breach, `_validateDeposit` reject, or >2M gas | Request → `FAILED`; fee sunk; work not done | Exclude `deployPool` from callback (§5.3); re-validate conditions and fail safe; keep `pendingBnb` intact so funds aren't lost (current code already zeroes `pendingBnb` only after a successful swap — revert restores it) |
| **`retryTrigger` by anyone** (MEV) | After `FAILED`, any address re-runs the callback with **no gas cap** | The retried `processRevenue` is a public sandwichable buyback an MEV bot can frontrun/backrun; bot picks the block | This is the same AUTO-mode sandwich surface, now *attacker-scheduled*. For sandwich-sensitive tokens, **do not** put the buyback under triggers — keep it MANUAL + private relay. Harvest is feed-bounded, lower risk |
| **Backend liveness dependency** | `trigger()` only fires when the Flap backend (TRIGGER_ROLE) calls it; timing "after `executeAfter`, not guaranteed" | "Timed harvest" can be arbitrarily late; revenue sits idle | Treat as best-effort, no-sooner-than schedule. Keep `processRevenue`/`harvest` permissionlessly callable (current AUTO) as a fallback so a keeper or anyone can run them if the backend stalls — do **not** make triggers the sole path |
| **Fee drain on repeated failure** | Each (re)schedule sinks 0.0002 BNB regardless of outcome | Slow BNB bleed | Cap retries; circuit-breaker that stops self-rescheduling after K failures; fund fees from operator, not `pendingBnb` |
| **Timing non-determinism vs "timed" expectation** | Service guarantees only `>= executeAfter` | UX mismatch if "every 24h harvest" is promised | Document as "harvest no sooner than T"; self-reschedule from the *callback*, not wall-clock, so drift doesn't compound into gaps |
| **Replay** | Same `requestId` callback delivered twice | Double-execution | `delete triggerData[requestId]` before doing work (Rule 008 #2) |

---

## 7. Recommendation

**Add a third `TRIGGERED` mode; do not replace `AUTO`. Reject trigger-driving the pool-bootstrap path.**

Concrete:

1. **Keep `AUTO` and `MANUAL`.** Triggers depend on an off-chain backend (TRIGGER_ROLE) with no timing guarantee; removing the permissionless `AUTO` path would make the vault's revenue processing wholly dependent on Flap backend liveness — a regression in availability and a new single point of failure. The existing permissionless `processRevenue`/`harvest` must remain as the always-available fallback.

2. **Add `Mode.TRIGGERED` as a peer of AUTO/MANUAL** (extend the enum; `setMode` stays creator/Guardian-only). In TRIGGERED mode, `processRevenue`/`harvest` logic is reachable both by the trigger callback **and** still permissionlessly (so a stalled backend never locks funds). Add a `trigger(uint256)` entrypoint implementing Rule 008 (#1 sender check, #2 replay delete, #4 gas-bounded, nonReentrant).

3. **Never `deployPool` inside a callback.** Gate auto-deploy behind an operator-only `bootstrapPool()` (or require the operator to run the first `processRevenue` manually). The callback path `require(_poolExists())` and fails safe otherwise. This sidesteps the only branch that plausibly busts the 2M cap (§3.2) — and that branch is *unmeasurable* until myx ships on BSC, so it cannot be trusted to fit.

4. **Timed harvest = FEASIBLE.** Harvest fits the gas budget with wide margin and is feed-bounded (low MEV). Implement as: operator seeds one `requestTrigger`, callback re-arms the next interval from a fixed-cost tail with a retry/circuit-breaker cap. Sell it as "no-sooner-than" cadence, not exact.

5. **Auto add-liquidity via trigger = FEASIBLE only for the steady-state (pool-exists) path,** and only if you accept that a `retryTrigger`-able buyback is attacker-schedulable MEV bait. For sandwich-sensitive tokens, leave the buyback in MANUAL + private relay; triggers are appropriate for harvest and for low-MEV tokens' steady-state add-liquidity.

6. **Fund trigger fees from the operator (or a dedicated `feeReserve`), not `pendingBnb`,** to keep revenue accounting uncorrupted; cap retries to bound fee bleed.

**Before any of this is built, measure the real myx `deployPool` and `deposit` gas on a BSC fork once myx is deployed there** — the entire §3.2 risk hinges on an estimate, and it is the load-bearing unknown for goal (a).
