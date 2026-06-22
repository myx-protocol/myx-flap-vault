# Flap Vault Interaction Risk Report

Generated: 2026-06-22 03:06:22 UTC

## Vault Security Rating
**Low**

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
### Finding 1: scheduleProcess fee debit from pendingBnb breaks the (vault BNB balance == pendingBnb) invariant when permissionless process() runs concurrently, enabling a griefer to permanently strand the trigger fee
- **Severity:** Low
- **Confidence:** Low
- **Detected by:** attacker_review
- **Description:** scheduleProcess() pays the trigger fee from `pendingBnb` by debiting `pendingBnb -= fee` but does NOT reduce the vault's actual BNB balance correspondingly (the fee leaves via requestTrigger{value: fee}). Meanwhile, the permissionless process() reads `amount = pendingBnb` and then sets `pendingBnb = 0`, calling _buyTaxToken with `amount` which forwards that full amount as msg.value. Because process() forwards `amount` BNB (the value of pendingBnb at the time it reads it) while the actual vault balance has already been reduced by the trigger fee in a prior scheduleProcess, there can be a mismatch where process() attempts to forward more BNB via swapExactInput{value: amount} than the vault holds, causing process() to revert. An attacker can exploit the receive→scheduleProcess auto-flow to leave the vault in a state where the recorded pendingBnb exceeds the actual BNB balance, bricking the permissionless process() path.
- **Vulnerable Code:**
  - `src/MyxVault.sol:scheduleProcess`
  - `src/MyxVault.sol:process`
  - `src/MyxVault.sol:_buyTaxToken`

> **Status:** `[ ]` TP　`[x]` FP　`[ ]` By Design　`[ ]` Acknowledged
> **Reason (if FP / By Design / Acknowledged):** `requestTrigger{value: fee}` sends the fee OUT of the vault, reducing the actual BNB balance by exactly the same `fee` debited from `pendingBnb`. The (balance == pendingBnb) invariant therefore holds; `process()` forwards `amount == pendingBnb == balance` and can never run out of BNB, so it cannot be bricked. The premise "does NOT reduce the actual balance" is incorrect — the report itself notes the fee leaves via `requestTrigger{value: fee}`, which is exactly the balance reduction. Verified by `test_invariant_vaultBalanceEqualsPendingBnb`.

### Finding 2: Documentation claims both guardian AND creator can emergency-withdraw LP; only guardian is described in README architecture
- **Severity:** Low
- **Confidence:** Medium
- **Detected by:** doc_review
- **Description:** The tg-docs/doc.md states 'Emergency roles allow the guardian and creator to withdraw LP or sweep stuck tokens'. The README.md architecture diagram, however, attributes emergency paths only to the guardian: '[guardian] emergencyWithdraw / emergencySweepBnb / emergencyRescueToken'. The code grants EMERGENCY_ROLE to BOTH the guardian and the creator (in initialize: `_grantRole(EMERGENCY_ROLE, p.creator)`). The code matches tg-docs/doc.md but contradicts the README's guardian-only attribution.
- **Vulnerable Code:**
  - `src/MyxVault.sol#initialize`
  - `src/MyxVault.sol#emergencyWithdraw`
  - `src/MyxVault.sol#emergencySweepBnb`
  - `src/MyxVault.sol#emergencyRescueToken`

> **Status:** `[x]` TP　`[ ]` FP　`[ ]` By Design　`[ ]` Acknowledged
> **Reason (if FP / By Design / Acknowledged):** Fixed — README architecture diagram updated to `[guardian/creator]`, matching the code (`initialize` grants `EMERGENCY_ROLE` to both guardian and creator) and `tg-docs/doc.md`. Creator holding EMERGENCY_ROLE is by design.

