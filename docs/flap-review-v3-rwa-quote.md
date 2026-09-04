# MyxVault V3：BNB / RWA quote 税收 → myx LP 分红 — 提交 Flap 团队评审

日期：2026-09-03　仓库分支：`feat/vault-v3-erc20-quote`　联系人：MYX 团队

> 本文描述 MyxVault 对 Flap Vault Spec V3（ERC20 quote）的完整实现与我们在 BSC 主网 fork 上验证过的链上事实，并在末尾列出希望 Flap 确认或给出优化建议的具体问题。所有链上事实均标注了验证方式；凡未验证的假设都单独标出。

---

## 1. 目标

让 Flap 发币人可以选择**原生 BNB 或 Flap Portal 已启用的任意 ERC20 quote（含 bStocks 类 RWA 股票代币）**作为 tax token 的 quote。税收以该 quote 到账 MyxVault，vault 用税收在 Flap Portal 买回 tax token，存入 myx base 池得到 mBase LP，再把 LP **本身**作为分红资产存入 token 的 Flap 原生 Dividend 合约，由 Flap 的 `setShare` 转账钩子按持币比例分给持有者。

设计原则：

- 不引入 Flap 与 myx 之外的任何合约依赖；所有兑换走 Flap 自己的 `MultiDexRouter`。
- `receive()` 只做记账，永不 revert，不做任何外部兑换。
- 每笔 quote 出账都在同一函数内扣减记账基线（Rule 010）。
- 没有 fallback 路径：某一腿不可用时跳过并发事件，不尝试其他 venue。

---

## 2. 合约与依赖总览

| 合约 | 角色 |
|---|---|
| `MyxVault`（BeaconProxy，继承 `VaultBaseV3`） | 收税、记账、买回、入池、喂分红、gas 池 |
| `MyxVaultFactory`（非升级，`VaultFactoryBaseV2` + `IVaultFactoryDividendV23`） | 为 VaultPortal 部署 vault；quote 白名单；解析 `MAGIC_DIVIDEND_COMPUTED`；预付 gas |
| `MyxVaultUISchema`（外部链接库） | `vaultUISchema()` 的常量，为了让 vault 留在 EIP-170 之内 |

依赖的 Flap 组件（BSC 主网地址）：

| 组件 | 地址 | 用途 |
|---|---|---|
| Portal | `0xe2cE6ab80874Fa9Fa2aAE65D277Dd6B8e65C9De0` | `quoteExactInput` / `swapExactInput` 买回；`getQuoteTokenConfiguration` 读 quote 是否启用与 dexId |
| VaultPortal | `0x90497450f2a706f1951b5bdda52B4E5d16f34C06` | 发币、调用 `newVault`、`resolveDividendToken`、校验 `vaultQuoteToken()` |
| TaxProcessor（每币一个） | — | 派税 + 零值 ping；`swapRegistry()` |
| SwapRegistry | `0x644A8f560138418bAD4EdEFC7c17878a3c2fBEB6` | `multiDexRouter()`、`weth()` |
| MultiDexRouter | `0xDedF55b08a3f1c61576a4bd675825690e1eE99ec` | `getDEXInfo` / `computeV3PoolAddress` / `quoteExactInputSingle` / `exactInputSingle` |
| FlapTriggerService | `0xcf4EE25035CF883895110f367F5BA8172416a7F9` | 延迟触发 `process()` |
| Dividend（每币一个） | — | `deposit()` / `withdrawDividendsFor()` |

myx 侧：`PoolManager.deployPool/getPool`、`BasePool.deposit/withdraw`、`PoolFactory.predictBasePoolToken`（CREATE2 权威预测 mBase 地址）。

---

## 3. 发币流程

```
创建人 ── prepayGas{value ≥ minInitialGas}() ──▶ MyxVaultFactory.prepaidGas[creator]     (仅 ERC20 quote)
创建人 ── newTokenV6WithVault(params) ──▶ VaultPortal
   params.quoteToken      = address(0) 或 Portal 已启用的 ERC20
   params.dividendToken   = MAGIC_DIVIDEND_COMPUTED
   params.dividendBps     = 0            （由工厂 _validateBeforeLaunch 强制）
   params.vaultFactory    = MyxVaultFactory
   params.vaultData       = abi.encode(address marketQuoteToken, uint256 minProcessAmount,
                                       uint256 gasThreshold, uint256 gasRefillAmount)
VaultPortal:
   1. factory.isQuoteTokenSupported(quote)       → native 恒 true；ERC20 在 56/97 上按 Portal 配置 enabled==1
   2. factory.onBeforeLaunch(...)                → dividendBps == 0 且 dividendToken == MAGIC
   3. factory.resolveDividendToken(predicted, v, params)  (staticcall)
        → marketId = keccak256(chainId, marketQuoteToken)
        → return myx PoolFactory.predictBasePoolToken(marketId, predictedToken, symbol)   // mBase 地址
   4. factory.newVault(taxToken, quote, creator, vaultData)
        → 校验 minProcessAmount != 0；ERC20 时 gasRefillAmount ∈ (gasThreshold, maxGasRefillAmount]
        → 部署 BeaconProxy，initialize(InitParams{…, quoteToken = quote, …})
        → ERC20 时 require(prepaidGas[creator] ≥ minInitialGas)，清零并 vault.fundGas{value: 全额}()
   5. VaultPortal 校验 vault.vaultQuoteToken() == quote
```

