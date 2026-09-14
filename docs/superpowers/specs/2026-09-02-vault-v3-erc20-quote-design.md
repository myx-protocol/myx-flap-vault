# MyxVault V3：BNB / RWA quote 税收 → myx LP 分红 设计

日期：2026-09-02　分支：`feat/vault-v3-erc20-quote`　状态：待审阅

## 1. 目标与范围

让 Flap 发币人可以选 **原生 BNB 或 Flap 已启用的任意 ERC20 quote**（含 bStocks 类 RWA 股票代币）作为 tax token 的 quote，税收以该 quote 到账 vault，vault 把税收买回 tax token 存入 myx base 池，产出的 mBase LP 通过 Flap 原生 Dividend 合约按持币比例分给持有者。LP 分红这一段不变。

范围内：

- vault 收入模型改为 Flap spec V3 的余额差值记账，同一段代码处理原生币与 ERC20。
- ERC20 quote 下的 FlapTriggerService 手续费来源：BNB gas 池，由创建人发币前在工厂预付初始额度、低于阈值时用 quote 自动兑换补充、任何人可随时充值。
- 买回腿改为以 quote 为输入走 Portal。
- 工厂放开 quote 限制，vaultData 由创建人携带该 vault 的配置。
- 同步上游 `src/flap/`（`VaultBaseV3.sol`、rule 010、`IPortal` 枚举补齐）。
- 修复 main 上两个陈旧测试。

范围外（另开分支）：Robinhood Chain 的 V3 验证与适配。本分支保留现有 4663 硬编码地址不动；Robinhood 上工厂只声明支持原生币。

## 2. 已验证的链上事实（2026-09-02，BSC 主网 fork）

| 事实 | 证据 |
|---|---|
| BSC VaultPortal 对 `factorySpecVersion()=="v2.3"` 的工厂强制 vault 实现 `vaultQuoteToken()`，否则 `VaultQuoteTokenMismatch` | 探针：v2.3 工厂 + 无该函数的 vault 发币 revert；v2.2 工厂正常。**当前 MyxVault 在 BSC 主网无法发币。** |
| ERC20 quote（USDT / BTCB / NVDAB）带 vault 发币成功，`dispatch()` 把 ERC20 税转给 vault 并零值 ping `receive()` 一次 | 探针日志：vault quote 余额增量等于 `marketQuoteBalance`，`pings=1`，`msg.value=0` |
| ERC20 quote 发币时 dividendToken 不能为 0 | VaultPortal 报错文案 |
| `MAGIC_DIVIDEND_COMPUTED` + `resolveDividendToken` 在 BSC 生效 | 探针：dividendToken 解析为工厂返回值 |
| Portal 无法直接做 quote→BNB（`TokenNotTradable`），只在卖 tax token 时内部反向走 quote 路由 | 探针 + Portal v5.22.0 验证源 |
| Flap `MultiDexRouter`（SwapRegistry 指向，Sourcify 验证源）对任意合约开放 V3 报价与成交；dexId 0 = PancakeSwap，支持费率 [2500, 100, 10000, 500] | 探针：3 NVDAB 单跳 0.25% 档得 0.9585 WBNB；选池+报价约 46 万 gas |
| RWA 在 Pancake V2 池深度极浅，V3 池才有深度 | 链上储备查询 |
| VaultPortal 对同一创建者有发币频率限制 `RateLimitExceeded` | 探针，fork 测试需 `vm.warp` |
| 发币交易里多付的原生币全部流入 Portal，不退款、不转发给工厂或 vault（ERC20 quote 多付 0.01 BNB、native quote 多付 0.015 BNB 均如此） | 探针：sender 余额减少，Portal 余额等额增加，工厂与 vault 收到 0 |

## 3. 架构

