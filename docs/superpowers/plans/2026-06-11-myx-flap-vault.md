# MyxVault + MyxVaultFactory Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Implement a Flap-spec vault pair (`MyxVault` + `MyxVaultFactory`) that converts Flap tax revenue (native BNB) into MYX base-pool liquidity held by the vault, and routes harvested LP rebates back to token holders via the token's native Dividend contract.

**Architecture:** `MyxVaultFactory` (non-upgradeable, `VaultFactoryBaseV2`) deploys `MyxVault` instances as BeaconProxies; vault upgrades are Guardian-only. `MyxVault.receive()` only does accounting (Flap Rule 005); all heavy work lives in permissionless `processRevenue()` (BNB → base token → `BasePool.deposit`, auto-`deployPool` if missing) and `harvest()` (claim rebates → swap to WBNB → forward to Dividend contract). MEV protection: all swap `minOut` values are computed internally from Chainlink feeds — never caller-supplied.

**Tech Stack:** Foundry (solc 0.8.30, evm cancun), OpenZeppelin v4.9.6 (upgradeable), Flap base contracts (`src/flap/`), PancakeSwap V2 router, Chainlink feeds, BSC fork tests via `FlapBSCFixture`.

**Design doc:** `docs/flap-vault-integration-design.md` (v2). All key constraints verified there; this plan references them as [D§n].

---

## Known unknowns (isolated, not blocking)

1. **Dividend contract ABI — VERIFIED by Task 0** (docs/phase0-findings.md): `deposit(uint256) returns (bool)` is permissionless approve+pull WBNB (returns false on failure, never reverts — callers must check); per-holder view is `withdrawableDividends(address)`; holders claim via `withdrawDividends()` on the Dividend contract. Residual risks recorded in findings: Dividend owner (Flap Portal) can `emergencyWithdraw` unclaimed WBNB (custodial risk); `minimumShareBalance` excludes small holders from forwarded dividends.
2. **MYX is not deployed on BSC yet** [D§7]. All unit tests use mocks implementing the minimal interfaces extracted in Task 2 (signatures verified against `myx-contract-v2` source). The fork integration test (Task 12) uses real Flap contracts + mock MYX deployed onto the fork.

## File structure (locked)

```
src/
  flap/                          (existing, official — do not modify)
  FlapDeployed.sol               (existing)
  myx/IMyxPool.sol               Create: minimal MYX interfaces + PoolId derivation
  dex/IPancakeRouterV2.sol       Create: Pancake V2 router subset
  dex/IWBNB.sol                  Create: WETH9-style wrap interface
  oracle/IAggregatorV3.sol       Create: Chainlink subset
  dividend/IDividendDistributor.sol  Create: ASSUMED ABI (Task 0 verification point)
  MyxVault.sol                   Create: vault implementation (beacon impl)
  MyxVaultFactory.sol            Create: factory + beacon
test/
  FlapBSCFixture.sol             (existing)
  mocks/Mocks.sol                Create: all mocks in one file
  MyxVault.t.sol                 Create: vault unit tests
  MyxVaultFactory.t.sol          Create: factory unit tests
  Integration.fork.t.sol         Create: BSC fork end-to-end
script/
  testnet/bnb/DeployMyxVaultFactory.s.sol  Create
  mainnet/bnb/DeployMyxVaultFactory.s.sol  Create
docs/
  phase0-findings.md             Create (Task 0 output)
```

Conventions for every task: Solidity identifiers/comments/errors in English only. Commits use Conventional Commits, English, no Co-Authored-By trailer. After each task: `forge build` and the task's tests must pass before committing.

---

### Task 0: Phase-0 on-chain verification (research, no code)

**Files:**
- Create: `docs/phase0-findings.md`

This task needs network access to BSC (public RPC `https://bsc-dataseed.binance.org` and BscScan web). It verifies the single assumed ABI and records canonical addresses.

- [ ] **Step 1: Find a live Flap V3 tax token and its Dividend contract**

On BscScan, open the GiftV4VaultFactoryV2 contract `0x6909aD1822Ece349CDDAb98E6F62EeeD9fAa2e10`, find a recent `newVault` transaction, note the `taxToken`. Then:

```bash
cast call <taxToken> "dividendContract()(address)" --rpc-url https://bsc-dataseed.binance.org
cast call <taxToken> "taxProcessor()(address)" --rpc-url https://bsc-dataseed.binance.org
```

- [ ] **Step 2: Read the Dividend contract's verified source on BscScan**

Record in `docs/phase0-findings.md`:
1. Exact function signature for external deposits of WBNB (name, params, ERC20-approve-based or not).
2. Whether unsolicited external deposits are accepted at all (look for `onlyTaxProcessor`-style gates). **If gated, flag immediately — design §5.5 degrades to vault-internal snapshot distribution and this plan's Task 8 must be revised before execution continues.**
3. The pending/claimable view signature (needed by `pendingReward(user)` in Task 10).

- [ ] **Step 3: Record canonical BSC addresses**

Verify each with `cast call <addr> "symbol()(string)"` / `"decimals()(uint8)"` and record:

| Item | Expected | Verify |
|---|---|---|
| WBNB | `0xbb4CdB9CBd36B01bD1cBaEBF2De08d9173bc095c` | symbol=WBNB, dec=18 |
| USDT (BSC) | `0x55d398326f99059fF775485246999027B3197955` | symbol=USDT, dec=18 |
| Pancake V2 Router | `0x10ED43C718714eb63d5aA57B78B54704E256024E` | `WETH()` returns WBNB |
| Chainlink BNB/USD | `0x0567F2323251f0Aab15c8dFb1967E4e8A7D42aeE` | `decimals()` = 8 |
| Chainlink USDT/USD | `0xB97Ad0E74fa7d920791E90258A6E2085088b4320` | `decimals()` = 8 |

- [ ] **Step 4: Update `src/dividend/IDividendDistributor.sol` interface comment block with findings (after Task 2 creates it, or note for Task 2 if executed in order). Commit**

```bash
git add docs/phase0-findings.md
git commit -m "docs: record phase-0 on-chain verification findings"
```

---

### Task 1: Test mocks foundation

**Files:**
- Create: `test/mocks/Mocks.sol`

All mocks in one file — they are small and only used by tests.

- [ ] **Step 1: Write the mocks**

```solidity
// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {ERC20} from "@openzeppelin/token/ERC20/ERC20.sol";
import {IERC20} from "@openzeppelin/token/ERC20/IERC20.sol";

contract MockERC20 is ERC20 {
    constructor(string memory n, string memory s) ERC20(n, s) {}
    function mint(address to, uint256 amount) external { _mint(to, amount); }
}

contract MockWBNB is ERC20 {
    constructor() ERC20("Wrapped BNB", "WBNB") {}
    function deposit() external payable { _mint(msg.sender, msg.value); }
    function withdraw(uint256 wad) external {
        _burn(msg.sender, wad);
        (bool ok,) = msg.sender.call{value: wad}("");
        require(ok, "MockWBNB: send failed");
    }
    receive() external payable { _mint(msg.sender, msg.value); }
}

contract MockAggregatorV3 {
    int256 public answer;
    uint8 public immutable decimals_;
    constructor(int256 _answer, uint8 _decimals) { answer = _answer; decimals_ = _decimals; }
    function setAnswer(int256 a) external { answer = a; }
    function decimals() external view returns (uint8) { return decimals_; }
    function latestRoundData() external view returns (uint80, int256, uint256, uint256, uint80) {
        return (1, answer, block.timestamp, block.timestamp, 1);
    }
}

/// @dev Swaps at a fixed rate: amountOut = amountIn * rateNum / rateDen.
contract MockPancakeRouter {
    uint256 public rateNum = 1;
    uint256 public rateDen = 1;
    function setRate(uint256 num, uint256 den) external { rateNum = num; rateDen = den; }
    function swapExactTokensForTokens(
        uint256 amountIn, uint256 amountOutMin, address[] calldata path, address to, uint256
    ) external returns (uint256[] memory amounts) {
        IERC20(path[0]).transferFrom(msg.sender, address(this), amountIn);
        uint256 out = (amountIn * rateNum) / rateDen;
        require(out >= amountOutMin, "MockRouter: INSUFFICIENT_OUTPUT_AMOUNT");
        MockERC20(path[path.length - 1]).mint(to, out);
        amounts = new uint256[](path.length);
        amounts[0] = amountIn;
        amounts[path.length - 1] = out;
    }
}

contract MockDividendDistributor {
    IERC20 public immutable wbnb;
    uint256 public totalDeposited;
    bool public depositSucceeds = true;
    mapping(address => uint256) public pendingOf;
    constructor(address _wbnb) { wbnb = IERC20(_wbnb); }
    function setDepositSucceeds(bool v) external { depositSucceeds = v; }
    function deposit(uint256 amount) external returns (bool) {
        if (!depositSucceeds) return false; // mirrors real contract: false, not revert
        wbnb.transferFrom(msg.sender, address(this), amount);
        totalDeposited += amount;
        return true;
    }
    function setPending(address user, uint256 amount) external { pendingOf[user] = amount; }
    function withdrawableDividends(address user) external view returns (uint256) { return pendingOf[user]; }
}

contract MockTaxToken is ERC20 {
    address public dividendContract;
    constructor(address _dividend) ERC20("Mock Tax Token", "MTT") { dividendContract = _dividend; }
}
```

(`MockBasePool` / `MockPoolManager` are added in Task 2 Step 3, after the interfaces they implement exist.)

- [ ] **Step 2: Build**

Run: `forge build`
Expected: success.

- [ ] **Step 3: Commit**

```bash
git add test/mocks/Mocks.sol
git commit -m "test: add ERC20/WBNB/router/feed/dividend mocks"
```

---

### Task 2: External interfaces (MYX minimal, DEX, oracle, dividend)

**Files:**
- Create: `src/myx/IMyxPool.sol`
- Create: `src/dex/IPancakeRouterV2.sol`
- Create: `src/dex/IWBNB.sol`
- Create: `src/oracle/IAggregatorV3.sol`
- Create: `src/dividend/IDividendDistributor.sol`
- Modify: `test/mocks/Mocks.sol` (append MockBasePool, MockPoolManager)
- Test: compilation + mock conformance via `forge build`

Signatures below are extracted verbatim from `myx-contract-v2` (`src/interfaces/IBasePool.sol:77-186`, `src/interfaces/IPoolManager.sol:14-108`, `src/types/PoolKey.sol`, `src/types/Metadata.sol:33-56`). MYX interfaces are MIT-licensed upstream.

- [ ] **Step 1: Write `src/myx/IMyxPool.sol`**

