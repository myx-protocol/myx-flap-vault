# MYX × Flap Vault 设计

> 在 BSC 上为 Flap 发射的 tax token 实现一对 `MyxVault + MyxVaultFactory`：把代币交易税转化为 myx 永续做市 LP，并以该 LP 作为分红代币按持币比例分给持有者。

## 1. 目标与经济飞轮

Flap 是 BSC 上的 tax-token（fee-on-transfer）发射平台；第三方按 Flap Vault 规范实现金库，承接交易税（native BNB，`mktBps` 份额）并自定义其去向。

```
MEME(tax token) 交易 → 税(BNB) ──dispatch──▶ MyxVault.receive()  (只记账)
        [任意人] process(): BNB ──Flap Portal 买回──▶ MEME
                          ──▶ 存入 myx (MEME/USDT) base 池 ──▶ 得 LP 代币 mBase
                          ──▶ 把 mBase 存进该 MEME 的 Flap 原生 Dividend 合约(dividendToken = mBase)
        持有 MEME 的用户 ──按份额累积 mBase──▶ claimReward() 领走 mBase LP
        领到 mBase 的用户 ──持有 LP──▶ 自己去 myx 领 USDT rebate / 退本
```

**飞轮**：税 → 买回 MEME（价格支撑）+ 注入 myx 做市深度 → LP 持续产 USDT rebate → 分给持币者。分红资产是 **LP 本身**，持币者拿到 LP 后既享 LP 净值也可自取 myx 奖励。

## 2. 分红公平性：复用 Flap 原生 Dividend 的 setShare hook（不可刷）

公平的「持币即分」需要在每次代币转账时更新每人份额。我们的 vault 是 market（收 mktBps），不是 token 的 dividend 合约，**拿不到转账回调**——所以 vault 不自建任何 per-user 会计，而是把 LP 喂进 token 的 **Flap 原生 Dividend 合约**（MasterChef 累加器 `magnifiedDividendPerShare/rewardDebt`）。该合约靠 token 的 `_afterTokenTransfer → setShare(holder, balanceOf)`（`onlyTaxToken` 门）维护份额：

- `pendingReward(user)` → `dividend.withdrawableDividends(user)`
- `claimReward()` → `dividend.withdrawDividendsFor(msg.sender)`
- **不可刷**：新接收 token 的钱包 `rewardDebt` 以当前 index 基准，对此前已注入的分红零份额；领→转→再领无法刷出第二份。

（机制对照 Lista DAO 的 slisBNB 金库 `0xabd6156A587484EC487e7CcA236fCEE7E6e126a6`：金库只当「收益资产生产者 + dividend 喂料器 + claim 代理」，公平性 100% 来自 Flap Dividend 合约。我们把 slisBNB 换成 myx LP。）

## 3. 死循环与 Flap Spec v2.3 `computeDividendToken`

**死循环**：dividendToken 必须在 Portal 创建 MEME 时写进合约；但我们要用 myx LP(mBase) 当 dividendToken，而 mBase 地址依赖 MEME 地址，MEME 此刻还没部署（CREATE2 预测地址）。

**Flap Spec v2.3（官方 issue，本设计依赖、尚未上线）**：新增魔法地址 `MAGIC_DIVIDEND_COMPUTED`。发币时 dividendToken 填它；VaultPortal 预测出 MEME 地址后回调我们 factory：
```solidity
function computeDividendToken(address predictedToken, bytes calldata hint) external view returns (address);
```
我们在回调里从 `predictedToken` 算出 mBase 地址返回 → 它成为该 MEME 的 dividendToken。纯链上、无需预输入。

## 4. 三处合约