`vaultData` 四个字段全部由创建人给出；工厂只做边界校验，发币后不可修改。

---

## 4. 收税与记账（Spec V3 / Rule 010）

```
TaxProcessor.dispatch()
   ├─ native quote: value transfer ──────────────▶ vault.receive()
   └─ ERC20 quote:  ERC20 transfer + zero-value ping ─▶ vault.receive()

receive():
   if (_unwrapping) return;                         // 见 §6.3，2300 gas 内返回
   _sync();                                         // bal = 当前 quote 余额; if bal > pendingQuote: 识别差额
   if (!hasPendingTrigger && pendingQuote >= minProcessAmount && !inProcess)
       try scheduleProcess() {} catch {}            // 任何失败只影响预约，不影响税收
```

- `pendingQuote` 即"已确认且未花费"的 quote，是 Rule 010 的基线。原生 quote 下恒有 `address(this).balance == pendingQuote`；ERC20 quote 下 BNB 余额是独立的 gas 池。
- 出账点：`process()` 买回、`executeGasRefill()`、`emergencySweepNative`（仅原生）、`emergencyRescueToken(quote)`、原生 quote 的触发手续费。每处都在同一函数内扣减基线。
- 零差值唤醒是静默 no-op；直接转入的 quote 在下一次唤醒或任何人调用 `sync()` 时被识别。

---

## 5. 自动触发与 gas 池

| 项 | 原生 quote | ERC20 quote |
|---|---|---|
| 手续费来源 | 从 `pendingQuote` 扣，仅在 `requestTrigger` 成功后 | 从 vault 的 BNB gas 池扣，`pendingQuote` 不动 |
| 预约条件 | `pendingQuote ≥ minProcessAmount + fee` | `pendingQuote ≥ minProcessAmount` 且 `balance ≥ fee` |
| gas 池初始来源 | 不需要 | 发币时工厂转入创建人的预付款 |
| gas 池补充 | 不需要 | `process()` 内自动 refill（§6.1）；任何人 `fundGas()` |

`trigger(requestId)`：校验 `msg.sender == TriggerService`，忽略陈旧 id，先清在途标记再 `try process()`，回调失败不会卡死后续预约。

---

## 6. `process()`（无许可）

```
_sync()
require(pendingQuote >= minProcessAmount)
_refillGas()                                     // 仅 ERC20 quote 且 gas 池 < gasThreshold
if (pendingQuote < minProcessAmount) { emit BuybackSkipped; _feedDividend(); return; }
amount = pendingQuote; pendingQuote = 0
received = _buyTaxToken(amount)                  // Portal.swapExactInput(inputToken = quote)，minOut = 同块报价 × (1 − maxSlippageBps)，按余额差值入账
_ensurePoolExists()                              // myx deployPool（首次）
basePool.deposit(poolId, received, 0, vault, vault)   → mBase LP
_feedDividend()                                  // LP 全额 deposit 进 Dividend；未接线 / deposit 返回 false 或 revert → 保留 LP，发 DividendDeferred，下次重试
```

### 6.1 gas refill（quote → WBNB → BNB）

- 地址全部运行时解析：`taxToken.taxProcessor().swapRegistry()` → `multiDexRouter()`、`weth()`；`dexId` 取 `Portal.getQuoteTokenConfiguration(quote).dexId`。vault 内不硬编码任何新地址。
- 选池：遍历 `router.getDEXInfo(dexId).v3SupportedFees`，`computeV3PoolAddress` 有代码的档位才 `quoteExactInputSingle`（try/catch），取最优输出。创建人无需指定费率。
- 用量：`needed = gasRefillAmount − balance`，按最优报价线性反推 `quoteIn`，**硬上限 20%**（`MAX_REFILL_SHARE_BPS = 2000`），只能补一部分时补一部分。
- 执行：`executeGasRefill()` 自调用 + try/catch，内部依次扣基线、approve、`exactInputSingle`、清 approve、`WBNB.withdraw`。任何失败整体回滚并发 `GasRefillSkipped`，买回照常进行。
- 解析 venue 失败（`swapVenue()` revert 或返回零地址）同样跳过。

