# myx-flap-vault

MYX integration vault for the [Flap](https://docs.flap.sh) launchpad on BNB Chain.

Implements a custom `Vault + VaultFactory` pair following the Flap `VaultBaseV2` / `VaultFactoryBaseV2` specification. Tax revenue (native BNB, `mktBps` share) collected from Flap tax tokens is used to buy back the tax token via the Flap Portal and deposit it as base liquidity into the MYX protocol. The resulting MYX base-pool LP (mBase) is itself distributed to holders pro-rata via the token's native Dividend contract — **the LP IS the dividend asset** (no swap, no intermediate WBNB).

## Architecture

```
Flap tax token ──tax(mktBps)──▶ dispatch() ──BNB──▶ MyxVault.receive()
        receive(): accounting + best-effort schedule a delayed process() via FlapTriggerService
        [anyone / trigger] process(): BNB → buy back the tax token via the Flap Portal
                 → deployPool if missing → BasePool.deposit (mBase LP minted to vault)
                 → _feedDividend(): deposit the mBase LP ITSELF into the Dividend contract
                   (the LP is the dividend asset — no swap, no WBNB)
        [guardian/creator] emergencyWithdraw / emergencySweepBnb / emergencyRescueToken: rescue paths
```

See [docs/flap-vault-integration-design.md](docs/flap-vault-integration-design.md) for the full design, verified constraints, and the phased development plan.

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