```
创建人 ──prepayGas{value}()──▶ MyxVaultFactory.prepaidGas[creator]
VaultPortal ──newVault(taxToken, quote, creator, vaultData)──▶ 工厂部署 vault，ERC20 quote 时把 prepaidGas[creator] 全额 fundGas 进 vault
Flap TaxProcessor.dispatch()
   ├─ native quote: BNB value transfer ──▶ receive()
   └─ ERC20 quote:  ERC20 transfer + zero-value ping ──▶ receive()
receive(): _sync() 余额差值记账（轻量，不外呼 DEX）；满足条件且 poolReady 则 try scheduleProcess()
ensurePoolDeployed() [无许可；主网由 MYX 链下服务调用]: 部署 myx 池 → 闩锁 poolReady → 为积压税收预约触发
process() [仅 trigger() 回调可执行，2026-09-13 起；手动入口 requestProcess()]:
   _sync()
   ├─ ERC20 quote 且 gas 池 < gasThreshold ──▶ _refillGas(): quote → WBNB → BNB（Flap MultiDexRouter 自动选池）
   ├─ _buyTaxToken(): quote → tax token（Portal，同块报价做 minOut，余额差值入账）
   ├─ _ensurePoolExists(); basePool.deposit → mBase LP
   └─ _feedDividend(): LP 存入 Flap Dividend（不变，deferral-safe）
trigger(requestId) [FlapTriggerService 回调]: try process()
requestProcess() payable [任何人]: 预约触发，不在调用者交易内兑换（Flap 反馈：避免公开 swap 被抢跑+夹子）
fundGas() payable [任何人]: 向 gas 池充 BNB（仅 ERC20 quote）
sync() [任何人]: 无副作用的收入确认入口
```

依赖清单：Flap Portal / VaultPortal / TaxProcessor / SwapRegistry / MultiDexRouter / TriggerService / Dividend，myx PoolManager / BasePool / PoolFactory，WBNB。**不新增任何 Flap 或 myx 之外的合约地址**；MultiDexRouter、WBNB 地址运行时从 `taxToken.taxProcessor().swapRegistry()` 读取，dexId 从 Portal 的 quote 配置读取。

## 4. 合约改动

### 4.1 MyxVault

继承链改为 `VaultBaseV3`（新增 `vaultQuoteToken()`、`vaultSpecVersion()`），其余不变。

**存储与初始化**

```solidity
struct InitParams {
    address taxToken;
    address creator;
    address quoteToken;        // launch quote, address(0) = native; == vaultQuoteToken()
    address marketQuoteToken;  // myx market quote (USDT/USDC), unchanged semantics
    address poolManager;
    address basePool;
    uint16  maxSlippageBps;    // shared by buyback leg and gas refill leg
    uint256 minProcessAmount;  // in quote base units (creator-supplied, quote decimals aware)
    uint256 gasThreshold;      // wei; ERC20 quote only, 0 for native
    uint256 gasRefillAmount;   // wei; ERC20 quote only, must be > gasThreshold
    uint256 maxProcessAmount;  // quote base units; per-call buyback cap, >= minProcessAmount (added 2026-09-13 after pre-audit)
}
```

- `pendingEth` 重命名为 `pendingQuote`：语义变为"已确认且未花费的 quote 余额"，即 V3 的 `accountedQuote` 基线。
- 新增 `quoteToken`、`gasThreshold`、`gasRefillAmount`。`__gap` 相应缩减，保持 storage 布局 append-only（新字段放在 `hasPendingTrigger` 之后）。
- 校验：`marketQuoteToken != 0`；ERC20 quote 时 `gasRefillAmount > gasThreshold`；native quote 时两者必须为 0（避免误配）。

**收入确认（rule 010）**

```solidity
function _quoteBalance() internal view returns (uint256) {
    return quoteToken == address(0) ? address(this).balance : IERC20(quoteToken).balanceOf(address(this));
}
function _sync() internal returns (uint256 newRevenue) {
    uint256 bal = _quoteBalance();
    if (bal <= pendingQuote) return 0;            // zero-delta wake: silent no-op
    newRevenue = bal - pendingQuote;
    pendingQuote = bal;
    emit RevenueReceived(newRevenue, pendingQuote);
}
receive() external payable {
    _sync();
    if (!hasPendingTrigger && pendingQuote >= minProcessAmount && _probePoolReady()) { try this.scheduleProcess() {} catch {} }
}
function sync() external { _sync(); }
```

