# Phase 0-v3 Findings — Flap V3 Tax Token Transfer-Tax Scope

> Date: 2026-06-12. On-chain verification for the v3 redesign (vault buys back the tax token
> via Portal and deposits it as MYX base liquidity). Sources: Sourcify exact-match verified
> `FlapTaxTokenV3` implementation `0x024f18294970B5c76c0691b87f138A0317156422` (all V3 tokens
> are EIP-1167 clones of it), plus live-token empirical sampling (Goat `0x5501ea8a…7777`).

## Verdicts

### 1. vault → MYX BasePool transferFrom: UNTAXED (full amount lands)

Tax is charged in `_transfer → _getTaxWithPoolState` ONLY when a counterparty is a
registered pool (`pools[from] || pools[to]`, or `mainPool` in `TaxEnforced` state). All other
transfers hit `return 0 → _plainTransfer`. The `pools` set is written exclusively inside the
one-shot `initialize()`; there is NO `addPool`/`setPool`/owner setter — the MYX pool can never
become a Flap-registered pool. Empirical: wallet-to-wallet transfers move full round amounts
(single Transfer event, no tax-skim sibling); 0/sampled non-pool transfers taxed.

**Consequence: the deposit leg needs no balance-delta accounting and creates no MYX pool
shortfall. The tax token behaves as a normal ERC20 for approve + transferFrom into MYX.**

### 2. Portal BUY (swapExactInput): full on bonding curve, NET on DEX phase

- Bonding curve: token `Transfer Portal→buyer` equals `TokenBought.amount` to the wei — full.
- DEX-listed (bought through the Flap-registered pool): the buy IS taxed; buyer receives net
  (verified: tax/gross exactly equals the configured bps, 114/114 sampled pool-buys skimmed).

**Consequence: the vault MUST account the buy leg via balance-delta
(`balanceOf(after) - balanceOf(before)`), which is correct in both phases.**

### 3. decimals == 18

Confirmed on the shared implementation and live tokens. Satisfies MYX `deployPool`'s
`decimals < 19` requirement.

### 4. No address-exemption mechanism

`excludedFromTax(address)` / `isExcludedFromFee(address)` do not exist (calls revert).
Exemption is structural (not being a registered pool) — nothing to configure; the vault and
the MYX pool are inherently exempt on plain transfers.

## Caveats (non-skimming)

1. `_afterTokenTransfer` calls `dividendContract.setShare(party, balanceOf(party))` for any
   non-skipped from/to (skips: token itself, zero, dead, dividend contract, registered pools).
   Depositing into the MYX pool triggers `setShare(myxPool)` — moves no tokens, but a
   misbehaving dividend contract would revert the transfer (failure path: deposit reverts,
   funds stay in the vault — safe). The MYX pool address will also passively accrue dividend
   share if its balance exceeds `minimumShareBalance` (harmless; the pool never claims).
2. `_liquidateTax(to)` runs only when `to == mainPool`; deposits into the MYX pool skip it
   entirely (no extra gas / side effects).

## Open item carried to fork testing

Whether `quoteExactInput` quotes gross or net in the DEX phase is not pinned down; the vault
passes `minOutputAmount` to the Portal (Portal-level check) and accounts via balance-delta,
with the operator-permissioned trigger bounding any quote-basis mismatch. Verify quote-vs-swap
basis consistency against the real Portal in the fork e2e test.
