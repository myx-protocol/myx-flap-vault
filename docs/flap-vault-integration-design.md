# MYX × Flap Vault 接入设计

> 状态：草案 v2（待 review）
> 日期：2026-06-09
> 方向：myx 作为 Flap 的 Vault 开发者，在 BSC 内同链对接
> 机制：税收 → 加 base 流动性 → LP 由 vault 持有 → 按持币比例回流奖励

---

## 1. 背景与目标

Flap 是 BSC 上的 tax-token（fee-on-transfer）发射平台。第三方按规范实现 `Vault + VaultFactory`，承接代币交易抽到的税（native BNB），自定义其去向。

**本方案目标**：实现 `MyxVault + MyxVaultFactory`，让 Flap 上发行的 tax token 把抽到的税（`mktBps` 份额，native BNB）：

1. wrap / swap 成发币时指定的 **base token**；
2. 若目标 base pool 不存在则**先创建池子**，再 `BasePool.deposit` 添加 base 流动性；
3. 得到的 **LP 由 vault 持有**（不分发到用户钱包）；
4. vault 持有的 LP 持续累积奖励；定期 claim → 转 WBNB → 灌入该 tax token 的**原生 Dividend 合约**，由持币者**按持币比例**领取；
5. 合约提供两个查询：用户名义 LP 份额、用户可领奖励；前端据此展示并提供领取入口。

**链与资产**：全流程 BSC 内闭环，无跨链桥。

---

## 2. 四条定调结论

1. **myx 侧零核心代码改动**。建池 `deployPool` permissionless、`BasePool.deposit/claimUserRebate` 对合约开放、LP 是标准 ERC20、`pendingUserRebates` 是 public view。主体工作 100% 在 Flap vault 合约。

2. **`receive()` 是铁律红线**。Flap Spec Rule 005（Critical）禁止 `receive()` 调用树内任何外部调用 / swap / deposit / 无界循环，gas ≤ 1M。违反 → 该 token 税收永久损坏 + BNB 锁死。`receive()` 只记账，重活全异步。

3. **"自动建池"半可行，受 market 前置约束**。`PoolManager.deployPool(marketId, baseToken)` 无权限、任意合约可调，且建出的 **Cook 状态即允许 deposit**。但**前提是对应 `market` 已由 `RISK_ADMIN` 创建**（market 级是治理动作）。即：vault 能补 pool，但补不了 market。

4. **"按持币比例分奖励"复用 Flap 原生 Dividend，但有一个可行性前提待证**。按持币比例链上可得，无需链下系统；vault 把 LP 奖励灌进 token 原生 Dividend 合约即可让持币者按比例领。**但原生 Dividend 合约"是否支持外部主动注入"及其入金 ABI 未公开，必须 BscScan 反查**（Phase 0 头号阻塞项，见 §11）。

---

## 3. 关键事实（已源码级核实）

### 3.1 Flap 侧

| 事实 | 证据 |
|---|---|
| 仅支持 BSC（56 / 测试 97） | `VaultBase` error 定义 |
| Vault 只收 native BNB（quote 强制 `address(0)`） | factory 校验 |
| 税聚合：`dispatch()` 任意人可调，`call{gas:1_000_000}` 推**聚合后 BNB**给 `receive()`，**无 per-buyer 归属** | `FlapBSCFixture.sol:408-411` |
| `receive()` 禁外部调用（Rule 005 Critical） | `spec-checker/rules/005` |
| Dividend 地址：`IFlapTaxTokenV3(taxToken).dividendContract()`，收 WBNB（ERC20），原生按持币比例分 | `IFlapTaxTokenV3.sol:51-52`、`ITaxProcessor.sol` |
| Factory = BeaconProxy + UpgradeableBeacon；`newVault` `require(msg.sender==_getVaultPortal())` + `new BeaconProxy`；升级权限独占 Guardian | `FreeCoinBeacon.sol:183-205` |
| 构造期 taxToken 不存在（CREATE2），不能 init 期回调 | `IVaultFactory.sol:21-27` |
| Guardian 对每个 permissioned 函数不可撤销权限 | 规范页 |

**BSC 主网地址**：VaultPortal `0x90497450f2a706f1951b5bdda52B4E5d16f34C06` ｜ Guardian `0x9e27098dcD8844bcc6287a557E0b4D09C86B8a4b` ｜ WBNB `0xbb4CdB9CBd36B01bD1cBaEBF2De08d9173bc095c`。

### 3.2 myx 侧