```solidity
// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

type MarketId is bytes32;
type PoolId is bytes32;

/// @dev Mirrors myx-contract-v2 PoolKey hashing: poolId = keccak256(abi.encode(marketId, baseToken)).
library MyxPoolId {
    function derive(MarketId marketId, address baseToken) internal pure returns (PoolId) {
        return PoolId.wrap(keccak256(abi.encode(marketId, baseToken)));
    }
}

/// @dev Subset of myx PoolMetadata — field order must match upstream struct exactly.
struct PoolMetadata {
    MarketId marketId;
    PoolId poolId;
    address baseToken;
    address quoteToken;
    uint8 riskTier;
    uint8 state; // PoolState enum upstream; only zero-check is used here
    bool compoundEnabled;
    address basePoolToken;
    address quotePoolToken;
    address poolVault;
    address tradingVault;
}

interface IMyxPoolManager {
    struct DeployPoolParams {
        MarketId marketId;
        address baseToken;
    }

    /// @notice Permissionless in myx (PoolManager.sol:152); requires market to exist.
    function deployPool(DeployPoolParams calldata params) external;

    function getPool(PoolId poolId) external view returns (PoolMetadata memory pool);
}

interface IMyxBasePool {
    function deposit(PoolId poolId, uint256 amountIn, uint256 minAmountOut, address user, address recipient)
        external
        returns (uint256 amountOut);

    function withdraw(PoolId poolId, uint256 amountIn, uint256 minAmountOut, address user, address recipient)
        external
        returns (uint256 amountOut, uint256 rebateOut);

    function claimUserRebate(PoolId poolId, address user, address recipient) external returns (uint256 rebateOut);

    function pendingUserRebates(PoolId poolId, address user, uint256 price)
        external
        view
        returns (uint256 rebates, uint256 genesisRebates);
}
```

- [ ] **Step 2: Write the three small interfaces**

`src/dex/IWBNB.sol`:

```solidity
// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {IERC20} from "@openzeppelin/token/ERC20/IERC20.sol";

interface IWBNB is IERC20 {
    function deposit() external payable;
    function withdraw(uint256 wad) external;
}
```

`src/dex/IPancakeRouterV2.sol`:

```solidity
// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

interface IPancakeRouterV2 {
    function swapExactTokensForTokens(
        uint256 amountIn,
        uint256 amountOutMin,
        address[] calldata path,
        address to,
        uint256 deadline
    ) external returns (uint256[] memory amounts);
}
```

`src/oracle/IAggregatorV3.sol`:

```solidity
// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

interface IAggregatorV3 {
    function decimals() external view returns (uint8);
    function latestRoundData()
        external
        view
        returns (uint80 roundId, int256 answer, uint256 startedAt, uint256 updatedAt, uint80 answeredInRound);
}
```

`src/dividend/IDividendDistributor.sol`:

```solidity
// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

/// @notice Interface to the Flap tax token's native Dividend contract.
/// @dev ABI VERIFIED on-chain by Task 0 (docs/phase0-findings.md):
///      - deposit(uint256) is approve+pull WBNB, permissionless, RETURNS false ON FAILURE
///        (does not revert) — callers MUST check the return value.
///      - withdrawableDividends(address) is the per-holder claimable view.
///      - Holders claim via withdrawDividends() directly on the Dividend contract.
interface IDividendDistributor {
    function deposit(uint256 amount) external returns (bool success);
    function withdrawableDividends(address user) external view returns (uint256);
}
```

- [ ] **Step 3: Append MYX mocks to `test/mocks/Mocks.sol`**

```solidity
import {IMyxBasePool, IMyxPoolManager, PoolMetadata, PoolId, MarketId} from "../../src/myx/IMyxPool.sol";

/// @dev Mints LP 1:1 for deposits; pays rebates in quote token; tracks calls for assertions.
contract MockBasePool is IMyxBasePool {
    MockERC20 public immutable lpToken;
    MockERC20 public immutable quoteToken;
    uint256 public rebateToPay;
    uint256 public depositCallCount;
    uint256 public lastDepositAmount;
    address public lastDepositRecipient;

    constructor(MockERC20 _lp, MockERC20 _quote) {
        lpToken = _lp;
        quoteToken = _quote;
    }

    function setRebate(uint256 amount) external { rebateToPay = amount; }

    function deposit(PoolId, uint256 amountIn, uint256 minAmountOut, address user, address recipient)
        external
        returns (uint256 amountOut)
    {
        // pull base token like the real pool does (token address not tracked; tests pre-fund)
        amountOut = amountIn; // 1:1 LP
        require(amountOut >= minAmountOut, "MockBasePool: slippage");
        depositCallCount += 1;
        lastDepositAmount = amountIn;
        lastDepositRecipient = recipient;
        lpToken.mint(recipient, amountOut);
        user; // silence
    }

    function withdraw(PoolId, uint256 amountIn, uint256 minAmountOut, address, address recipient)
        external
        returns (uint256 amountOut, uint256 rebateOut)
    {
        amountOut = amountIn; // 1:1 back
        require(amountOut >= minAmountOut, "MockBasePool: slippage");
        quoteToken.mint(recipient, amountOut);
        rebateOut = 0;
    }

    function claimUserRebate(PoolId, address, address recipient) external returns (uint256 rebateOut) {
        rebateOut = rebateToPay;
        rebateToPay = 0;
        if (rebateOut > 0) quoteToken.mint(recipient, rebateOut);
    }

    function pendingUserRebates(PoolId, address, uint256) external view returns (uint256, uint256) {
        return (rebateToPay, 0);
    }
}

contract MockPoolManager is IMyxPoolManager {
    mapping(bytes32 => PoolMetadata) internal pools;
    uint256 public deployPoolCallCount;
    bool public marketExists = true;

    function setMarketExists(bool v) external { marketExists = v; }

    function setPool(PoolId poolId, PoolMetadata memory meta) external { pools[PoolId.unwrap(poolId)] = meta; }

    function deployPool(DeployPoolParams calldata params) external {
        require(marketExists, "MockPoolManager: market missing");
        deployPoolCallCount += 1;
        bytes32 id = keccak256(abi.encode(params.marketId, params.baseToken));
        PoolMetadata memory meta;
        meta.marketId = params.marketId;
        meta.poolId = PoolId.wrap(id);
        meta.baseToken = params.baseToken;
        pools[id] = meta;
    }

    function getPool(PoolId poolId) external view returns (PoolMetadata memory) {
        return pools[PoolId.unwrap(poolId)];
    }
}
```

- [ ] **Step 4: Build**

Run: `forge build`
Expected: success (interfaces compile, mocks conform).

- [ ] **Step 5: Commit**

```bash
git add src/myx src/dex src/oracle src/dividend test/mocks/Mocks.sol
git commit -m "feat: add minimal myx/dex/oracle/dividend interfaces and myx mocks"
```

---

### Task 3: MyxVault skeleton — storage, initialize, receive()

**Files:**
- Create: `src/MyxVault.sol`
- Create: `test/MyxVault.t.sol`

`receive()` does accounting ONLY — Flap Rule 005 (Critical): no external calls, no loops, worst-case gas ≤ 1M, must never revert on plain BNB transfer. Violation permanently bricks tax collection for the token [D§2].

- [ ] **Step 1: Write failing tests**

```solidity
// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.26;

import {Test} from "forge-std/Test.sol";
import {MyxVault} from "../src/MyxVault.sol";
import {MarketId, PoolId, MyxPoolId} from "../src/myx/IMyxPool.sol";
import "./mocks/Mocks.sol";

contract MyxVaultTestBase is Test {
    MyxVault vault;
    MockWBNB wbnb;
    MockERC20 usdt;
    MockERC20 baseToken; // non-WBNB base for swap-path tests
    MockERC20 lpToken;
    MockBasePool basePool;
    MockPoolManager poolManager;
    MockPancakeRouter router;
    MockAggregatorV3 bnbUsdFeed;
    MockAggregatorV3 usdtUsdFeed;
    MockDividendDistributor dividend;
    MockTaxToken taxToken;

    address creator = makeAddr("creator");
    // Guardian address hardcoded in VaultBase for chainId 56; tests chain-id 31337 would revert.
    // We etch chainid 56 via vm.chainId so _getGuardian() resolves.
    address constant GUARDIAN = 0x9e27098dcD8844bcc6287a557E0b4D09C86B8a4b;
    MarketId marketId = MarketId.wrap(bytes32(uint256(1)));

    function setUp() public virtual {
        vm.chainId(56);
        wbnb = new MockWBNB();
        usdt = new MockERC20("Tether", "USDT");
        baseToken = new MockERC20("Base", "BASE");
        lpToken = new MockERC20("MYX LP", "MLP");
        basePool = new MockBasePool(lpToken, usdt);
        poolManager = new MockPoolManager();
        router = new MockPancakeRouter();
        bnbUsdFeed = new MockAggregatorV3(600e8, 8);  // BNB = $600
        usdtUsdFeed = new MockAggregatorV3(1e8, 8);   // USDT = $1
        dividend = new MockDividendDistributor(address(wbnb));
        taxToken = new MockTaxToken(address(dividend));

        vault = new MyxVault();
        vault.initialize(_initParams(address(wbnb))); // base = WBNB by default
    }

    function _initParams(address base) internal view returns (MyxVault.InitParams memory p) {
        p.taxToken = address(taxToken);
        p.creator = creator;
        p.baseToken = base;
        p.marketId = marketId;
        p.poolManager = address(poolManager);
        p.basePool = address(basePool);
        p.swapRouter = address(router);
        p.wbnb = address(wbnb);
        p.quoteToken = address(usdt);
        p.bnbUsdFeed = address(bnbUsdFeed);
        p.usdtUsdFeed = address(usdtUsdFeed);
        p.maxSlippageBps = 300;          // 3%
        p.minProcessAmount = 0.1 ether;  // BNB
    }
}

contract MyxVaultInitTest is MyxVaultTestBase {
    function test_initialize_storesConfig() public view {
        assertEq(vault.taxToken(), address(taxToken));
        assertEq(vault.baseToken(), address(wbnb));
        assertEq(PoolId.unwrap(vault.poolId()), PoolId.unwrap(MyxPoolId.derive(marketId, address(wbnb))));
    }

    function test_initialize_revertsOnSecondCall() public {
        vm.expectRevert();
        vault.initialize(_initParams(address(wbnb)));
    }

    function test_receive_accountsOnly() public {
        vm.deal(address(this), 1 ether);
        (bool ok,) = address(vault).call{value: 1 ether}("");
        assertTrue(ok);
        assertEq(vault.pendingBnb(), 1 ether);
        assertEq(address(vault).balance, 1 ether);
    }

    function test_receive_gasUnder1M() public {
        vm.deal(address(this), 1 ether);
        uint256 gasBefore = gasleft();
        (bool ok,) = address(vault).call{value: 1 ether}("");
        uint256 used = gasBefore - gasleft();
        assertTrue(ok);
        assertLt(used, 100_000); // far below the 1M Rule-005 budget
    }
}
```

- [ ] **Step 2: Run tests to verify they fail**

Run: `forge test --match-contract MyxVaultInitTest -v`
Expected: FAIL — `MyxVault` not found / does not compile.