### 6.2 为什么要 20% 上限

`quoteIn` 由同块报价线性反推，池价被压得越低反推出的 `quoteIn` 越大，而 `minOut` 也来自同一个被操纵的报价。没有上限时单次 `process()` 的损失上界是整批税收；20% 上限把它压到单批的 20%，且同一批不能重复调用。我们没有引入外部价格源，因为那会破坏"只依赖 Flap 与 myx"的原则。

### 6.3 WBNB 2300 gas 与 transient 标志

真实 WBNB 的 `withdraw()` 用 `transfer()` 付款，只给 2300 gas；vault 的 `receive()` 要读 ERC20 余额，装不下。解决：`bool transient _unwrapping`（EIP-1153），`executeGasRefill` 在 unwrap 前后置位/清除，`receive()` 第一条语句检查该标志直接返回。这意味着 vault 依赖 Cancun 的 TLOAD/TSTORE。

---

## 7. 应急与升级

- `EMERGENCY_ROLE`：Guardian 与 creator。`emergencyWithdraw`（LP 赎回）、`emergencySweepNative`（原生 quote 时清税并清基线；ERC20 quote 时只清 gas 池）、`emergencyRescueToken`（rescue quote 时清基线）。
- Guardian 角色不可被他人撤销（Flap 规范）；beacon 升级权限仅 Guardian，可永久锁定。
- 工厂持有的预付款按地址记账，只能本人取回或在本人发币时转入本人的 vault；工厂没有 `receive()`，余额恒等于预付款总和。

---

## 8. 我们验证过的链上事实

| 事实 | 验证方式 |
|---|---|
| BSC VaultPortal 对 `factorySpecVersion()=="v2.3"` 的工厂强制 vault 实现 `vaultQuoteToken()`，否则 `VaultQuoteTokenMismatch` | 主网 fork：v2.3 工厂 + 无该函数 vault 发币 revert；v2.2 工厂正常 |
| ERC20 quote（USDT / BTCB / NVDAB）带 vault 发币成功，`dispatch()` 转 ERC20 后零值 ping `receive()` 一次 | 主网 fork：vault 余额增量 == `marketQuoteBalance`，ping 1 次，`msg.value == 0` |
| ERC20 quote 发币时 `dividendToken` 不能为 0 | VaultPortal 报错文案 |
| `MAGIC_DIVIDEND_COMPUTED` + `resolveDividendToken` 在 BSC 主网生效 | 主网 fork |
| 发币交易里多付的 `msg.value` 全部流入 Portal，不退、不转给工厂或 vault | 主网 fork，两种 quote 均如此 |
| Portal 不能直接做 quote → BNB（`TokenNotTradable`），只在卖 tax token 时内部反向走 quote 路由 | 主网 fork + Portal v5.22.0 验证源 |
| NVDAB 的 Portal 内部路由是 NVDAB →(V3 1%)→ USDT →(V3 0.01%)→ WBNB，经 Portal 自己的 MultiDexRouter；无公开 getter | 调用追踪 + `QuoteRouteCodec` 源码 |
| SwapRegistry 指向的 MultiDexRouter 对任意合约开放 V3 报价与成交（dexId 0 = PancakeSwap，费率 [2500,100,10000,500]） | 主网 fork：3 NVDAB → 0.9585 WBNB |
| RWA 在 Pancake V2 池深度极浅，V3 池才有深度；USDT 侧最深 | 链上储备 |
| VaultPortal 对同一创建者有发币频率限制 `RateLimitExceeded` | 主网 fork |
| testnet TriggerService `getMaxCallbackGas()` = 2,000,000；首次 `process()`（含 myx `deployPool`）实测 292 万 gas，回调失败，后续回调 89 万 | BSC 测试网真实交易 |
| Robinhood VaultPortal 尚不接受 ERC20 quote 的 vault 发币（`UnsupportedQuoteToken`），也未校验 `vaultQuoteToken()` | Robinhood 主网 fork |
| Flap 自家 RWA/Index 工厂对 RWA quote 的 `isQuoteTokenSupported` 全为 false；SwapRegistry 分红兑换白名单不含 RWA → WBNB | 链上调用 |

测试：单元 186 个、BSC 主网 fork 端到端 3 个（原生 quote；NVDAB quote 预付 → 发币 → 交易 → dispatch ping → 自动预约 → `process()` refill + 买回 + 入池）。

---

## 9. 希望 Flap 确认的问题