| 事实 | 证据 |
|---|---|
| `deployPool(DeployPoolParams{marketId, baseToken})` **无权限** | `PoolManager.sol:152` |
| 建池前置：`market` 由 `RISK_ADMIN` 创建（`createMarket onlyRiskAdmin`） | `MarketManager.sol:116` |
| Cook 状态即可 deposit（`_validateDeposit` 仅挡 PreBench/Bench） | `BasePool.sol:478-481` |
| `BasePool.deposit(poolId,amountIn,minOut,user,recipient)` 对合约开放（`user==msg.sender`）；LP mint 给 `recipient` | `BasePool.sol:156-197`，校验 `:163` |
| base LP 标准 ERC20 | `BasePoolToken → TokenBase → ERC20Upgradeable` |
| `pendingUserRebates(poolId,user,price)` public view，返回 `(rebates, genesisRebates)` | `BasePool.sol:135-142` |
| `claimUserRebate(poolId,user,recipient)` 用户自己可调 | `BasePool.sol:275-278` |
| 交易利润经 rebate 机制单独可领（非纯净值复投），`withdraw` 时一并结算 | `BasePool.sol:216-272, 462-472` |
| base token 由 deployer 指定（≠quote，decimals<19）；BSC quote 典型 USDT | `PoolManager.sol:152-163`、`markets/usd` |
| myx 当前仅 Arbitrum Sepolia，BSC 未部署 | `hardhat.config.ts` |

---

## 4. 目标架构（BSC 内闭环）

```
Flap tax token ──tax(mktBps, 聚合)──▶ dispatch{gas:1M} ──BNB──▶ MyxVault.receive()
                                                                  │ 仅记账 pendingBnb += msg.value
                                                                  ▼
        [任意人] processRevenue():
            BNB ──wrap/swap(内部算 minOut)──▶ base token
            ──▶ if !poolExists: PoolManager.deployPool(marketId, baseToken)   // market 须已存在
            ──▶ BasePool.deposit(poolId, amt, minOut, self, self)             // LP 留 vault
                   ⋯ vault 持有 LP, 累积 rebate ⋯
        [任意人] harvest():
            BasePool.claimUserRebate(poolId, self, self)  // 领 USDT
            ──swap USDT→BNB──▶ WBNB.deposit ──▶ DividendContract.<inject>(WBNB)
                                                          ▼
                                          持币者按 balanceOf/totalSupply 比例领取
        [Guardian] emergencyWithdraw(): 赎回 vault 持有的 LP / 救援

查询(view, 给前端):
    userLpShare(user)   = lpHeld × flap.balanceOf(user) / flap.totalSupply()   // 名义份额
    pendingReward(user) = DividendContract.pending(user) 的包装               // 可领奖励
领取(前端): 用户钱包直接调 DividendContract.claim()（Flap 原生）
```

---

## 5. MyxVault 合约设计（主体产出）

> 合约全英文标识符。以下为接口级设计，含不变量与失败路径。

### 5.1 存储与初始化

- `initialize(address taxToken, bytes vaultData)`，由 factory 经 BeaconProxy 调用。
- `vaultData` 解码：`(MarketId marketId, address baseToken, address poolManager, address basePool, address swapRouter, uint16 maxSlippageBps, uint256 minProcessAmount)`。
- **不变量**：init 期不回调 taxToken（CREATE2 时未部署），仅存地址。
- 状态：`pendingBnb`、`lpToken`（首次 deposit 后缓存）、`poolId`（建池/查池后缓存）。

### 5.2 函数

| 函数 | 触发者 | 行为 | 不变量 / 失败路径 |
|---|---|---|---|
| `receive()` | dispatch | **仅** `pendingBnb += msg.value` | 绝不外部调用（Rule 005）；不 revert |
| `processRevenue()` | 任意人 | `require(pendingBnb >= minProcessAmount)`；BNB→wrap/swap→base（**minOut 内部用可信价源算**）；若 `!poolInitialized(poolId)` 则 `deployPool(marketId, baseToken)`；`BasePool.deposit(...,self,self)` | reentrancy guard；market 不存在 → revert（vault 无权建 market）；swap/deposit 失败 → BNB 安全滞留 pendingBnb |
| `harvest()` | 任意人 | `claimUserRebate(poolId,self,self)`（USDT）→ swap USDT→BNB → `WBNB.deposit` → `DividendContract.<inject>(amt)` | minOut 内部算；Dividend 注入失败 → revert，资金滞留 vault 重试 |
| `emergencyWithdraw(uint256 lpAmount, address to)` | Guardian/creator | 赎回 vault 持有的 LP，救援 | `onlyGuardianOrCreator`；应对 myx 异常/流动性枯竭 |
| `userLpShare(address user)` | view | `lpToken.balanceOf(self) * flap.balanceOf(user) / flap.totalSupply()` | 名义份额，前端展示用 |
| `pendingReward(address user)` | view | 包装 `DividendContract.pending(user)` | 给前端显示可领额 |
| `description()` / `vaultUISchema()` | view/pure | 动态披露 + UI schema | V2 强制 |