### 4.1 myx PoolFactory（CREATE2 + 权威预测 view）
为让 mBase 地址在 MEME 部署前可被精确预测：
- `_deployPoolToken` 的 `new BeaconProxy(beacon, initData)` 改为 **CREATE2**：`new BeaconProxy{salt: keccak256(abi.encode(poolId, underlyingToken))}(beacon, initData)`（underlyingToken 区分 base/quote）。
- 新增权威预测 view（地址数学只此一份，避免跨仓库漂移）：
  ```solidity
  function predictBasePoolToken(MarketId marketId, address baseToken, string calldata baseSymbol)
      external view returns (address);
  ```
  内部复刻部署用的 `initData`（含 `name="MYX Finance "+baseSym+"-"+quoteSym+" BasePool Token"`，`symbol="m"+baseSym`，quoteSym 链上现读 market.quoteToken.symbol()）+ salt，`Create2.computeAddress(salt, keccak256(initcode), POOL_FACTORY)`。
- 部署路径与预测路径共用同一组 `name/symbol/initData/salt` 助手 → **不可能漂移**。
- 测试 `PoolTokenPredict.t.sol` 焊死 `predictBasePoolToken(...) == 实际 deployPool 出来的 basePoolToken`（已字节级验证通过）。
- 副作用：CREATE2 改变所有 pool token 地址；`PoolFactory.initialize` 缓存依赖加了 `MARKET_MANAGER`（已部署工厂需重新注册）。

> myx 改动在 `feat/pool-token-create2` 分支，待 myx 团队 review。

### 4.2 MyxVaultFactory（非升级，BeaconProxy 工厂）
- `computeDividendToken(predictedToken, hint)`：从 `hint` 解出 `(quoteToken, symbol)`，`marketId = keccak256(abi.encode(uint64(chainid), quoteToken))`（已验证等价 myx `MarketIdLib`），`return IMyxPoolFactory(poolFactory).predictBasePoolToken(marketId, predictedToken, symbol)`。**地址数学全委托 myx，本地不复刻**。
- `factorySpecVersion() == "v2.3"`；`isQuoteTokenSupported` 仅 BNB；`_validateBeforeLaunch` 仅校验 `quoteToken==address(0)`（dividendToken 是 v2.3 sentinel，不在此校验）。
- `newVault`：`require(msg.sender==_getVaultPortal())`，vaultData = `abi.encode(address quoteToken)`，`new BeaconProxy(beacon, initData)`；升级权限独占 Guardian。
- GlobalConfig：`poolManager / basePool / poolFactory / maxSlippageBps / minProcessAmount`。

### 4.3 MyxVault（精简，322 行）
| 函数 | 触发 | 行为 |
|---|---|---|
| `receive()` | dispatch | **仅** `pendingBnb += msg.value`（Flap Rule 005：不外部调用、不 revert、≤1M gas） |
| `process()` | **任意人** | `pendingBnb→Portal 买回 MEME(minOut=同块 quote×(1-slippage), 余额差值入账)→若池不存在 deployPool→BasePool.deposit 得 LP→_feedDividend()` |
| `feedDividend()` | 任意人 | 把 vault 持有的 LP 喂进 Dividend；`dividendContract==0` 或 `deposit()` 返 false(`totalShares==0`) → 留 LP、`emit DividendDeferred`、下次重试（deferral，绝不 revert 卡死） |
| `claimReward()` | 任意人 | 代理 `dividend.withdrawDividendsFor(msg.sender)` |
| `pendingReward(user)` | view | 代理 `dividend.withdrawableDividends(user)`（mBase LP 单位） |
| `ensurePoolDeployed()` | 任意人 | 可选预建池 |
| `emergencyWithdraw / emergencySweepBnb / emergencyRescueToken` | EMERGENCY_ROLE(Guardian+creator) | 赎回 LP / 清 BNB / 救援滞留 LP 或杂入 ERC20 |

- `initialize`：`marketId = derive(chainid, marketQuoteToken)`，`poolId = derive(marketId, taxToken)`；授 Guardian `DEFAULT_ADMIN+EMERGENCY`、creator `EMERGENCY`；`revokeRole` 对 Guardian 不可撤销。
- **无 trigger / 无三模式 / 无 operator**：`process` 无许可（tax token 无外部喂价，同块 quote minOut 兜底单次损失；这是经过权衡的取舍）。

