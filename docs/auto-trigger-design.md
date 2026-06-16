# Auto-Trigger Design — receive-scheduled `process()` via FlapTriggerService

Date: 2026-06-16
Status: approved, implementing

## Goal

When the vault receives tax, automatically run `process()` ~60 seconds later through
Flap's on-chain `FlapTriggerService`, without operating a self-hosted keeper.

## Background & constraints

- EVM contracts cannot self-schedule; any "X seconds later" needs an external transaction.
  `FlapTriggerService` is Flap's backend-driven scheduler: `requestTrigger{value: fee}(executeAfter)`
  registers a job, the backend calls back `requester.trigger(requestId)` after `executeAfter`
  (bounded gas, NOT guaranteed punctual).
- A TRIGGERED mode existed in v4 (task #23) and was removed in v6 (#32) for leanness.
- **Flap Rule 005**: `receive()` must be accounting-only — no external calls, never reverts,
  ≤ 1M gas. This is why tax dispatch (`TaxProcessor` fan-out) can rely on every vault's `receive()`.

## Key decision: schedule in `receive()`, do NOT run `process()` inline

Running `process()` inside `receive()` was rejected: `process()` is heavy (Portal buyback +
first-call `deployPool` + add-liquidity + dividend feed), far above Rule 005's 1M gas, and the
gas forwarded to `receive()` by the dispatch fan-out is limited. An out-of-gas inside `receive()`
**cannot be cleanly caught** (63/64 forwarding rule) — the `catch` arm would lack the gas to even
emit, so `receive()` itself OOG-reverts → that tax fan-out fails → **lost / stuck tax**. Trading a
60-second saving for a small chance of losing funds is a bad deal in a money contract.

Decision: `receive()` only schedules a (lightweight) trigger; `process()` runs in the separate,
gas-funded trigger callback 60s later, and remains permissionless as a fallback.

## Data flow

```
Flap dispatch ──BNB──▶ receive()
                         ├─ pendingBnb += msg.value ; emit RevenueReceived   (Rule-005 accounting)
                         └─ if no in-flight trigger & pendingBnb >= min:
                              try this.scheduleProcess(msg.value)             (self-call, try/catch)
                                 └─ requestTrigger{value: fee}(now + DELAY)

Flap trigger backend ──(>= now+DELAY)──▶ trigger(requestId)                  (ITriggerReceiver)
                         ├─ require msg.sender == triggerService
                         ├─ if requestId != pendingTriggerId: return         (stale/unknown ignored)
                         ├─ pendingTriggerId = 0                              (clear BEFORE, CEI)
                         └─ try this.process() catch {}                      (failure must not deadlock)
```

## Components & state

| Item | Notes |
|------|-------|
| `triggerService` (immutable) | deploy param (BSC mainnet `0xcf4EE25035CF883895110f367F5BA8172416a7F9`; **testnet addr TBD**), not hardcoded |
| `pendingTriggerId` (uint256) | `0` = no in-flight; non-zero = scheduled. Idempotence gate: non-zero ⇒ skip new schedule |
| `PROCESS_DELAY` (immutable) | default 60s, deploy-configurable |
| `scheduleProcess(uint256 budget) external` | `onlySelf` (msg.sender == address(this)); wraps `getFee()` + `requestTrigger` so the whole leg is inside the `receive()` try/catch |
| `trigger(uint256) external` | implements `ITriggerReceiver`; sender check; stale-id ignore; clear id, then `try this.process()` |

Events: `ProcessScheduled(requestId, executeAfter)`, `ProcessTriggered(requestId, bool success)`.

## Safety invariants

1. **`receive()` never reverts** — scheduling goes through `try this.scheduleProcess()`; any
   `getFee`/`requestTrigger` revert is caught: no fee charged, no id set, tax never lost.
2. **Fee accounting self-consistent** — `pendingBnb += msg.value` first; `pendingBnb -= fee` ONLY
   on successful schedule, so `vault BNB balance == pendingBnb` always holds and `process()` can
   never be balance-starved.
3. **Small-tax guard** — `msg.value <= fee` or `pendingBnb < minProcessAmount` ⇒ no schedule
   (avoids underflow / dust scheduling); permissionless `process()` remains the fallback.
4. **No deadlock on FAILED** — `trigger()` clears `pendingTriggerId` before `try process()`, so
   whether `process()` succeeds or reverts, the next tax receipt can re-schedule.

## spec-checker deviations (intentional)

- **Rule 005 FAIL** — `receive()` now makes an external call (`scheduleProcess` → `requestTrigger`).
- **Rule 002 FAIL** — the trigger fee is paid out of tax revenue (operational cost, not self-skim,
  but it breaks the literal "100% of tax → LP").

These are deliberate, accepted trade-offs for auto-triggering; `spec-checker-findings.md` will be
updated to mark them as intentional. Implies the vault is self-deployed / not pursuing Flap's
official spec-checker certification.

## Open items

- Testnet `FlapTriggerService` address (deploy parameter).
- gas: the trigger callback (including first-call `deployPool`) must be ≤ `getMaxCallbackGas()`.
  Asserted in tests; if the live limit is exceeded, revisit (e.g. pre-deploy the pool out-of-band).

## Test matrix (TDD)

Schedule: above-threshold + no pending ⇒ `requestTrigger` called, id stored, fee deducted /
has-pending ⇒ skip / below-threshold ⇒ no schedule / `msg.value <= fee` ⇒ no schedule, no tax loss /
service reverts ⇒ `receive()` does not revert, full tax retained.
Callback: correct sender + id ⇒ process runs + id cleared / process reverts ⇒ id still cleared /
wrong sender ⇒ revert / stale id ⇒ ignored / gas ≤ `getMaxCallbackGas()`.
New mock: `MockFlapTriggerService`.