- [ ] **Step 3: Write the vault skeleton**

```solidity
// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.26;

import {VaultBaseV2} from "./flap/VaultBaseV2.sol";
import {VaultUISchema} from "./flap/IVaultSchemasV1.sol";
import {Initializable} from "@openzeppelin-contracts-upgradeable/proxy/utils/Initializable.sol";
import {AccessControlUpgradeable} from "@openzeppelin-contracts-upgradeable/access/AccessControlUpgradeable.sol";
import {ReentrancyGuardUpgradeable} from "@openzeppelin-contracts-upgradeable/security/ReentrancyGuardUpgradeable.sol";
import {IERC20} from "@openzeppelin/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/token/ERC20/utils/SafeERC20.sol";
import {MarketId, PoolId, MyxPoolId, PoolMetadata, IMyxPoolManager, IMyxBasePool} from "./myx/IMyxPool.sol";
import {IPancakeRouterV2} from "./dex/IPancakeRouterV2.sol";
import {IWBNB} from "./dex/IWBNB.sol";
import {IAggregatorV3} from "./oracle/IAggregatorV3.sol";
import {IDividendDistributor} from "./dividend/IDividendDistributor.sol";

/// @title MyxVault
/// @notice Flap vault that deposits tax revenue as MYX base-pool liquidity (LP held by
///         the vault) and forwards harvested rebates to the token's Dividend contract.
/// @dev Invariants:
///      - receive() performs accounting only (Flap Rule 005), never external calls.
///      - All swap minOut values are derived from Chainlink feeds inside the contract.
///      - Guardian retains irrevocable EMERGENCY_ROLE (Flap mandate).
contract MyxVault is VaultBaseV2, Initializable, AccessControlUpgradeable, ReentrancyGuardUpgradeable {
    using SafeERC20 for IERC20;

    struct InitParams {
        address taxToken;
        address creator;
        address baseToken;
        MarketId marketId;
        address poolManager;
        address basePool;
        address swapRouter;
        address wbnb;
        address quoteToken;
        address bnbUsdFeed;
        address usdtUsdFeed;
        uint16 maxSlippageBps;
        uint256 minProcessAmount;
    }

    bytes32 public constant EMERGENCY_ROLE = keccak256("EMERGENCY_ROLE");
    uint16 public constant BPS_DENOMINATOR = 10_000;

    error CannotRevokeGuardianRole();
    error BelowMinimumProcessAmount(uint256 pending, uint256 minimum);
    error StalePrice(address feed);
    error MarketNotInitialized();
    error DividendDepositFailed();

    event RevenueReceived(uint256 amount, uint256 pendingTotal);
    event RevenueProcessed(uint256 bnbAmount, uint256 baseAmount, uint256 lpMinted);
    event PoolDeployed(PoolId poolId);
    event Harvested(uint256 rebateAmount, uint256 wbnbForwarded);
    event EmergencyWithdrawal(uint256 lpAmount, uint256 amountOut, address to);
    event EmergencySwept(uint256 bnbAmount, address to);

    address public taxToken;
    address public creator;
    address public baseToken;
    MarketId public marketId;
    PoolId public poolId;
    IMyxPoolManager public poolManager;
    IMyxBasePool public basePool;
    IPancakeRouterV2 public swapRouter;
    IWBNB public wbnb;
    IERC20 public quoteToken;
    IAggregatorV3 public bnbUsdFeed;
    IAggregatorV3 public usdtUsdFeed;
    uint16 public maxSlippageBps;
    uint256 public minProcessAmount;

    uint256 public pendingBnb;
    uint256 public totalLpMinted;
    uint256 public totalRewardsForwarded;

    constructor() {
        _disableInitializers();
    }

    function initialize(InitParams calldata p) external initializer {
        __AccessControl_init();
        __ReentrancyGuard_init();

        taxToken = p.taxToken;
        creator = p.creator;
        baseToken = p.baseToken;
        marketId = p.marketId;
        poolId = MyxPoolId.derive(p.marketId, p.baseToken);
        poolManager = IMyxPoolManager(p.poolManager);
        basePool = IMyxBasePool(p.basePool);
        swapRouter = IPancakeRouterV2(p.swapRouter);
        wbnb = IWBNB(p.wbnb);
        quoteToken = IERC20(p.quoteToken);
        bnbUsdFeed = IAggregatorV3(p.bnbUsdFeed);
        usdtUsdFeed = IAggregatorV3(p.usdtUsdFeed);
        maxSlippageBps = p.maxSlippageBps;
        minProcessAmount = p.minProcessAmount;

        address guardian = _getGuardian();
        _grantRole(DEFAULT_ADMIN_ROLE, guardian);
        _grantRole(EMERGENCY_ROLE, guardian);
        _grantRole(EMERGENCY_ROLE, p.creator);
    }

    /// @dev Flap Rule 005: accounting only. No external calls, no loops, never reverts.
    receive() external payable {
        pendingBnb += msg.value;
        emit RevenueReceived(msg.value, pendingBnb);
    }

    /// @dev Flap mandate: the Guardian role must not be revocable by anyone else.
    function revokeRole(bytes32 role, address account) public override onlyRole(getRoleAdmin(role)) {
        if (account == _getGuardian()) revert CannotRevokeGuardianRole();
        super.revokeRole(role, account);
    }

    // ── implemented in later tasks ──
    function description() public view virtual override returns (string memory) {
        return "MyxVault";
    }

    function vaultUISchema() public pure virtual override returns (VaultUISchema memory schema) {
        schema.vaultType = "MyxVault";
    }
}
```

- [ ] **Step 4: Run tests to verify they pass**

Run: `forge test --match-contract MyxVaultInitTest -v`
Expected: 4 PASS.

- [ ] **Step 5: Commit**

```bash
git add src/MyxVault.sol test/MyxVault.t.sol
git commit -m "feat: add MyxVault skeleton with rule-005-safe receive and guardian roles"
```

---

### Task 4: Guardian role invariants

**Files:**
- Modify: `test/MyxVault.t.sol` (append test contract)

The implementation already exists (Task 3 `revokeRole` override + role grants). This task locks the Flap mandate with tests.

- [ ] **Step 1: Write the tests**

```solidity
contract MyxVaultGuardianTest is MyxVaultTestBase {
    function test_guardianHasEmergencyAndAdminRole() public view {
        assertTrue(vault.hasRole(vault.EMERGENCY_ROLE(), GUARDIAN));
        assertTrue(vault.hasRole(vault.DEFAULT_ADMIN_ROLE(), GUARDIAN));
    }

    function test_creatorHasEmergencyRole() public view {
        assertTrue(vault.hasRole(vault.EMERGENCY_ROLE(), creator));
    }

    function test_revokeGuardianRole_reverts() public {
        bytes32 role = vault.EMERGENCY_ROLE();
        vm.prank(GUARDIAN); // even the admin itself cannot revoke the guardian
        vm.expectRevert(MyxVault.CannotRevokeGuardianRole.selector);
        vault.revokeRole(role, GUARDIAN);
    }

    function test_guardianCanRevokeOthers() public {
        bytes32 role = vault.EMERGENCY_ROLE();
        vm.prank(GUARDIAN);
        vault.revokeRole(role, creator);
        assertFalse(vault.hasRole(role, creator));
    }

    function test_guardianCanRenounceItself() public {
        bytes32 role = vault.EMERGENCY_ROLE();
        vm.prank(GUARDIAN);
        vault.renounceRole(role, GUARDIAN);
        assertFalse(vault.hasRole(role, GUARDIAN));
    }
}
```

- [ ] **Step 2: Run tests**

Run: `forge test --match-contract MyxVaultGuardianTest -v`
Expected: 5 PASS (implementation from Task 3 already satisfies them; if any fail, fix `MyxVault` — not the tests).

- [ ] **Step 3: Commit**

```bash
git add test/MyxVault.t.sol
git commit -m "test: lock guardian irrevocability invariants"
```

---

### Task 5: processRevenue — WBNB direct path

**Files:**
- Modify: `src/MyxVault.sol`
- Modify: `test/MyxVault.t.sol` (append test contract)

baseToken == WBNB ⇒ wrap only, no swap [D§5.3]. `minAmountOut` for `BasePool.deposit` is 0 by design: MYX LP minting is oracle-priced (exchange rate from reserve info + oracle price, not AMM spot), so there is no AMM-style sandwich surface on the mint itself; the swap leg (Task 7) carries the MEV protection.

- [ ] **Step 1: Write failing tests**

```solidity
contract MyxVaultProcessWbnbTest is MyxVaultTestBase {
    function setUp() public override {
        super.setUp();
        // register the WBNB pool as already existing
        PoolMetadata memory meta;
        meta.marketId = marketId;
        meta.poolId = MyxPoolId.derive(marketId, address(wbnb));
        meta.baseToken = address(wbnb);
        meta.basePoolToken = address(lpToken);
        poolManager.setPool(meta.poolId, meta);
    }

    function _fund(uint256 amount) internal {
        vm.deal(address(this), amount);
        (bool ok,) = address(vault).call{value: amount}("");
        assertTrue(ok);
    }

    function test_processRevenue_wrapsAndDeposits() public {
        _fund(1 ether);
        vault.processRevenue();
        assertEq(vault.pendingBnb(), 0);
        assertEq(basePool.depositCallCount(), 1);
        assertEq(basePool.lastDepositAmount(), 1 ether);
        assertEq(basePool.lastDepositRecipient(), address(vault)); // LP held by vault
        assertEq(lpToken.balanceOf(address(vault)), 1 ether);
        assertEq(vault.totalLpMinted(), 1 ether);
    }

    function test_processRevenue_revertsBelowMinimum() public {
        _fund(0.05 ether); // below 0.1 ether minProcessAmount
        vm.expectRevert(
            abi.encodeWithSelector(MyxVault.BelowMinimumProcessAmount.selector, 0.05 ether, 0.1 ether)
        );
        vault.processRevenue();
    }

    function test_processRevenue_failedDepositLeavesBnbPending() public {
        _fund(1 ether);
        vm.mockCallRevert(
            address(basePool),
            abi.encodeWithSelector(IMyxBasePool.deposit.selector),
            "POOL_PAUSED"
        );
        vm.expectRevert();
        vault.processRevenue();
        // state rolled back: BNB safely retained for retry
        assertEq(vault.pendingBnb(), 1 ether);
        assertEq(address(vault).balance, 1 ether);
    }

    function test_processRevenue_callableByAnyone() public {
        _fund(1 ether);
        vm.prank(makeAddr("randomCaller"));
        vault.processRevenue();
        assertEq(basePool.depositCallCount(), 1);
    }
}
```

- [ ] **Step 2: Run tests to verify they fail**

Run: `forge test --match-contract MyxVaultProcessWbnbTest -v`
Expected: FAIL — `processRevenue` not defined.

- [ ] **Step 3: Implement (append to MyxVault)**