1. **预付 gas 的两步流程**：ERC20 quote 下 vault 需要 BNB 付触发费，但发币交易的 `msg.value` 被 Portal 吞掉，我们只能让创建人先向工厂 `prepayGas()`。VaultPortal 有没有计划把多余的 `msg.value` 转发给 `newVault`，或提供"发币时附带原生币给 vault"的通道？这能把两笔交易合成一笔。
2. **MultiDexRouter 的接口稳定性**：我们从 SwapRegistry 动态读取 `multiDexRouter()` 并调用 `getDEXInfo / computeV3PoolAddress / quoteExactInputSingle / exactInputSingle`。这个合约没有公开文档，是否可以视为稳定接口？SwapRegistry 更换 router 时 ABI 会保持吗？
3. **Portal 的 quote 路由是否可以暴露 getter**：Portal 已为每个 quote 维护 `SWAP_VIA_ROUTE` 多跳路由（NVDAB 走 USDT 中转，深度更好），但没有读取接口。若能提供 `getQuoteSwapRoute(quote)`，vault 可以直接复用 Flap 的路由并反向执行，不必自己选池。
4. **回调 gas 上限**：`getMaxCallbackGas()` 2,000,000 不够首次 `process()`（myx `deployPool` + 首次买回 + 分红入账）。我们的做法是发币后先由任何人调用 `ensurePoolDeployed()`。是否有更好的做法，例如回调上限可按 requester 配置？
5. **ping 语义**：请确认 ping 是否会在同一次 `dispatch()` 中对同一钱包多次发出、是否可能被管理员关闭、以及是否有计划引入 `onFlapRevenue` 类型化回调（V3 NatSpec 提到的 FUTURE EXTENSIONS）。
6. **`receive()` 2300 gas**：我们用 EIP-1153 transient 标志解决 WBNB `withdraw` 的 2300 gas 限制。Flap 后续新链是否都会启用 Cancun（TLOAD/TSTORE）？Robinhood Chain 是否已支持？
7. **Robinhood**：Robinhood VaultPortal 目前不支持 ERC20 quote 的 vault 发币，也未做 `vaultQuoteToken()` 校验。是否有升级时间表？
8. **RWA 代币特性**：bStocks 类代币是否存在转账限制、黑名单或暂停机制？vault 在 dispatch 与 `process()` 之间会短暂持有 quote，若被冻结会影响买回。
9. **Rule 001 参数面**：`minProcessAmount / gasThreshold / gasRefillAmount` 由创建人在 vaultData 给出、发币后不可改，工厂只校验 `!= 0`、`refill > threshold`、`refill ≤ maxGasRefillAmount`。创建人最坏能做的是把每批最多 20% 的税转成只有 EMERGENCY_ROLE 能取的 BNB，而 creator 本来就持有 EMERGENCY_ROLE。这样的参数面是否符合 Flap 对 Rule 001 的要求？
10. **20% refill 上限**是否合理，或者 Flap 是否推荐某种价格参考来做更精确的 minOut？

---

## 附录 A：vault 关键接口

```solidity
function vaultQuoteToken() external view returns (address);   // address(0) = native
function vaultSpecVersion() external pure returns (string);   // "v3"
function pendingQuote() external view returns (uint256);
function gasBalance() external view returns (uint256);        // ERC20 quote 的 BNB gas 池
function sync() external;                                     // 无副作用的收入确认
function fundGas() external payable;                          // 任何人充值 gas 池（仅 ERC20 quote）
function process() external;                                  // 无许可
function feedDividend() external;                             // 重试被推迟的分红
function ensurePoolDeployed() external;                       // 发币后预建 myx 池
function claimReward() external;  function pendingReward(address) external view returns (uint256);
function trigger(uint256 requestId) external;                 // ITriggerReceiver
```

工厂：

```solidity
struct GlobalConfig { address poolManager; address basePool; address poolFactory; uint16 maxSlippageBps; uint256 minInitialGas; uint256 maxGasRefillAmount; }
function prepayGas() external payable;  function withdrawPrepaidGas() external;  function prepaidGas(address) external view returns (uint256);
function isQuoteTokenSupported(address) external view returns (bool);
function resolveDividendToken(address predicted, uint8 launchVersion, bytes launchParams) external view returns (address);
function factorySpecVersion() external pure returns (string);   // "v2.3"
```

## 附录 B：建议的发币参数（BSC 主网）

| 参数 | 建议 | 说明 |
|---|---|---|
| `minProcessAmount` | 一批税的价值远大于 0.0002 BNB 触发费（如 ≥ 1 USD 等值） | 太小会让每笔尘埃税都花一次触发费 |
| `gasThreshold` | ≈ 2 次触发费（0.0004 BNB） | |
| `gasRefillAmount` | ≈ 10 次触发费（0.002 BNB），≤ 工厂 `maxGasRefillAmount`（0.05 BNB） | |
| 工厂 `minInitialGas` | 0.002 BNB | 发币前预付 |
| 发币后 | 任何人调用一次 `ensurePoolDeployed()` | 避免首次回调超 200 万 gas |