- 原生 quote 下 `address(this).balance == pendingQuote` 恒等（每笔出账同步扣减）；任何人直接打入的 BNB 视作捐赠。
- ERC20 quote 下 BNB 余额是 gas 池，与 `pendingQuote` 无关；任何人直接转入的 quote 在下一次唤醒时被当作税收。
- **每笔 quote 出账在同一函数内扣减 `pendingQuote`**：`process()` 买回、`_refillGas()`、`emergencySweep*`、native 下的 trigger fee。这是 rule 010 的 Critical 项。

**自动触发与 gas 池**

```solidity
function _gasAvailable() internal view returns (uint256) {
    return quoteToken == address(0) ? pendingQuote : address(this).balance;
}
function scheduleProcess() external {  // onlySelf
    uint256 fee = service.getFee();
    if (quoteToken == address(0)) {
        require(pendingQuote >= minProcessAmount + fee);
        ... requestTrigger{value: fee}; pendingQuote -= fee;
    } else {
        require(address(this).balance >= fee);          // gas pool
        require(pendingQuote >= minProcessAmount);
        ... requestTrigger{value: fee};                  // pendingQuote untouched
    }
}
function fundGas() external payable { require(quoteToken != address(0)); emit GasFunded(msg.sender, msg.value); }
```

- ERC20 quote 的 vault 在 `newVault` 时收到创建人的预付 gas（见 §4.2），首批税收即可自动预约。若预付耗尽且 refill 尚未发生，`receive()` 只记账不预约，任何人可手动 `process()`（内部 refill 后恢复自动预约）或 `fundGas()`。
- `trigger()` 回调逻辑不变（清标记 → try process）。

**池部署开关（2026-09-14）**

myx `deployPool` 实测约 2.06M gas，超过 FlapTriggerService 的 2M 回调上限，池部署不能进回调，也不拆成单独的触发任务（决定：链下 MYX 服务在税收累计约 1000 USD 时部署）。vault 只依据"池是否已部署"决定是否预约：

```solidity
bool public poolReady;                       // 一次性闩锁，与 hasPendingTrigger / quoteToken 同槽
function _probePoolReady() internal returns (bool) {   // 只在未闩锁时读池，发现即闩锁，从不部署
    if (poolReady) return true;
    if (poolManager.getPool(poolId).basePoolToken == address(0)) return false;
    poolReady = true; emit PoolReady(poolId); return true;
}
scheduleProcess(): require(poolReady)        // 不变量：有在途触发 ⇒ 池已部署
requestProcess(): require(_probePoolReady(), "Pool not deployed / 池尚未部署")
ensurePoolDeployed(): _ensurePoolExists()（部署缺失的池并闩锁）→ _sync() → 积压 ≥ minProcessAmount 则 try scheduleProcess()
_ensurePoolExists(): poolReady 已置位则直接返回（process() 内不再探测）
```

- 探测放在预约 try/catch 之外：预约失败（无 gas、服务不可用）不会撤销闩锁。
- 闩锁后不再读池：myx 池不会被移除；若极端情况下 deposit 失败，`process()` revert、税收留存，不会丢资金。

**gas 补充腿（仅 ERC20 quote）**

```solidity
function _refillGas() internal {
    if (quoteToken == address(0) || address(this).balance >= gasThreshold) return;
    uint256 needed = gasRefillAmount - address(this).balance;
    (uint24 fee, uint256 outForAll) = _bestPool(pendingQuote);     // quote all pending once
    if (outForAll == 0) { emit GasRefillSkipped(pendingQuote); return; }  // no pool: skip, do not revert
    uint256 quoteIn = outForAll >= needed ? pendingQuote * needed / outForAll : pendingQuote; // linear estimate, capped
    uint256 quoted = _quoteOut(fee, quoteIn);
    uint256 minOut = quoted * (BPS - maxSlippageBps) / BPS;
    pendingQuote -= quoteIn;                                        // rule 010: decrement before outflow
    forceApprove(router, quoteIn);
    uint256 got = router.exactInputSingle(dexId, {quoteToken, wbnb, fee, address(this), quoteIn, minOut, 0});
    IWBNB(wbnb).withdraw(got);
    emit GasRefilled(quoteIn, got);
}
```