```solidity
    /// @notice Converts accumulated BNB into base-pool liquidity. Permissionless by design;
    ///         MEV protection comes from internally computed swap minOut (never caller input).
    function processRevenue() external nonReentrant {
        uint256 amount = pendingBnb;
        if (amount < minProcessAmount) revert BelowMinimumProcessAmount(amount, minProcessAmount);
        pendingBnb = 0;

        uint256 baseAmount = _toBaseToken(amount);
        _ensurePoolExists();

        IERC20(baseToken).forceApprove(address(basePool), baseAmount);
        // minAmountOut = 0: LP mint is oracle-priced upstream (no AMM spot to sandwich);
        // the swap leg in _toBaseToken carries the slippage protection.
        uint256 lpOut = basePool.deposit(poolId, baseAmount, 0, address(this), address(this));
        totalLpMinted += lpOut;

        emit RevenueProcessed(amount, baseAmount, lpOut);
    }

    /// @dev BNB → baseToken. WBNB base: pure wrap. Other bases: wrap then swap (Task 7).
    function _toBaseToken(uint256 bnbAmount) internal returns (uint256 baseAmount) {
        wbnb.deposit{value: bnbAmount}();
        if (baseToken == address(wbnb)) {
            return bnbAmount;
        }
        revert("SWAP_PATH_NOT_IMPLEMENTED"); // replaced in Task 7
    }

    function _ensurePoolExists() internal {
        PoolMetadata memory pool = poolManager.getPool(poolId);
        if (pool.basePoolToken == address(0) && pool.baseToken == address(0)) {
            poolManager.deployPool(IMyxPoolManager.DeployPoolParams({marketId: marketId, baseToken: baseToken}));
            emit PoolDeployed(poolId);
        }
    }
```

- [ ] **Step 4: Run tests to verify they pass**

Run: `forge test --match-contract MyxVaultProcessWbnbTest -v`
Expected: 4 PASS.

- [ ] **Step 5: Commit**

```bash
git add src/MyxVault.sol test/MyxVault.t.sol
git commit -m "feat: implement processRevenue wrap-and-deposit path"
```

---

### Task 6: processRevenue — auto pool deployment branch

**Files:**
- Modify: `test/MyxVault.t.sol` (append test contract)

`_ensurePoolExists` shipped in Task 5; this task locks the deploy-if-missing behavior and the market-missing failure path [D§5.4].

- [ ] **Step 1: Write the tests**

```solidity
contract MyxVaultAutoDeployPoolTest is MyxVaultTestBase {
    function _fund(uint256 amount) internal {
        vm.deal(address(this), amount);
        (bool ok,) = address(vault).call{value: amount}("");
        assertTrue(ok);
    }

    function test_processRevenue_deploysPoolWhenMissing() public {
        // no setPool() — pool does not exist yet
        _fund(1 ether);
        vault.processRevenue();
        assertEq(poolManager.deployPoolCallCount(), 1);
        assertEq(basePool.depositCallCount(), 1);
    }

    function test_processRevenue_skipsDeployWhenPoolExists() public {
        PoolMetadata memory meta;
        meta.baseToken = address(wbnb);
        meta.basePoolToken = address(lpToken);
        poolManager.setPool(MyxPoolId.derive(marketId, address(wbnb)), meta);
        _fund(1 ether);
        vault.processRevenue();
        assertEq(poolManager.deployPoolCallCount(), 0);
    }

    function test_processRevenue_marketMissing_revertsAndRetainsBnb() public {
        poolManager.setMarketExists(false);
        _fund(1 ether);
        vm.expectRevert("MockPoolManager: market missing");
        vault.processRevenue();
        assertEq(vault.pendingBnb(), 1 ether); // safely retained for retry after governance creates market
    }
}
```

- [ ] **Step 2: Run tests**

Run: `forge test --match-contract MyxVaultAutoDeployPoolTest -v`
Expected: 3 PASS (Task 5 implementation covers them; fix `MyxVault` if not).

- [ ] **Step 3: Commit**

```bash
git add test/MyxVault.t.sol
git commit -m "test: lock auto pool deployment and market-missing failure path"
```

---

### Task 7: processRevenue — swap path for non-WBNB base tokens

**Files:**
- Modify: `src/MyxVault.sol`
- Modify: `test/MyxVault.t.sol` (append test contract)

For a non-WBNB base, BNB is wrapped then swapped via Pancake. `minOut` is computed from the Chainlink base-token feed configured at vault initialization — caller input is never used [D§5.3, D§9]. The factory (Task 11) only admits base tokens that have a registered feed; tokens are required to be 18-decimals (BSC norm — WBNB/BTCB/ETH all 18), feeds 8-decimals, both enforced at factory construction.

- [ ] **Step 1: Extend InitParams and storage**

Add to `InitParams` struct (after `usdtUsdFeed`):

```solidity
        address baseTokenUsdFeed; // address(0) when baseToken == WBNB
```

Add storage variable (after `usdtUsdFeed`):

```solidity
    IAggregatorV3 public baseTokenUsdFeed;
```

Add to `initialize` (after `usdtUsdFeed` assignment):

```solidity
        baseTokenUsdFeed = IAggregatorV3(p.baseTokenUsdFeed);
```

Update the test helper `_initParams` in `MyxVaultTestBase` — add a `baseFeed` field set in swap-path tests; default `address(0)`.

- [ ] **Step 2: Write failing tests**

```solidity
contract MyxVaultProcessSwapTest is MyxVaultTestBase {
    MockAggregatorV3 baseFeed;
    MyxVault swapVault;

    function setUp() public override {
        super.setUp();
        baseFeed = new MockAggregatorV3(60_000e8, 8); // base = $60k (BTC-like)
        swapVault = new MyxVault();
        MyxVault.InitParams memory p = _initParams(address(baseToken));
        p.baseTokenUsdFeed = address(baseFeed);
        swapVault.initialize(p);
        // mock router rate: 1 WBNB ($600) = 0.01 base ($60k) → num=1, den=100
        router.setRate(1, 100);
    }

    function _fund(uint256 amount) internal {
        vm.deal(address(this), amount);
        (bool ok,) = address(swapVault).call{value: amount}("");
        assertTrue(ok);
    }

    function test_processRevenue_swapsToBaseThenDeposits() public {
        _fund(1 ether);
        swapVault.processRevenue();
        // 1 BNB → 0.01 base at fair rate; deposited into pool
        assertEq(basePool.lastDepositAmount(), 0.01 ether);
        assertEq(swapVault.pendingBnb(), 0);
    }

    function test_processRevenue_revertsWhenSwapWorseThanSlippageBound() public {
        // fair = 0.01 base/BNB; bound = 0.0097 (3%); router pays only 0.005 → must revert
        router.setRate(1, 200);
        _fund(1 ether);
        vm.expectRevert("MockRouter: INSUFFICIENT_OUTPUT_AMOUNT");
        swapVault.processRevenue();
        assertEq(swapVault.pendingBnb(), 1 ether); // retained for retry
    }

    function test_processRevenue_revertsOnStaleFeed() public {
        baseFeed.setAnswer(0);
        _fund(1 ether);
        vm.expectRevert(abi.encodeWithSelector(MyxVault.StalePrice.selector, address(baseFeed)));
        swapVault.processRevenue();
    }
}
```

- [ ] **Step 3: Run tests to verify they fail**

Run: `forge test --match-contract MyxVaultProcessSwapTest -v`
Expected: FAIL — swap path reverts with `SWAP_PATH_NOT_IMPLEMENTED`.

- [ ] **Step 4: Implement — replace `_toBaseToken` body and add helpers**

```solidity
    function _toBaseToken(uint256 bnbAmount) internal returns (uint256 baseAmount) {
        wbnb.deposit{value: bnbAmount}();
        if (baseToken == address(wbnb)) {
            return bnbAmount;
        }
        // fair amount from feeds: base = bnbAmount * (BNB/USD) / (BASE/USD); both feeds 8 dec, tokens 18 dec
        uint256 bnbUsd = _readPrice(bnbUsdFeed);
        uint256 baseUsd = _readPrice(baseTokenUsdFeed);
        uint256 fairOut = (bnbAmount * bnbUsd) / baseUsd;
        uint256 minOut = (fairOut * (BPS_DENOMINATOR - maxSlippageBps)) / BPS_DENOMINATOR;

        address[] memory path = new address[](2);
        path[0] = address(wbnb);
        path[1] = baseToken;
        IERC20(address(wbnb)).forceApprove(address(swapRouter), bnbAmount);
        uint256[] memory amounts =
            swapRouter.swapExactTokensForTokens(bnbAmount, minOut, path, address(this), block.timestamp);
        baseAmount = amounts[amounts.length - 1];
    }

    function _readPrice(IAggregatorV3 feed) internal view returns (uint256) {
        (, int256 answer,,,) = feed.latestRoundData();
        if (answer <= 0) revert StalePrice(address(feed));
        return uint256(answer);
    }
```

- [ ] **Step 5: Run all vault tests**

Run: `forge test --match-path test/MyxVault.t.sol -v`
Expected: all PASS (including earlier contracts — `_initParams` change must not break them).

- [ ] **Step 6: Commit**

```bash
git add src/MyxVault.sol test/MyxVault.t.sol
git commit -m "feat: add feed-priced swap path for non-WBNB base tokens"
```

---

### Task 8: harvest — claim rebates and forward to Dividend contract

**Files:**
- Modify: `src/MyxVault.sol`
- Modify: `test/MyxVault.t.sol` (append test contract)

Rebates arrive in quote token (USDT). Flow: claim → swap USDT→WBNB (feed-priced minOut) → approve + `deposit` into the token's Dividend contract resolved via `IFlapTaxTokenV3(taxToken).dividendContract()` [D§5.5]. **Task 0 verification point:** the `deposit(uint256)` call shape. Per design default, only rebates are forwarded; LP principal/NAV stays in the vault.

- [ ] **Step 1: Write failing tests**

```solidity
contract MyxVaultHarvestTest is MyxVaultTestBase {
    function setUp() public override {
        super.setUp();
        // USDT → WBNB at fair rate: 600 USDT = 1 WBNB → num=1, den=600
        router.setRate(1, 600);
    }

    function test_harvest_claimsSwapsAndForwards() public {
        basePool.setRebate(600 ether); // 600 USDT pending
        vault.harvest();
        // 600 USDT → 1 WBNB → forwarded to dividend
        assertEq(dividend.totalDeposited(), 1 ether);
        assertEq(vault.totalRewardsForwarded(), 1 ether);
        assertEq(usdt.balanceOf(address(vault)), 0);
    }

    function test_harvest_noRebate_noop() public {
        vault.harvest();
        assertEq(dividend.totalDeposited(), 0);
    }

    function test_harvest_badSwapRate_revertsAndRetainsUsdt() public {
        basePool.setRebate(600 ether);
        router.setRate(1, 1200); // router pays half of fair → below 3% bound
        vm.expectRevert("MockRouter: INSUFFICIENT_OUTPUT_AMOUNT");
        vault.harvest();
        // claim happened inside the reverted tx, so nothing left the vault overall
        assertEq(dividend.totalDeposited(), 0);
    }

    function test_harvest_dividendDepositFalse_reverts() public {
        // real Dividend contract returns false instead of reverting (e.g. totalShares == 0)
        basePool.setRebate(600 ether);
        dividend.setDepositSucceeds(false);
        vm.expectRevert(MyxVault.DividendDepositFailed.selector);
        vault.harvest();
        assertEq(dividend.totalDeposited(), 0);
    }
}
```

