# MyxVault 实现升级：refill 与回购拆分（BSC 主网）

## 背景

旧实现把 gas 池补充（refill）和回购放在同一次 FlapTriggerService 回调里。gas 池低于创建人设置的
`gasThreshold` 时，这次回调在主网需要 4.5M 到 5M gas，超过服务 2,000,000 的上限，必然失败。
已确认受影响：MEMESTOCKS vault `0xa111bDbec89d06199A97460b462561ccd8887554`（BNCB quote），
HappyCoin vault `0x548e7DE7BB5958F3Bd0706f913D9C2AB3d9c89c0`（MYX quote）。

修复在 PR #4（merge `7d3ea76`）：refill 单独占一次回调（`RefillOnlyBatch` + `skipRefillOnce`），
零流动性费率档不报价，每次报价 gas 上限 300k。

## 存储兼容

唯一新增字段 `skipRefillOnce` 位于 slot 213 第 22 字节，旧布局中该字节未使用。所有原有变量的
slot、offset、类型不变，`__gap` 仍为 38。已在两个线上 vault 解码 slot 213，第 22 字节均为 0，
升级后读作 `false`，无需迁移或重新初始化。

## 步骤

### 1. 部署新实现（MYX 部署钱包）

```bash
forge script script/mainnet/bnb/UpgradeMyxVaultImplementation.s.sol \
  --rpc-url https://bsc-dataseed.bnbchain.org --private-key $PRIVATE_KEY \
  --libraries src/lib/MyxVaultUISchema.sol:MyxVaultUISchema:0x10Fd858F44eEd0DF1dCA64fB0BE78cB54971CA77 \
  --broadcast --verify
```

脚本只部署实现合约，并在部署后检查：代码是本次版本、已链接线上 UI schema 库、地址不同于当前实现。
输出里会打印 Guardian 交易的 calldata。

### 2. Guardian 切换 beacon（Flap 执行）

| 字段 | 值 |
|---|---|
| chainId | 56 |
| from | Guardian `0x9e27098dcD8844bcc6287a557E0b4D09C86B8a4b` |
| to | MyxVaultFactory `0xeaEEa9c17a5376497C44fE2a5F9c63FE3B23bf87` |
| value | 0 |
| 函数 | `upgradeVaultImplementation(address newImplementation)` |
| 参数 | 第 1 步输出的新实现地址 |
| calldata | `0x17e4c4d9` + 新实现地址左补零到 32 字节 |

### 3. 上线后核对

```bash
cast call 0xD0EBB6fB05c0e7bd17F3Caffc85aE5896c4A41f1 "implementation()(address)" --rpc-url https://bsc-dataseed.bnbchain.org
cast call 0x548e7DE7BB5958F3Bd0706f913D9C2AB3d9c89c0 "skipRefillOnce()(bool)" --rpc-url https://bsc-dataseed.bnbchain.org
cast call 0x548e7DE7BB5958F3Bd0706f913D9C2AB3d9c89c0 "REFILL_QUOTE_GAS()(uint256)" --rpc-url https://bsc-dataseed.bnbchain.org
```

卡住的 vault 不会自己醒来，需要一次唤醒：任何人调用 `requestProcess()`，或等下一笔税收派发。

### 回滚

Guardian 用同一函数把 beacon 指回旧实现 `0x429a991d50B00771E363071450084616D4DAD066`。旧代码不读
第 22 字节，回滚安全。

## 演练结果（2026-10-21，BSC 主网 fork，真实 factory / beacon / TriggerService / myx 池）

`test/UpgradeVaultImplementation.fork.t.sol`：

| 检查 | 结果 |
|---|---|
| 非 Guardian 调用升级 | revert |
| 升级后 HappyCoin、MEMESTOCKS 全部状态字段不变，`skipRefillOnce = false` | 通过 |
| HappyCoin 第 1 次回调（refill-only），服务交易总 gas | 1,251,761，成功 |
| HappyCoin 第 2 次回调（回购），服务交易总 gas | 1,224,014，成功 |
| HappyCoin 积压 49.14 MYX | 全部回购，铸造 LP 666,762 |

## 残余风险：gas 池的长期消耗

修复只保证 refill 和回购各自能在 2M 内完成，不保证 gas 池自给自足。触发费现为 0.0002 BNB。
gas 池低于 `gasThreshold` 时每个周期要两次回调（0.0004 BNB），refill 最多拿本批 20% 的税换 BNB。
以演练中的价格（约 0.0001 BNB / MYX）估算，单批低于约 20 MYX 时 refill 补不回两次手续费，
gas 池会慢慢下降；低于一次手续费后不再自动预约，需要有人 `fundGas()` 或
`requestProcess{value}()`。建议链下服务监控各 vault 的 `gasBalance()`，低于 `gasThreshold` 时补充。