- 地址解析：`registry = ITaxProcessor(IFlapTaxTokenV3(taxToken).taxProcessor()).swapRegistry()`；`router = registry.multiDexRouter()`；`wbnb = registry.weth()`；`dexId = IPortal(_getPortal()).getQuoteTokenConfiguration(quoteToken).dexId`。每次 refill 动态读，不缓存。
- `_bestPool(amountIn)`：遍历 `router.getDEXInfo(dexId).v3SupportedFees`，`computeV3PoolAddress` 有代码的档位才 `try quoteExactInputSingle`，取最大输出。单档报价 revert 不影响其他档。
- 没有任何可用池时 refill 跳过并发事件，`process()` 继续买回；不引入备用路径。
- 兑换后 `process()` 用剩余 `pendingQuote` 买回；若剩余低于 `minProcessAmount`，本次买回跳过（发事件），等下一批。

**买回腿**

`_buyTaxToken(uint256 quoteAmount)`：`inputToken = quoteToken`；ERC20 时先 `forceApprove(portal, amount)`，`swapExactInput` 不带 value；native 时保持 `{value: amount}`。报价、minOut、余额差值入账逻辑不变。

**应急路径**

- `emergencySweepEth` 改名 `emergencySweepNative`：native quote 下清空余额并置 `pendingQuote = 0`；ERC20 quote 下只清 gas 池，不动 `pendingQuote`。
- `emergencyRescueToken`：若 `token == quoteToken`，同步置 `pendingQuote = 0`（rule 010 出账扣基线）。
- `emergencyWithdraw` 不变。

**UI 面**

`description()` 显示 quote 符号与 `pendingQuote`（按 quote 精度格式化，`Decimal18` 需扩展为按 decimals 格式化）、gas 池余额。`vaultUISchema()` 增加 `vaultQuoteToken`、`sync`、`fundGas`、`gasBalance`。

### 4.2 MyxVaultFactory

- `GlobalConfig` 去掉 `minProcessAmount`（移入 vaultData）；保留 `poolManager / basePool / poolFactory / maxSlippageBps`（构造函数校验 `<= 10_000`）；新增 `maxGasRefillAmount`（wei，ERC20 quote 下创建人 `gasRefillAmount` 的上限，BSC 取 0.05 BNB、Robinhood 取 0）与 `minInitialGas`（wei，ERC20 quote 发币前必须预付的最低 BNB，建议取 FlapTriggerService 当前手续费的 10 倍，BSC 约 0.002 BNB）。
- **预付 gas**：
  - `prepayGas() external payable`：`prepaidGas[msg.sender] += msg.value`，任何地址可为自己预存，可多次累加。
  - `withdrawPrepaidGas()`：CEI 顺序全额退回 `prepaidGas[msg.sender]`。
  - `newVault` 中，若 `quoteToken != address(0)`：`require(prepaidGas[creator] >= config.minInitialGas)`（双语文案），随后清零记账并 `MyxVault(vault).fundGas{value: amount}()` 全额转入新 vault；转账失败则整笔发币 revert。`creator` 是 VaultPortal 传入的发币交易 `msg.sender`，不可伪造。native quote 时忽略预存，不转、不要求，创建人可自行取回。
  - 发币交易里多付的 `msg.value` 会被 Portal 吞掉（§2），因此预付必须是发给工厂的独立交易；前端把 approve / prepayGas / 发币串成一个流程。`onBeforeLaunch` 载荷不含 creator，无法在发币前预检预付额，只能在 `newVault` 内强制并由 VaultPortal 抛出文案。
