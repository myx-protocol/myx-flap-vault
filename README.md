# myx-flap-vault

MYX integration vault for the [Flap](https://docs.flap.sh) launchpad.

Supported chains: BNB Chain (56), BNB Testnet (97) and Robinhood Chain (4663). Per-chain Flap
addresses (Portal, Guardian, VaultPortal, TriggerService) are hardcoded and resolved by chain id;
an unsupported chain reverts rather than falling back. Robinhood Chain testnet (46630) is not
supported — Flap ships a trigger service there but no Portal or Guardian.

Implements a custom `Vault + VaultFactory` pair following the Flap `VaultBaseV3` / `VaultFactoryBaseV2` specification. Tax revenue collected from Flap tax tokens — native BNB, or any ERC20/RWA quote token enabled on the Flap Portal (`mktBps` share) — is used to buy back the tax token via the Flap Portal and deposit it as base liquidity into the MYX protocol. The resulting MYX base-pool LP (mBase) is itself distributed to holders pro-rata via the token's native Dividend contract — **the LP IS the dividend asset** (no swap, no intermediate WBNB).

Supported quotes: native BNB, or any ERC20/RWA quote enabled on the Flap Portal (BSC mainnet/testnet); Robinhood Chain native only.

## Architecture

```
Flap tax token ──tax(mktBps)──▶ dispatch() ──BNB or ERC20 quote (+ zero-value ping)──▶ MyxVault.receive()
        receive(): balance-delta accounting (Flap spec V3) + best-effort schedule of a delayed process()
        creator: factory.prepayGas() before launch (ERC20 quote) → forwarded into the vault gas pool
        [anyone / trigger] process(): sync → (ERC20 quote) refill BNB gas pool via Flap MultiDexRouter
                 → buy back the tax token via the Flap Portal → deployPool if missing
                 → BasePool.deposit (mBase LP minted to vault) → _feedDividend()
        [anyone] fundGas(): top up the gas pool · sync(): recognize unpinged revenue
        [guardian/creator] emergencyWithdraw / emergencySweepNative / emergencyRescueToken
```

See [docs/flap-vault-integration-design.md](docs/flap-vault-integration-design.md) for the full design, verified constraints, and the phased development plan.

## Launch parameters

`vaultData = abi.encode(address marketQuoteToken, uint256 minProcessAmount, uint256 gasThreshold, uint256 gasRefillAmount)`;
`dividendToken = MAGIC_DIVIDEND_COMPUTED`; `dividendBps = 0`.

## Risks

- RWA quote tokens (bStocks) may carry transfer restrictions; the vault holds the quote between
  `dispatch()` and `process()`.
- The refill leg (ERC20 quote → WBNB → BNB via Flap's MultiDexRouter) is capped at
  `MAX_REFILL_SHARE_BPS = 2000` — at most 20% of a processed batch can be diverted to top up the gas
  pool, bounding griefing/slippage exposure from any single `process()` call.
- A refill swap that reverts (e.g. an RWA transfer restriction toward the DEX pool) does not brick
  the vault: the refill is skipped (`GasRefillSkipped`), the batch is untouched and the buyback still
  runs in the same `process()` call. Only the auto-scheduling stops once the gas pool runs dry —
  anyone can restore it by calling `fundGas()` with more than `gasThreshold`, and `process()` stays
  permissionless in the meantime.

## Layout

| Path | Content |
|---|---|
| `src/flap/` | Official Flap interfaces and base contracts (from [FlapVaultExample](https://github.com/flap-sh/FlapVaultExample)) |
| `src/FlapDeployed.sol` | Flap deployed contract addresses (BSC mainnet / testnet) |
| `src/` | `MyxVault` / `MyxVaultFactory` implementation (WIP) |
| `test/FlapBSCFixture.sol` | BSC fork test fixture (from FlapVaultExample) |
| `docs/` | Design docs and plans |
| `.agents/skills/` | Flap vault spec checker and helper skills |
| `script/` | Deployment scripts (mainnet / testnet) |

## Build

```bash
forge build
forge test
```

Dependencies are pinned via `foundry.lock` (forge-std v1.14.0, OpenZeppelin v4.9.6).