- [ ] **Step 2: Run tests to verify they fail**

Run: `forge test --match-contract MyxVaultHarvestTest -v`
Expected: FAIL — `harvest` not defined.

- [ ] **Step 3: Implement (append to MyxVault)**

```solidity
    error ZeroDividendContract();

    /// @notice Claims accumulated LP rebates and forwards them to the token's native
    ///         Dividend contract as WBNB. Permissionless; minOut is feed-priced internally.
    function harvest() external nonReentrant {
        basePool.claimUserRebate(poolId, address(this), address(this));
        // Use the full USDT balance (not just this claim's return value) so any dust left by a
        // prior dust-skipped harvest is swept once it becomes economic. The only USDT path into
        // this vault is rebate claims; forwarding it to holders is the vault's purpose.
        uint256 usdtBalance = quoteToken.balanceOf(address(this));
        if (usdtBalance == 0) return;

        // fair WBNB out = usdt * (USDT/USD) / (BNB/USD); both feeds 8 dec, tokens 18 dec
        uint256 usdtUsd = _readPrice(usdtUsdFeed);
        uint256 bnbUsd = _readPrice(bnbUsdFeed);
        uint256 fairOut = (usdtBalance * usdtUsd) / bnbUsd;
        // dust below 1 wei WBNB-equivalent would yield minOut == 0 (no slippage floor);
        // retain it in the vault until the next harvest accumulates an economic amount.
        if (fairOut == 0) return;
        uint256 minOut = (fairOut * (BPS_DENOMINATOR - maxSlippageBps)) / BPS_DENOMINATOR;

        address[] memory path = new address[](2);
        path[0] = address(quoteToken);
        path[1] = address(wbnb);
        quoteToken.forceApprove(address(swapRouter), usdtBalance);
        uint256[] memory amounts =
            swapRouter.swapExactTokensForTokens(usdtBalance, minOut, path, address(this), block.timestamp);
        uint256 wbnbOut = amounts[amounts.length - 1];

        _forwardToDividend(wbnbOut);
        totalRewardsForwarded += wbnbOut;
        emit Harvested(usdtBalance, wbnbOut);
    }

    /// @dev Verified ABI (docs/phase0-findings.md): deposit() is approve+pull and returns
    ///      false on failure WITHOUT reverting (e.g. totalShares == 0) — must be checked so
    ///      a failed forward reverts the harvest and funds stay in the vault for retry.
    function _forwardToDividend(uint256 wbnbAmount) internal {
        // Resolved live (not cached): the taxToken does not exist at initialize() time
        // (CREATE2 predicted address), so its dividendContract() cannot be read then.
        address dividendAddr = IFlapTaxTokenV3(taxToken).dividendContract();
        if (dividendAddr == address(0)) revert ZeroDividendContract();
        IERC20(address(wbnb)).forceApprove(dividendAddr, wbnbAmount);
        if (!IDividendDistributor(dividendAddr).deposit(wbnbAmount)) revert DividendDepositFailed();
    }
```

Add import at top of MyxVault.sol:

```solidity
import {IFlapTaxTokenV3} from "./flap/IFlapTaxTokenV3.sol";
```

(`MockTaxToken` already exposes `dividendContract()`; no mock change needed.)

- [ ] **Step 4: Run tests to verify they pass**

Run: `forge test --match-contract MyxVaultHarvestTest -v`
Expected: 3 PASS.

- [ ] **Step 5: Commit**

```bash
git add src/MyxVault.sol test/MyxVault.t.sol
git commit -m "feat: implement harvest with feed-priced swap and dividend forwarding"
```

---

### Task 9: Emergency functions

**Files:**
- Modify: `src/MyxVault.sol`
- Modify: `test/MyxVault.t.sol` (append test contract)

Rescue paths for MYX failure modes (pool stuck, liquidity drought) [D§5.2, D§9]. EMERGENCY_ROLE = Guardian + creator. These are the vault's only permissioned functions — keeping this set small bounds what the Guardian can do.

- [ ] **Step 1: Write failing tests**

```solidity
contract MyxVaultEmergencyTest is MyxVaultTestBase {
    function test_emergencyWithdraw_redeemsLpToRecipient() public {
        lpToken.mint(address(vault), 10 ether); // simulate held LP
        address rescue = makeAddr("rescue");
        vm.prank(GUARDIAN);
        vault.emergencyWithdraw(10 ether, 0, rescue);
        assertEq(usdt.balanceOf(rescue), 10 ether); // MockBasePool pays quote 1:1
    }

    function test_emergencyWithdraw_creatorAllowed() public {
        lpToken.mint(address(vault), 1 ether);
        vm.prank(creator);
        vault.emergencyWithdraw(1 ether, 0, creator);
    }

    function test_emergencyWithdraw_strangerReverts() public {
        vm.prank(makeAddr("stranger"));
        vm.expectRevert(); // AccessControl revert
        vault.emergencyWithdraw(1 ether, 0, makeAddr("stranger"));
    }

    function test_emergencySweepBnb() public {
        vm.deal(address(vault), 2 ether);
        address rescue = makeAddr("rescue");
        vm.prank(GUARDIAN);
        vault.emergencySweepBnb(rescue);
        assertEq(rescue.balance, 2 ether);
        assertEq(vault.pendingBnb(), 0);
    }
}
```

- [ ] **Step 2: Run tests to verify they fail**

Run: `forge test --match-contract MyxVaultEmergencyTest -v`
Expected: FAIL — functions not defined.

- [ ] **Step 3: Implement (append to MyxVault)**

```solidity
    /// @notice Redeems vault-held LP back to quote token, sent to `to`. Disaster recovery only.
    function emergencyWithdraw(uint256 lpAmount, uint256 minAmountOut, address to)
        external
        nonReentrant
        onlyRole(EMERGENCY_ROLE)
    {
        (uint256 amountOut,) = basePool.withdraw(poolId, lpAmount, minAmountOut, address(this), to);
        emit EmergencyWithdrawal(lpAmount, amountOut, to);
    }

    /// @notice Sweeps stuck native BNB. Disaster recovery only (e.g. processRevenue permanently broken).
    function emergencySweepBnb(address to) external nonReentrant onlyRole(EMERGENCY_ROLE) {
        uint256 amount = address(this).balance;
        pendingBnb = 0;
        (bool ok,) = to.call{value: amount}("");
        require(ok, "BNB_SWEEP_FAILED");
        emit EmergencySwept(amount, to);
    }
```

- [ ] **Step 4: Run tests to verify they pass**

Run: `forge test --match-contract MyxVaultEmergencyTest -v`
Expected: 4 PASS.

- [ ] **Step 5: Commit**

```bash
git add src/MyxVault.sol test/MyxVault.t.sol
git commit -m "feat: add guardian/creator emergency withdraw and bnb sweep"
```

---

### Task 10: Views, description, UI schema

**Files:**
- Modify: `src/MyxVault.sol`
- Modify: `test/MyxVault.t.sol` (append test contract)

Frontend queries [D§5.2]: `userLpShare(user)` = notional share of vault-held LP pro-rata to tax-token holdings; `pendingReward(user)` = per-holder claimable dividend (wraps the Dividend contract's `pending(address)` — Task 0 verification point); `pendingVaultRebates(price)` = vault-level claimable rebates from MYX. `description()` + `vaultUISchema()` are Flap V2 mandates. Claiming itself happens on the Flap Dividend contract directly (its native claim method — the frontend's claim button targets it, not the vault).

- [ ] **Step 1: Write failing tests**

```solidity
contract MyxVaultViewsTest is MyxVaultTestBase {
    function test_userLpShare_proRataByHolding() public {
        lpToken.mint(address(vault), 100 ether);
        address alice = makeAddr("alice");
        address bob = makeAddr("bob");
        // alice holds 30%, bob 70% of tax token supply
        deal(address(taxToken), alice, 30 ether, true);
        deal(address(taxToken), bob, 70 ether, true);
        assertEq(vault.userLpShare(alice), 30 ether);
        assertEq(vault.userLpShare(bob), 70 ether);
    }

    function test_userLpShare_zeroSupply() public {
        lpToken.mint(address(vault), 100 ether);
        assertEq(vault.userLpShare(makeAddr("nobody")), 0);
    }

    function test_pendingVaultRebates_passesThrough() public {
        basePool.setRebate(42 ether);
        (uint256 rebates,) = vault.pendingVaultRebates(1e18);
        assertEq(rebates, 42 ether);
    }

    function test_pendingReward_wrapsDividendPending() public {
        address alice = makeAddr("alice");
        dividend.setPending(alice, 5 ether);
        assertEq(vault.pendingReward(alice), 5 ether);
    }

    function test_description_nonEmpty() public view {
        assertGt(bytes(vault.description()).length, 20);
    }

    function test_vaultUISchema_describesMethods() public view {
        assertEq(vault.vaultUISchema().vaultType, "MyxVault");
        assertGt(vault.vaultUISchema().methods.length, 0);
    }
}
```

Note: `userLpShare` needs the LP token address. Add caching: the vault resolves `basePoolToken` from `poolManager.getPool(poolId)` lazily.

- [ ] **Step 2: Run tests to verify they fail**

Run: `forge test --match-contract MyxVaultViewsTest -v`
Expected: FAIL.

- [ ] **Step 3: Implement (replace the Task-3 placeholder `description`/`vaultUISchema`, append views)**