- `vaultData = abi.encode(address marketQuoteToken, uint256 minProcessAmount, uint256 gasThreshold, uint256 gasRefillAmount, uint256 maxProcessAmount)`；`vaultDataSchema()` 同步描述五个字段，其中 `minProcessAmount` 的 decimals 由 UI 按 quote 处理，schema 里标 0 并在描述中说明"以 quote 最小单位计"。
- `newVault(taxToken, quoteToken, creator, vaultData)`：把 `quoteToken` 直传 `InitParams.quoteToken`；解码 vaultData 并做同 §4.1 的校验，失败用双语 `require` 文案。
- `isQuoteTokenSupported(quote)`：chainid 56/97 → `quote == 0 || IPortal(portal).getQuoteTokenConfiguration(quote).enabled == 1`；chainid 4663 → `quote == 0`。
- `_validateBeforeLaunch`：删除"quote 必须为原生币"；保留 dividendBps == 0 与 MAGIC 校验。`tokenCreationPolicies` 去掉 quote 策略。
- `resolveDividendToken` 不变（marketQuote 仍来自 vaultData 第一个字段，两处解码必须同源）。

### 4.3 `src/flap/` 同步

- 从上游 FlapVaultExample 引入 `VaultBaseV3.sol`；更新 `VaultBase.sol` / `VaultFactoryBaseV2.sol` 时**保留本地的 4663 分支与"无默认分支"注释**（上游把 46630 并入了 4663 分支，本分支不采纳）。
- `IPortal.sol`：`NativeToQuoteSwapType` 补 `SWAP_VIA_ROUTE`（值 7），否则 `getQuoteTokenConfiguration` 解码 RWA quote 会 revert。同时补 `QuoteHop` / `PoolType` 定义以便注释引用。
- 新增 `src/flap/ISwapRegistry.sol`、`src/flap/IMultiDexRouter.sol`（从 Sourcify 验证源截取所需子集）。
- `.agents/skills/flap-vault-spec-checker/` 同步 rule 010 与 prelude 中的 `VaultBaseV3.sol`。

## 5. 数据流与状态

状态变量：`pendingQuote`（基线）、gas 池（`address(this).balance`，仅 ERC20 quote 有意义）、`hasPendingTrigger / pendingTriggerId`、`poolReady`（一次性闩锁）、`totalLpMinted / totalRewardsForwarded`。

不变量：

1. native quote：`address(this).balance == pendingQuote`。
2. ERC20 quote：`IERC20(quote).balanceOf(this) >= pendingQuote`（多出部分是尚未确认的收入）。
3. 任何出账函数结束时 `pendingQuote` 已按出账额扣减。
4. `receive()` 只做记账、事件、一次 try 自调用；不调用 DEX。
5. `vaultQuoteToken()` 初始化后不可变、不 revert。
6. `hasPendingTrigger ⇒ poolReady`；`poolReady` 一旦为 true 永不回退。

## 6. 错误处理

- `receive()` 永不 revert：`_sync` 无 revert 路径，预约在 try/catch 内。
- `process()`：入口处 `pendingQuote < minProcessAmount`、买回报价为零、Portal 滑点超限 → revert（状态回滚，税收保留）。refill 无池 → 跳过不 revert；refill 之后剩余 `pendingQuote` 低于阈值 → 跳过买回、发事件、不 revert（refill 本身已是有效工作）。
- `_feedDividend` 保持 deferral 语义。
- 所有 revert 文案沿用双语 `unicode"English / 繁體中文"` 字面量（Flap 审计 F1/F2 约束）。

## 7. 安全与风险