### 5.3 base 资产处理（"发币时指定 base"）

- `vaultData.baseToken` 指定：
  - `baseToken == WBNB`：BNB 直接 `WBNB.deposit{value:}` wrap，无 swap。
  - 其它（WBTC/WETH…）：`swapRouter` 把 BNB→baseToken，`minOut` 内部算。
- base token 备好后走 deposit。

### 5.4 自动建池（"池子没创建先部署"）

- 检查 `PoolManager.getPool(poolId).isPoolInitialized()`；未初始化则 `deployPool(MarketId, baseToken)`（permissionless）。
- **硬约束**：`marketId` 对应 market 必须已由 `RISK_ADMIN` 创建——vault 无权建 market。若 market 不存在，`processRevenue` revert，需 myx 治理先建 market（前置依赖，见 §7）。
- Cook 态即可 deposit；但 Cook→Primed/Trench 的激活仍需 LISTING_ADMIN（不影响 deposit，但影响池子可交易性 / LP 价值，见 §9 风险）。

### 5.5 收益分配（"按持币比例" → 复用原生 Dividend）

- vault `claimUserRebate` 领到 USDT → swap BNB → wrap WBNB → 注入 token 原生 Dividend 合约。
- 持币者按 `balanceOf/totalSupply` 经**原生 Dividend** 领取，vault **不自建分配/快照**。
- **默认策略**：仅 claim rebate 回流；交易利润的净值增长部分留在 vault 持有的 LP 内（本金性质，Guardian 应急可赎回）。是否额外提净值增长见 §10 待定项。

### 5.6 权限模型

- 每个 permissioned 函数（`emergencyWithdraw`）**必须同时授予 Guardian**（`0x9e27...8a4b`）；override `revokeRole` 对 Guardian 抛 `CannotRevokeGuardianRole()`。
- `processRevenue` / `harvest` 无许可（任意人）。
- 收敛 Guardian 影响面：不暴露任意提款，能力上界 = 暴露的 permissioned 集合。

---

## 6. MyxVaultFactory 合约设计

- **BeaconProxy + UpgradeableBeacon**，构造期建 impl+beacon。
- `newVault(taxToken, quoteToken, creator, vaultData)`：`require(msg.sender==_getVaultPortal())` → `abi.decode(vaultData)` → `new BeaconProxy(beacon, abi.encodeCall(MyxVault.initialize,(taxToken,vaultData)))`。用 `new` 非 CREATE2。
- `_validateBeforeLaunch`：强制 `quoteToken==address(0)`；校验税率/bps。
- `isQuoteTokenSupported` 仅 BNB；`vaultDataSchema()`；`factorySpecVersion()=="v2.2"`。
- 升级权限独占 Guardian（`require(msg.sender==_getGuardian())`）。

---

## 7. myx 侧"修改点"（诚实结论：以前置依赖为主）

| 项 | 性质 | 说明 |
|---|---|---|
| myx 在 BSC 主网部署 | **前置依赖** | Flap 在 BSC |
| 目标 base token 的 **market 已创建**（RISK_ADMIN） | **前置依赖** | vault 只能补 pool，补不了 market |
| 合约代码改动 | **≈ 0** | deployPool/deposit/claim 已对合约开放；可选加 view helper |
| （可选）池子激活到 Trench | 运营 | 影响池子可交易性与 LP 经济意义 |

---

## 8. Flap 开发计划（分阶段）

- **Phase 0 ｜ 补证（阻塞）**：
  - **BscScan 反查原生 Dividend 合约：是否支持外部注入 + 入金/pending ABI**（决定 §5.5 可行性）。
  - 确认目标 base token、对应 market 是否存在、poolId、PoolManager/BasePool 地址。
  - swap 路由（Pancake）+ BSC USDT/WBNB 地址 + 可信价源（Chainlink BNB/USD or TWAP）。
  - 核实 Cook 态 deposit 的 LP 完整生命周期（能否正常 claim/withdraw）。