```solidity
    /// @notice Notional LP share for a tax-token holder: vaultLp * holderBalance / totalSupply.
    function userLpShare(address user) external view returns (uint256) {
        uint256 supply = IERC20(taxToken).totalSupply();
        if (supply == 0) return 0;
        address lpToken = poolManager.getPool(poolId).basePoolToken;
        if (lpToken == address(0)) return 0;
        uint256 vaultLp = IERC20(lpToken).balanceOf(address(this));
        return (vaultLp * IERC20(taxToken).balanceOf(user)) / supply;
    }

    /// @notice Vault-level claimable rebates from the MYX base pool.
    /// @param price MYX oracle price input required by pendingUserRebates upstream.
    function pendingVaultRebates(uint256 price) external view returns (uint256 rebates, uint256 genesisRebates) {
        return basePool.pendingUserRebates(poolId, address(this), price);
    }

    /// @notice Per-holder claimable dividend, read from the token's Dividend contract.
    /// @dev Verified signature (docs/phase0-findings.md): withdrawableDividends(address).
    ///      Holders claim via withdrawDividends() on the Dividend contract directly.
    function pendingReward(address user) external view returns (uint256) {
        return IDividendDistributor(IFlapTaxTokenV3(taxToken).dividendContract()).withdrawableDividends(user);
    }

    function description() public view override returns (string memory) {
        return string.concat(
            "MYX liquidity vault: converts tax revenue into MYX base-pool LP held by this vault (",
            Strings.toString(totalLpMinted),
            " LP minted cumulatively; some may have been emergency-withdrawn) and forwards harvested rebates to the token's dividend contract (",
            Strings.toString(totalRewardsForwarded),
            " WBNB forwarded). Pending BNB: ",
            Strings.toString(pendingBnb),
            ". processRevenue() and harvest() are permissionless."
        );
    }

    function vaultUISchema() public pure override returns (VaultUISchema memory schema) {
        schema.vaultType = "MyxVault";
        schema.description =
            "Tax revenue becomes MYX base-pool liquidity; LP rewards flow back to holders via the dividend contract.";
        schema.methods = new VaultMethodSchema[](5);

        schema.methods[0].name = "userLpShare";
        schema.methods[0].description = "Notional LP share for a holder, pro-rata to token balance.";
        schema.methods[0].inputs = new FieldDescriptor[](1);
        schema.methods[0].inputs[0] = FieldDescriptor("user", "address", "Holder address", 0);
        schema.methods[0].outputs = new FieldDescriptor[](1);
        schema.methods[0].outputs[0] = FieldDescriptor("share", "uint256", "Notional LP amount", 18);

        schema.methods[4].name = "pendingReward";
        schema.methods[4].description = "Claimable dividend for a holder (claim on the token's dividend contract).";
        schema.methods[4].inputs = new FieldDescriptor[](1);
        schema.methods[4].inputs[0] = FieldDescriptor("user", "address", "Holder address", 0);
        schema.methods[4].outputs = new FieldDescriptor[](1);
        schema.methods[4].outputs[0] = FieldDescriptor("amount", "uint256", "Claimable WBNB amount", 18);

        schema.methods[1].name = "pendingBnb";
        schema.methods[1].description = "Tax revenue awaiting processing.";
        schema.methods[1].outputs = new FieldDescriptor[](1);
        schema.methods[1].outputs[0] = FieldDescriptor("amount", "uint256", "BNB amount", 18);

        schema.methods[2].name = "processRevenue";
        schema.methods[2].description = "Convert pending BNB into MYX base-pool liquidity. Anyone can call.";
        schema.methods[2].isWriteMethod = true;

        schema.methods[3].name = "harvest";
        schema.methods[3].description = "Claim LP rebates and forward them to the dividend contract. Anyone can call.";
        schema.methods[3].isWriteMethod = true;
    }
```

Add imports:

```solidity
import {Strings} from "@openzeppelin/utils/Strings.sol";
import {VaultUISchema, VaultMethodSchema, FieldDescriptor} from "./flap/IVaultSchemasV1.sol";
```

(Replace the existing single-struct import from Task 3 with this widened one. Remove `virtual` from the two overridden functions if no further subclassing is intended.)

- [ ] **Step 4: Run all vault tests**

Run: `forge test --match-path test/MyxVault.t.sol -v`
Expected: all PASS.

- [ ] **Step 5: Commit**

```bash
git add src/MyxVault.sol test/MyxVault.t.sol
git commit -m "feat: add holder share views, dynamic description, and ui schema"
```

---

### Task 11: MyxVaultFactory

**Files:**
- Create: `src/MyxVaultFactory.sol`
- Create: `test/MyxVaultFactory.t.sol`

Beacon pattern per the official FreeCoinBeacon reference: factory itself is non-upgradeable (Flap verification mandate); vault implementation upgrades are Guardian-only via the beacon [D§6]. Base-token registry (token → feed) is constructor-fixed — no setters.

- [ ] **Step 1: Write failing tests**

```solidity
// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.26;

import {Test} from "forge-std/Test.sol";
import {MyxVaultFactory} from "../src/MyxVaultFactory.sol";
import {MyxVault} from "../src/MyxVault.sol";
import {MarketId} from "../src/myx/IMyxPool.sol";
import {IVaultFactoryValidationV2} from "../src/flap/IVaultFactory.sol";
import "./mocks/Mocks.sol";

contract MyxVaultFactoryTest is Test {
    MyxVaultFactory factory;
    MockWBNB wbnb;
    MockERC20 usdt;
    MockERC20 btcb;
    MockAggregatorV3 bnbFeed;
    MockAggregatorV3 usdtFeed;
    MockAggregatorV3 btcbFeed;
    MockBasePool basePool;
    MockPoolManager poolManager;
    MockPancakeRouter router;

    address constant VAULT_PORTAL = 0x90497450f2a706f1951b5bdda52B4E5d16f34C06; // BSC mainnet
    address constant GUARDIAN = 0x9e27098dcD8844bcc6287a557E0b4D09C86B8a4b;
    MarketId marketId = MarketId.wrap(bytes32(uint256(1)));

    function setUp() public {
        vm.chainId(56);
        wbnb = new MockWBNB();
        usdt = new MockERC20("Tether", "USDT");
        btcb = new MockERC20("BTCB", "BTCB");
        bnbFeed = new MockAggregatorV3(600e8, 8);
        usdtFeed = new MockAggregatorV3(1e8, 8);
        btcbFeed = new MockAggregatorV3(60_000e8, 8);
        basePool = new MockBasePool(new MockERC20("LP", "LP"), usdt);
        poolManager = new MockPoolManager();
        router = new MockPancakeRouter();

        address[] memory baseTokens = new address[](2);
        baseTokens[0] = address(wbnb);
        baseTokens[1] = address(btcb);
        address[] memory feeds = new address[](2);
        feeds[0] = address(0); // WBNB path needs no feed
        feeds[1] = address(btcbFeed);

        factory = new MyxVaultFactory(
            MyxVaultFactory.GlobalConfig({
                poolManager: address(poolManager),
                basePool: address(basePool),
                swapRouter: address(router),
                wbnb: address(wbnb),
                quoteToken: address(usdt),
                bnbUsdFeed: address(bnbFeed),
                usdtUsdFeed: address(usdtFeed),
                maxSlippageBps: 300,
                minProcessAmount: 0.1 ether,
                maxPriceStaleness: 3600
            }),
            baseTokens,
            feeds
        );
    }

    function _vaultData(address base) internal view returns (bytes memory) {
        return abi.encode(base, marketId);
    }

    function test_newVault_onlyVaultPortal() public {
        vm.expectRevert();
        factory.newVault(makeAddr("tax"), address(0), makeAddr("creator"), _vaultData(address(wbnb)));
    }

    function test_newVault_deploysInitializedProxy() public {
        vm.prank(VAULT_PORTAL);
        address vaultAddr =
            factory.newVault(makeAddr("tax"), address(0), makeAddr("creator"), _vaultData(address(wbnb)));
        MyxVault v = MyxVault(payable(vaultAddr));
        assertEq(v.taxToken(), makeAddr("tax"));
        assertEq(v.baseToken(), address(wbnb));
        assertEq(v.creator(), makeAddr("creator"));
        // cannot re-initialize
        vm.expectRevert();
        v.initialize(
            MyxVault.InitParams({
                taxToken: address(1), creator: address(1), baseToken: address(1),
                marketId: marketId, poolManager: address(1), basePool: address(1),
                swapRouter: address(1), wbnb: address(1), quoteToken: address(1),
                bnbUsdFeed: address(1), usdtUsdFeed: address(1), baseTokenUsdFeed: address(1),
                maxSlippageBps: 0, minProcessAmount: 0, maxPriceStaleness: 0
            })
        );
    }

    function test_newVault_rejectsUnsupportedBaseToken() public {
        vm.prank(VAULT_PORTAL);
        vm.expectRevert(MyxVaultFactory.UnsupportedBaseToken.selector);
        factory.newVault(makeAddr("tax"), address(0), makeAddr("creator"), _vaultData(makeAddr("junk")));
    }

    function test_isQuoteTokenSupported_onlyBnb() public view {
        assertTrue(factory.isQuoteTokenSupported(address(0)));
        assertFalse(factory.isQuoteTokenSupported(address(usdt)));
    }

    function test_validateBeforeLaunch_rejectsErc20Quote() public view {
        IVaultFactoryValidationV2.LaunchValidationDataV1 memory data;
        data.quoteToken = address(usdt);
        (bool ok, string memory reason) = factory.onBeforeLaunch(abi.encode(data));
        assertFalse(ok);
        assertGt(bytes(reason).length, 0);
    }

    function test_upgradeOnlyGuardian() public {
        address newImpl = address(new MyxVault());
        vm.expectRevert();
        factory.upgradeVaultImplementation(newImpl);
        vm.prank(GUARDIAN);
        factory.upgradeVaultImplementation(newImpl);
        assertEq(factory.beacon().implementation(), newImpl);
    }

    function test_factorySpecVersion() public view {
        assertEq(factory.factorySpecVersion(), "v2.2");
    }
}
```

Note: read the exact field list of `LaunchValidationDataV1` from `src/flap/IVaultFactory.sol` before writing the validation test — adjust struct literal construction to match it verbatim.

- [ ] **Step 2: Run tests to verify they fail**

Run: `forge test --match-path test/MyxVaultFactory.t.sol -v`
Expected: FAIL — `MyxVaultFactory` not found.

- [ ] **Step 3: Implement `src/MyxVaultFactory.sol`**