- **创建人参数面（rule 001）**：创建人只能给 `minProcessAmount`、`gasThreshold`、`gasRefillAmount`，三者在发币时写入、之后不可变，因此边界只能由工厂在 `newVault` 里强制：`minProcessAmount != 0`；ERC20 quote 下 `gasRefillAmount <= GlobalConfig.maxGasRefillAmount`（BSC 主网/测试网脚本取 0.05 BNB，Robinhood 取 0）；vault `initialize` 另要求 `gasRefillAmount > gasThreshold`（ERC20）或两者为零（native）。剩下的旋钮是：偏大的 `gasRefillAmount` 会把每批税收里更多的额度（受 `MAX_REFILL_SHARE_BPS` = 20% 硬顶）换成 BNB 留在只有 EMERGENCY_ROLE 能清空的 gas 池里。这落在创建人本来就拥有的 EMERGENCY_ROLE 信任范围内——创建人在 `initialize` 时即被授予 EMERGENCY_ROLE，本就可以用 `emergencyRescueToken` 把 100% 的 quote 税收转走，因此这不是新增的攻击面。任何参数组合都卡不死 vault：refill 报不出价或整笔 revert 都会跳过（`GasRefillSkipped`），买回照常执行。
- **MEV**：买回腿维持同块报价 minOut；refill 腿同样用同块报价 minOut，且金额小。文档化接受。
- **RWA 代币特性**：bStocks 类代币可能有转账限制或冻结，vault 持有 quote 期间存在合规风险，超出合约层可控范围，需在 README 说明。
- **MultiDexRouter 未公开文档**：接口来自 Sourcify 验证源，Uniswap 风格；SwapRegistry 可能更换 router 地址，动态读取即可跟随；若未来 Flap 撤掉 `multiDexRouter()` 入口，refill 腿失效但买回与分红不受影响。
- **精度**：6 位精度 quote（XAUT）下所有 quote 计量以最小单位处理，`minProcessAmount` 由创建人按精度给出。
- **预付款归属**：预存款在工厂里按地址记账，只能由本人取回或在本人发币时转入本人的 vault；工厂不持有其他资金，`withdrawPrepaidGas` 走 CEI，`newVault` 仅 VaultPortal 可调，无重入面。转入 vault 后即成为 vault 的 gas 池，受 `emergencySweepNative` 管辖。

## 8. 测试策略

单元（mocks：Portal 含 quote 配置、TaxProcessor→SwapRegistry→MultiDexRouter、WBNB、TriggerService）：

- rule 010 三类：裸转账不入账而 ping 入账；零差值 ping 幂等；出账后基线扣减且后续收入仍可识别（无死锁）。
- native quote 回归：现有 `MyxVault.t.sol` / `MyxVaultAutoTrigger.t.sol` 全部通过，仅改字段名。
- ERC20 quote：process 买回走 ERC20 输入并 approve；refill 触发/不触发条件；无池时跳过；refill 后剩余低于阈值时跳过买回；`fundGas` 仅 ERC20 允许；scheduleProcess 从 gas 池付费。
- 工厂：`isQuoteTokenSupported` 按链与 Portal 配置；vaultData 校验；`resolveDividendToken` 回归；预付 gas：累加、取回、ERC20 quote 发币时低于 `minInitialGas` 拒绝、达标时全额转入 vault 且记账清零、native quote 时不动预存。
- `receive()` gas 断言维持 ≤ 1,000,000。
- 池开关：无池时唤醒不预约、不扣费；池后部署则下一次唤醒闩锁并预约；预约失败闩锁仍保留；`ensurePoolDeployed` 部署 + 闩锁 + 预约积压（低于下限不预约）、二次调用不再读池；`requestProcess` 无池 revert；`scheduleProcess` 只看闩锁。

fork（BSC 主网）：

- 修复现有 `Integration.fork.t.sol`（MAGIC dividend + fresh salt + `vm.warp` 规避频率限制）。
- 新增 NVDAB quote 端到端：`prepayGas` → 发币（断言 vault gas 池等于预付额）→ 交易 → dispatch ping（断言自动预约发生）→ `process()`（refill + 买回 + deposit）→ 断言 gas 池、LP 铸造。
- 说明公共 RPC 非归档限制：0.01% 档报价可能因缺 trie 节点失败，测试对该现象容错。

## 9. 交付与分支

- 本分支 `feat/vault-v3-erc20-quote` 基于 main。
- 部署脚本：BSC 主网/测试网脚本去掉 `minProcessAmount`；Robinhood 脚本同步字段但不做行为验证。
- README 与 `docs/flap-vault-integration-design.md` 更新为 V3 模型；`docs/spec-checker-findings.md` 增加 rule 010 结论。
- 提交与 PR 按用户指示进行，不自动提交。