- **Phase 1 ｜ 骨架**：VaultBaseV2/VaultFactoryBaseV2 继承、Beacon 工厂、`receive()` 空记账、Guardian 权限框架。
- **Phase 2 ｜ 资金流（TDD + BSC fork）**：`processRevenue`（wrap/swap→建池→deposit）、`harvest`（claim→WBNB→Dividend）。
- **Phase 3 ｜ 应急/边界**：emergencyWithdraw、内部 minOut、阈值/分批、失败路径、market 缺失分支。
- **Phase 4 ｜ 合规**：跑 `FlapVaultSpecChecker`（Rule 005 等）修到全过；补 `description/vaultUISchema/vaultDataSchema`；实现 `userLpShare/pendingReward` view。
- **Phase 5 ｜ 审计 + 上线**：第三方审计 → factory verify → BSC 主网部署。

---

## 9. 风险矩阵（资金安全优先）

| 风险 | 等级 | 缓解 |
|---|---|---|
| `receive()` 越界 → 税收永久损坏 + BNB 锁死 | **极高** | receive 纯记账；Phase 4 spec checker 门禁 |
| **原生 Dividend 不支持外部注入** → §5.5 分配方案失效 | **高** | Phase 0 头号验证；失败则退化为 vault 自建持币快照分配（复杂度大增） |
| `processRevenue/harvest` 任意人触发 → swap 三明治 | 高 | **minOut 内部算（禁传参）** + 阈值 + 小额分批 |
| **本金做市风险敞口**：税本金入 base LP，净值随 myx 盈亏/无常损失缩水 | 高（业务性，已选择承担） | 设本金上限/分批；Guardian 应急赎回 |
| Cook 态池子未激活 → LP 经济意义不全 / 赎回受限 | 中 | Phase 0 核实；推动 LISTING_ADMIN 激活到 Trench |
| 自动建池但 **market 不存在** | 中 | 前置依赖（治理建 market）；vault revert 安全滞留 |
| 双向 swap（BNB→base、USDT→BNB）损耗 | 中 | 累积到阈值批量处理降频 |
| Factory 不可升级 | 中 | 可变参数走 vaultData / Guardian 可改存储 |

---

## 10. 已确认的设计决策

1. 方向：myx 做 Flap 的 Vault。
2. 跨链：myx 上 BSC，同链对接，无桥。
3. 注资形态：税 → 加 **base 流动性**（非 quote）。
4. base 资产：**发币时指定**（vaultData），vault 按需 wrap(WBNB)/swap。
5. 建池：池子不存在则 vault 自动 `deployPool`（permissionless，Cook 即可 deposit；market 须已存在）。
6. LP 归属：**vault 持有**（不分发用户钱包）。
7. 收益分配：**按持币比例**，复用 Flap 原生 Dividend，无链下系统。
8. 触发权限：`processRevenue/harvest` 任意人可触发（内部 minOut + 阈值 + 分批防 MEV）。
9. 查询：`userLpShare(user)` 名义 LP 份额 + `pendingReward(user)` 可领奖励。
10. 领取：前端调原生 Dividend `claim()`。

**待定项（review 时定）**：是否额外提取 LP 净值增长部分回流（需成本会计，默认否）。

---

## 11. Phase 0 补证清单（开工前必须坐实）

- [ ] **原生 Dividend 合约：是否支持外部注入 + 入金函数签名 + pending 查询签名**（BscScan 反查 `dividendContract()` 已验证合约）——头号阻塞，决定分配方案可行性
- [ ] 目标 base token + 其 market 是否已存在 + poolId + PoolManager/BasePool 地址
- [ ] Pancake 路由 + BSC USDT/WBNB 地址 + 可信价源（Chainlink BNB/USD feed）
- [ ] Cook 态 deposit 的 LP 完整生命周期（claim/withdraw 是否正常）
- [ ] `pendingUserRebates` 的 price 入参来源（myx oracle 接口）

---

## 12. 参考

- 官方参考实现：`github.com/flap-sh/FlapVaultExample`（FreeCoinBeacon.sol、VaultBaseV2、VaultFactoryBaseV2）
- spec checker：`github.com/flap-sh/FlapVaultSpecChecker`（Rule 005）
- Flap 文档：`docs.flap.sh/flap/developers/vault-developers/`
- myx 关键文件：`src/pool/PoolManager.sol`、`src/pool/BasePool.sol`、`src/pool/token/BasePoolToken.sol`、`src/pool/MarketManager.sol`