```solidity
// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.26;

import {VaultFactoryBaseV2} from "./flap/VaultFactoryBaseV2.sol";
import {IVaultFactoryValidationV2} from "./flap/IVaultFactory.sol";
import {VaultDataSchema, FieldDescriptor} from "./flap/IVaultSchemasV1.sol";
import {BeaconProxy} from "@openzeppelin/proxy/beacon/BeaconProxy.sol";
import {UpgradeableBeacon} from "@openzeppelin/proxy/beacon/UpgradeableBeacon.sol";
import {MyxVault} from "./MyxVault.sol";
import {MarketId} from "./myx/IMyxPool.sol";
import {IERC20Metadata} from "@openzeppelin/token/ERC20/extensions/IERC20Metadata.sol";

/// @title MyxVaultFactory
/// @notice Deploys MyxVault beacon proxies for the Flap VaultPortal. The factory itself is
///         non-upgradeable; vault implementation upgrades are Guardian-only via the beacon.
contract MyxVaultFactory is VaultFactoryBaseV2 {
    struct GlobalConfig {
        address poolManager;
        address basePool;
        address swapRouter;
        address wbnb;
        address quoteToken;
        address bnbUsdFeed;
        address usdtUsdFeed;
        uint16 maxSlippageBps;
        uint256 minProcessAmount;
        uint32 maxPriceStaleness;
    }

    error UnsupportedBaseToken();
    error OnlyGuardian();
    error UpgradesLocked();
    error ConfigLengthMismatch();
    error ZeroFeedForNonWbnbToken(address baseToken);
    error BaseTokenNotEighteenDecimals(address baseToken);

    event VaultCreated(address indexed vault, address indexed taxToken, address indexed creator, address baseToken);
    event VaultImplementationUpgraded(address newImplementation);
    event VaultUpgradesLocked();

    UpgradeableBeacon public immutable beacon;
    GlobalConfig public config;
    /// @dev base token => Chainlink USD feed (address(0) allowed only for WBNB). Constructor-fixed.
    mapping(address => address) public baseTokenFeeds;
    mapping(address => bool) public isSupportedBaseToken;
    bool public upgradesLocked;

    constructor(GlobalConfig memory _config, address[] memory baseTokens, address[] memory feeds) {
        if (baseTokens.length != feeds.length) revert ConfigLengthMismatch();
        config = _config;
        for (uint256 i = 0; i < baseTokens.length; i++) {
            // WBNB uses the wrap-only path (no swap, no feed); every other base token
            // is swapped via PancakeV2 and MUST have a USD feed, else processRevenue would
            // call _readPrice(address(0)) and revert forever (factory is non-upgradeable).
            if (feeds[i] == address(0) && baseTokens[i] != _config.wbnb) {
                revert ZeroFeedForNonWbnbToken(baseTokens[i]);
            }
            // All swap/LP math assumes 18-decimal base tokens (BSC norm: WBNB/BTCB/ETH all 18).
            if (IERC20Metadata(baseTokens[i]).decimals() != 18) {
                revert BaseTokenNotEighteenDecimals(baseTokens[i]);
            }
            isSupportedBaseToken[baseTokens[i]] = true;
            baseTokenFeeds[baseTokens[i]] = feeds[i];
        }
        beacon = new UpgradeableBeacon(address(new MyxVault()));
    }

    modifier onlyGuardian() {
        if (msg.sender != _getGuardian()) revert OnlyGuardian();
        _;
    }

    /// @inheritdoc VaultFactoryBaseV2
    function newVault(address taxToken, address quoteToken, address creator, bytes calldata vaultData)
        external
        override
        returns (address vault)
    {
        if (msg.sender != _getVaultPortal()) revert OnlyVaultPortal();
        if (quoteToken != address(0)) revert UnsupportedQuoteToken();

        (address baseToken, MarketId marketId) = abi.decode(vaultData, (address, MarketId));
        if (!isSupportedBaseToken[baseToken]) revert UnsupportedBaseToken();

        GlobalConfig memory c = config;
        vault = address(
            new BeaconProxy(
                address(beacon),
                abi.encodeCall(
                    MyxVault.initialize,
                    (
                        MyxVault.InitParams({
                            taxToken: taxToken,
                            creator: creator,
                            baseToken: baseToken,
                            marketId: marketId,
                            poolManager: c.poolManager,
                            basePool: c.basePool,
                            swapRouter: c.swapRouter,
                            wbnb: c.wbnb,
                            quoteToken: c.quoteToken,
                            bnbUsdFeed: c.bnbUsdFeed,
                            usdtUsdFeed: c.usdtUsdFeed,
                            baseTokenUsdFeed: baseTokenFeeds[baseToken],
                            maxSlippageBps: c.maxSlippageBps,
                            minProcessAmount: c.minProcessAmount,
                            maxPriceStaleness: c.maxPriceStaleness
                        })
                    )
                )
            )
        );
        emit VaultCreated(vault, taxToken, creator, baseToken);
    }

    error UnsupportedQuoteToken();

    function isQuoteTokenSupported(address quoteToken) external pure override returns (bool) {
        return quoteToken == address(0); // native BNB only
    }

    /// @notice Pre-launch validation hook (Flap VaultPortal calls this before token creation).
    /// @dev LIMITATION: Flap's LaunchValidationDataV1 does NOT carry vaultData, so the target
    ///      baseToken cannot be validated here. A launch with an unsupported baseToken passes
    ///      this hook but reverts later in newVault (UnsupportedBaseToken). Operators must
    ///      ensure the chosen baseToken is factory-supported before launching.
    function _validateBeforeLaunch(IVaultFactoryValidationV2.LaunchValidationDataV1 memory data)
        internal
        view
        override
        returns (bool success, string memory reason)
    {
        if (data.quoteToken != address(0)) {
            return (false, "MyxVaultFactory: only native BNB quote is supported");
        }
        return (true, "");
    }

    function vaultDataSchema() public pure override returns (VaultDataSchema memory schema) {
        schema.description = "MyxVault parameters: target base token and MYX market id.";
        schema.fields = new FieldDescriptor[](2);
        schema.fields[0] = FieldDescriptor("baseToken", "address", "Base asset for MYX liquidity (must be factory-supported)", 0);
        schema.fields[1] = FieldDescriptor("marketId", "bytes32", "MYX market identifier", 0);
        schema.isArray = false;
    }

    function upgradeVaultImplementation(address newImplementation) external onlyGuardian {
        if (upgradesLocked) revert UpgradesLocked();
        beacon.upgradeTo(newImplementation);
        emit VaultImplementationUpgraded(newImplementation);
    }

    function lockVaultUpgrades() external onlyGuardian {
        upgradesLocked = true;
        emit VaultUpgradesLocked();
    }
}
```

Note: check `VaultFactoryBaseV2`/`IVaultFactory` for whether `newVault` carries `override` against the interface and whether `OnlyVaultPortal` is inherited or must be redeclared — follow the FreeCoinBeacon reference (`/Users/simple/Documents/project/d11-myx/FlapVaultExample/src/FreeCoinBeacon.sol:183-205`) when in doubt.

- [ ] **Step 4: Run tests to verify they pass**

Run: `forge test --match-path test/MyxVaultFactory.t.sol -v`
Expected: all PASS.

- [ ] **Step 5: Run the full suite**

Run: `forge test`
Expected: all PASS.

- [ ] **Step 6: Commit**

```bash
git add src/MyxVaultFactory.sol test/MyxVaultFactory.t.sol
git commit -m "feat: add beacon-based MyxVaultFactory with guardian-only upgrades"
```

---

### Task 12: BSC fork integration test

**Files:**
- Create: `test/Integration.fork.t.sol`

End-to-end against REAL Flap contracts on a BSC mainnet fork: launch a V3 tax token through the real VaultPortal with our factory, trade to generate tax, dispatch, then run the vault pipeline. MYX side stays mocked (not deployed on BSC). This also satisfies Flap spec Rule 006 (integration test coverage). Read `.agents/skills/flap-vault-spec-checker/references/integration-test-guide.md` and `test/FlapBSCFixture.sol:29-120` (usage docs) before writing.

- [ ] **Step 1: Write the test**

```solidity
// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.26;

import {FlapBSCFixture} from "./FlapBSCFixture.sol";
import {MyxVaultFactory} from "../src/MyxVaultFactory.sol";
import {MyxVault} from "../src/MyxVault.sol";
import {MarketId} from "../src/myx/IMyxPool.sol";
import "./mocks/Mocks.sol";

contract MyxVaultForkTest is FlapBSCFixture {
    MyxVaultFactory factory;
    MockBasePool basePool;
    MockPoolManager poolManager;
    MockERC20 usdt;
    MockERC20 lpToken;

    address constant WBNB = 0xbb4CdB9CBd36B01bD1cBaEBF2De08d9173bc095c;
    address constant PANCAKE_ROUTER = 0x10ED43C718714eb63d5aA57B78B54704E256024E;
    address constant BNB_USD_FEED = 0x0567F2323251f0Aab15c8dFb1967E4e8A7D42aeE;
    address constant USDT_USD_FEED = 0xB97Ad0E74fa7d920791E90258A6E2085088b4320;

    function setUp() public {
        _forkBSCMainnet();
        usdt = new MockERC20("Tether", "USDT");
        lpToken = new MockERC20("LP", "LP");
        basePool = new MockBasePool(lpToken, usdt);
        poolManager = new MockPoolManager();

        address[] memory baseTokens = new address[](1);
        baseTokens[0] = WBNB;
        address[] memory feeds = new address[](1);
        feeds[0] = address(0);

        factory = new MyxVaultFactory(
            MyxVaultFactory.GlobalConfig({
                poolManager: address(poolManager),
                basePool: address(basePool),
                swapRouter: PANCAKE_ROUTER,
                wbnb: WBNB,
                quoteToken: address(usdt),
                bnbUsdFeed: BNB_USD_FEED,
                usdtUsdFeed: USDT_USD_FEED,
                maxSlippageBps: 300,
                minProcessAmount: 0.01 ether,
                maxPriceStaleness: 3600
            }),
            baseTokens,
            feeds
        );
    }

    function test_endToEnd_launchTradeDispatchProcess() public {
        // 1. Launch a V3 tax token through the REAL VaultPortal using our factory.
        //    Use _buildV3TaxTokenParams (FlapBSCFixture:298) with:
        //      vaultFactory = address(factory)
        //      vaultData    = abi.encode(WBNB, MarketId.wrap(bytes32(uint256(1))))
        //    and launch via the vaultPortal instance per the fixture docs (FlapBSCFixture:29-120).
        //    The exact param-struct field list comes from the fixture helper — follow its signature.
        address token = /* launch using fixture helpers */ address(0);
        // 2. Trade to generate tax revenue.
        _buyOnBC(token, 1 ether);
        _sell(token, IERC20(token).balanceOf(address(this)) / 2);
        // 3. Dispatch tax to the vault (real TaxProcessor, 1M gas cap — Rule 005 proof).
        _dispatchTax(token);
        // 4. Resolve our vault address from the VaultPortal registry / launch return value.
        MyxVault vault = MyxVault(payable(/* vault address from launch */ address(0)));
        assertGt(vault.pendingBnb(), 0, "dispatch should credit the vault through receive()");
        // 5. Run the pipeline.
        vault.processRevenue();
        assertEq(vault.pendingBnb(), 0);
        assertGt(basePool.depositCallCount(), 0);
        assertGt(lpToken.balanceOf(address(vault)), 0);
    }
}
```

The two `/* ... */` holes are deliberate: the launch-call shape depends on `_buildV3TaxTokenParams`'s struct and the vaultPortal launch method, which the implementer must read from `test/FlapBSCFixture.sol:298-355` and `src/flap/IVaultPortal.sol` at execution time (they are fixture-version-specific). Everything else is fixed.

- [ ] **Step 2: Run the fork test**

Run: `forge test --match-path test/Integration.fork.t.sol --fork-url https://bsc-dataseed.binance.org -vv`
Expected: PASS. Key assertion: `_dispatchTax` (1M gas cap) succeeds against our `receive()` — live Rule 005 compliance proof.

- [ ] **Step 3: Run the full non-fork suite to confirm no regressions**

Run: `forge test --no-match-path "test/Integration.fork.t.sol"`
Expected: all PASS.