## 5. 持币者 UX
1. 持有 MEME → Flap Dividend 按份额累积 mBase（转账 hook，不可刷）。
2. `vault.claimReward()`（或直接在 Dividend）领走 mBase LP。
3. 持有 mBase LP → 自己去 myx `claimUserRebate` 领 USDT / `withdraw` 退本。

## 6. 已验证的链上事实
- **CREATE2 等价**（fuzz 256 + concrete）：`keccak256(abi.encode(uint64 chainId, quoteToken)) == myx MarketIdLib.toId`；`predictBasePoolToken == 实际 basePoolToken`。
- **Flap V3 转账税范围**：只对「注册池对手方」抽税，`pools` 集合 initialize 后不可变 → vault↔用户、vault→myx 池的普通转账免税（stake/deposit 无缺口）；Portal BUY 在 bonding curve 足额、DEX 阶段净额 → 买回腿用余额差值入账。
- **Flap Dividend `deposit(uint256)→bool`**：permissionless approve+pull dividendToken；`totalShares==0` 返 false（不 revert）→ 我们 defer。`withdrawableDividends(address)` 查、`withdrawDividendsFor(address)` 代领。
- **BSC 地址**：VaultPortal `0x9049…4C06`、Guardian `0x9e27…8a4b`。

## 7. 依赖与未决（上线前必须闭环）
| 项 | 等级 | 说明 |
|---|---|---|
| **Flap v2.3 未发布** | 阻塞真 e2e | `computeDividendToken`/`MAGIC_DIVIDEND_COMPUTED` 未上线；现仅 mock 测回调。Flap 发布后补真 VaultPortal e2e。 |
| **hint ABI** | 资金级 | 假设 `abi.encode(address quoteToken, string symbol)`；symbol 必须与 MEME 部署后 `symbol()` 逐字节相同（带不带 `$`、大小写）——差一字节预测地址错、dividendToken 打飞资金。与 Flap v2.3 钉死。 |
| **interim rebate 归属** | 高 | LP 喂进 Dividend 后、被领走前由 Dividend 合约持有，其间 myx rebate 归 Dividend 合约。LP 转给领取者时累积 rebate 跟不跟着走，取决于 **myx LP 转账的 rebate 会计**——需 myx 侧确认，否则有 rebate 滞留/漏分风险。 |
| **myx CREATE2 改动** | 协调 | 改变所有 pool token 地址 + initialize 依赖集；需 myx 团队接受并全测通过。 |
| **Rule 004（自定义 error）** | 低（已接受） | spec-checker Medium：自定义 error UI 不易解码；非安全问题，保留。 |

## 8. 部署
- 工厂部署脚本：`script/{mainnet,testnet}/bnb/DeployMyxVaultFactory.s.sol`，GlobalConfig 走 env（`MYX_POOL_MANAGER/MYX_BASE_POOL/MYX_POOL_FACTORY` + maxSlippageBps/minProcessAmount）。
- 前置依赖：myx 在 BSC 部署 + 对应 quote(USDT/USDC) market 由 RISK_ADMIN 创建。
- 发币：dividendToken 填 `MAGIC_DIVIDEND_COMPUTED`，vaultFactory 填本工厂，vaultData = `abi.encode(quoteToken)`，hint 带 `(quoteToken, MEME symbol)`。

## 9. 参考
- `.agents/skills/flap-vault-spec-checker/`（Rule 001–009 合规）；最新审计：`docs/spec-checker-findings.md`。
- 官方参考实现：`github.com/flap-sh/FlapVaultExample`；Lista slisBNB 金库 `0xabd6156A587484EC487e7CcA236fCEE7E6e126a6`（分红模式对照）。
- myx：`src/pool/PoolFactory.sol`（CREATE2+predict）、`src/pool/BasePool.sol`、`src/types/{MarketKey,PoolKey}.sol`。