- [ ] **Step 4: Commit**

```bash
git add test/Integration.fork.t.sol
git commit -m "test: add BSC mainnet fork end-to-end integration test"
```

---

### Task 13: Flap spec-checker compliance pass

**Files:**
- Modify: whatever the checker flags (expected: none or minor)

- [ ] **Step 1: Run the bundled spec checker skill**

Follow `.agents/skills/flap-vault-spec-checker/SKILL.md` against `src/MyxVault.sol` + `src/MyxVaultFactory.sol`. It audits Rules 001-009 (001 vault rules, 002 factory rules incl. commission recommendation, 003 fairness, 004 UI-friendliness, 005 receive gas, 006 integration tests, 009 emergency controls).

- [ ] **Step 2: Fix every Critical/High finding; document accepted Medium/Low findings in `docs/phase0-findings.md` with rationale**

Note on Rule 002 (commission): this factory intentionally takes no commission (`commissionReceiver` unset — revenue value flows to MYX liquidity instead). Record this as the rationale if flagged.

- [ ] **Step 3: Re-run checker until no Critical/High remain. Run full test suite**

Run: `forge test`
Expected: all PASS.

- [ ] **Step 4: Commit**

```bash
git add -A
git commit -m "fix: address flap spec checker findings"
```

---

### Task 14: Deployment scripts

**Files:**
- Create: `script/testnet/bnb/DeployMyxVaultFactory.s.sol`
- Create: `script/mainnet/bnb/DeployMyxVaultFactory.s.sol`

- [ ] **Step 1: Write the testnet script**

```solidity
// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.26;

import {Script, console2} from "forge-std/Script.sol";
import {MyxVaultFactory} from "../../../src/MyxVaultFactory.sol";

/// @notice Deploys MyxVaultFactory on BNB testnet (chainId 97).
///         All MYX/DEX/feed addresses come from env to avoid hardcoding unverified ones.
contract DeployMyxVaultFactory is Script {
    function run() external {
        require(block.chainid == 97, "wrong chain");
        vm.startBroadcast();
        address[] memory baseTokens = new address[](1);
        baseTokens[0] = vm.envAddress("WBNB");
        address[] memory feeds = new address[](1);
        feeds[0] = address(0);

        MyxVaultFactory factory = new MyxVaultFactory(
            MyxVaultFactory.GlobalConfig({
                poolManager: vm.envAddress("MYX_POOL_MANAGER"),
                basePool: vm.envAddress("MYX_BASE_POOL"),
                swapRouter: vm.envAddress("PANCAKE_ROUTER"),
                wbnb: vm.envAddress("WBNB"),
                quoteToken: vm.envAddress("MYX_QUOTE_TOKEN"),
                bnbUsdFeed: vm.envAddress("BNB_USD_FEED"),
                usdtUsdFeed: vm.envAddress("USDT_USD_FEED"),
                maxSlippageBps: 300,
                minProcessAmount: 0.01 ether,
                maxPriceStaleness: 3600
            }),
            baseTokens,
            feeds
        );
        console2.log("MyxVaultFactory:", address(factory));
        console2.log("Beacon:", address(factory.beacon()));
        vm.stopBroadcast();
    }
}
```

- [ ] **Step 2: Write the mainnet script** — identical structure with `require(block.chainid == 56, ...)` and `minProcessAmount: 0.1 ether`. Mainnet constants (WBNB `0xbb4C...`, router `0x10ED...`, feeds per Task 0) may be inlined since Task 0 verified them; MYX addresses stay env-driven until MYX's BSC deployment exists.

- [ ] **Step 3: Dry-run compile**

Run: `forge build`
Expected: success. (No actual deployment in this plan — deployment is a separate operational step gated on MYX BSC deployment + audit [D§8 Phase 5].)

- [ ] **Step 4: Commit**

```bash
git add script/
git commit -m "feat: add factory deployment scripts for bnb testnet and mainnet"
```

---

## Out of scope (explicitly)

- MYX BSC deployment and market creation (prerequisite, owned by MYX governance [D§7]).
- Third-party audit and factory verification on flap.sh (Phase 5 [D§8]).
- Frontend reward-claim page (calls the Flap Dividend contract's native claim; signature recorded by Task 0).
- NAV-growth extraction (design default: rebates only [D§10]).

## Execution risks to watch

1. **Task 0 may invalidate Task 8's dividend-forwarding assumption.** If the Dividend contract rejects external deposits, stop and re-plan Task 8 (fallback: vault-internal snapshot distribution — significant scope change requiring user sign-off).
2. **Fork test RPC flakiness**: pin a block with `--fork-block-number` if public-RPC instability causes nondeterminism.
3. **OZ v4.9.6 vs v5 API drift**: this repo pins v4.9.6 — `ReentrancyGuardUpgradeable` lives under `security/`, `UpgradeableBeacon` constructor takes only the implementation address. Do not copy v5-style imports from elsewhere.

---

# v3 Rework Addendum (2026-06-12)

The flow was redesigned AFTER Tasks 0-14 completed (design doc v3): tax BNB now buys back
THE TAX TOKEN ITSELF via the Flap Portal and deposits it as MYX base liquidity. The task
bodies above describe the v2 implementation as executed; this addendum records the v3 delta.
Code blocks in Tasks 5/7/11 are historical — the source of truth is the contracts themselves.

## What changed (commits c5a8b63, 446aadb, 1dc21b2, c608dee)

| Area | v2 (as executed above) | v3 (current) |
|---|---|---|
| Buy leg | wrap WBNB / Pancake swap to whitelisted base, Chainlink minOut | `IPortalTradeV2.swapExactInput{value}` BUY (0 → taxToken); minOut = same-block `quoteExactInput` × (1 - maxSlippageBps); **balance-delta accounting** (DEX-phase buys land net of transfer tax) |
| Base asset | factory-whitelisted (WBNB/BTCB + feeds, 18-dec enforced) | the tax token itself; `poolId = derive(marketId, taxToken)`; auto-deploy is the main path |
| processRevenue | permissionless | **OPERATOR_ROLE** (creator + guardian; guardian as DEFAULT_ADMIN can grant more) — the tax token has no external price feed, so a same-block quote cannot prevent sandwiches; matches VaultBase's prescribed pattern for buyback-style operations |
| harvest | unchanged | unchanged (USDT→WBNB Pancake leg keeps Chainlink staleness-checked minOut; permissionless) |
| Factory | base whitelist + feed registry + decimals guard | `vaultData = abi.encode(MarketId)` only; whitelist machinery removed; GlobalConfig unchanged |
| InitParams | 15 fields | 13 fields (baseToken, baseTokenUsdFeed removed) |

## v3 verification evidence

- **phase0-v3-findings.md**: vault→MYX pool transferFrom is UNTAXED (Flap V3 taxes only
  registered-pool counterparties; `pools` set is immutable post-initialize) — deposit leg
  needs no shortfall handling. Portal BUY lands full on the bonding curve, net on DEX phase
  → balance-delta accounting. decimals == 18 confirmed.
- **Fork e2e (real BSC)**: launch → trade → dispatch (Rule 005 live) → operator-pranked
  processRevenue executing a REAL Portal bonding-curve buyback → auto-deployPool → deposit.
  Observed: quoteExactInput == received balance delta EXACTLY (BC-phase tax is taken on the
  BNB side; quote/swap share the same basis); 5% slippage bound absorbed zero deviation.
- **Spec-checker delta audit** (docs/spec-checker-findings.md, v3 section): no Critical/High;
  Rule 003 operator-gating matches VaultBase guidance; guardian holds OPERATOR_ROLE
  irrevocably (new test `test_revokeGuardianOperatorRole_reverts`).

## Final state

- 49 non-fork tests + 1 fork e2e, all green. `forge build` clean.
- Accepted/advisory items: Rule 004 custom errors (Medium, UI ergonomics); operator txs
  should use a private relay and small batches (same-block quote bounds intra-call deviation
  only); donated tokens unsweepable without upgrade (Rule 009 proxy exception).

---

# v4 Rework Addendum (2026-06-12)

Built on top of v3. Three user-directed changes; design source of truth is
docs/flap-vault-integration-design.md §0 (v4) + the contracts.

## What changed (commits 293fdc7, 22d9641, 8f71fce, 8f0c9d4, 657678e + docs)

| Area | v3 | v4 |
|---|---|---|
| Modes | AUTO / MANUAL (default AUTO) | **TRIGGERED (default)** / AUTO / MANUAL. TRIGGERED self-schedules via Flap TriggerService callbacks; AUTO permissionless; MANUAL operator-only. processRevenue public entry: AUTO=anyone, else=OPERATOR_ROLE. harvest permissionless in all modes. |
| harvest distribution | claim USDT rebate → Pancake swap USDT→WBNB (Chainlink minOut) → Dividend.deposit(WBNB) | **claim rebate (= pool quote = the token's dividendToken) → Dividend.deposit() DIRECTLY.** No swap, no feeds. Invariant `pool.quoteToken == dividend.dividendToken()` enforced at runtime. |
| Dependencies | Portal + myx + Dividend + Pancake + Chainlink | **Portal + myx + Dividend + TriggerService** (removed swapRouter/wbnb/quoteToken/bnbUsdFeed/usdtUsdFeed/maxPriceStaleness/_readPrice/SWAP_DEADLINE). |
| Automation | manual/keeper | `trigger(uint256)` (ITriggerReceiver, Rule 008 compliant) runs harvest backstop + reschedule + conditional buyback; `scheduleTrigger()` bootstrap (gated on pool deployed); `ensurePoolDeployed()` moves heavy deployPool out of the 2M callback; trigger fee paid from pendingBnb. |
| Factory | — | `_validateBeforeLaunch` rejects native(0)/self-magic dividendToken (lightweight, no whitelist); GlobalConfig +triggerService/+triggerInterval, −feed/swap fields. |

## Verification

- 80 non-fork tests + 2 real-BSC-fork e2e (manual buyback path + **triggered path against the live TriggerService**: real getFee 0.0002 BNB, real request ids 3044→3045, callback gas 542K < 2M). All green.
- spec-checker: **Rule 008 now in-scope → PASS** (caller check, replay protection, fresh-quote re-validation, ≤2M gas via pool-deploy gate, nonReentrant). Full delta audit in docs/spec-checker-findings.md.
- Final holistic review fixed H-01 (mode switch did not wind down the trigger loop → `_runCycle` reschedule now gated on `mode == TRIGGERED`).

## Phase-0-v4 open items (network/myx-BSC required)

- ERC20(USDT) dividend `deposit(uint256)` permissionless when dividendBps>0 (verified on WBNB instances; not on USDT+dividendBps>0 combo — network hard-blocked this session).
- USDT-dividend claim pays USDT directly (inferred: unwrap only when dividendToken==weth).
- Real myx deployPool gas ≤ 2M (fork-measure once myx ships on BSC).
- myx has quote=USDT / quote=USDC markets (deployment prerequisite).
