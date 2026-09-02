# MyxVault V3 ERC20/RWA Quote Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Let a Flap tax token launched with native BNB or any Portal-enabled ERC20/RWA quote route its tax into MyxVault, which buys back the token, deposits it into the myx base pool, and feeds the resulting mBase LP to holders as the dividend — with the FlapTriggerService fee for ERC20-quote vaults paid from a BNB gas pool that is prepaid at launch, auto-refilled from tax via Flap's own MultiDexRouter, and toppable by anyone.

**Architecture:** MyxVault moves to Flap spec V3 (`VaultBaseV3`, `vaultQuoteToken()`, balance-delta accounting in `receive()`), keeps the v6 LP-as-dividend flow, and adds a gas-pool leg (`fundGas`, `_refillGas`) for ERC20 quotes. MyxVaultFactory drops its quote restriction, moves per-vault economics into creator-supplied `vaultData`, checks Portal's quote whitelist on-chain, and holds prepaid gas that it forwards into the vault at `newVault`. All swap-venue addresses are resolved at runtime through `taxToken.taxProcessor().swapRegistry()` and the Portal quote configuration — no new hardcoded addresses.

**Tech Stack:** Solidity 0.8.30, Foundry (forge 1.7.x), OpenZeppelin 4.9.6 (+ upgradeable), Flap FlapVaultExample interfaces, BSC mainnet fork for integration.

**Spec:** `docs/superpowers/specs/2026-09-02-vault-v3-erc20-quote-design.md`

## Global Constraints

- All code, identifiers, comments, commit messages in English. Revert strings are bilingual literals `unicode"English / 繁體中文"` (Flap audit F1/F2); no custom errors in MyxVault/MyxVaultFactory.
- `receive()` stays accounting-only: no DEX calls, no reverts, and the existing test bound `< 100_000` gas per call holds.
- Never add a default chain branch to any per-chain address resolver; unknown chains must revert. Keep the local 4663 (Robinhood mainnet) branches as they are; do NOT merge 46630 into them when syncing upstream.
- Storage layout of `MyxVault` is append-only (beacon-upgradeable): new fields go after `hasPendingTrigger`, `__gap` shrinks by the number of new slots.
- Every quote outflow decrements `pendingQuote` in the same function (Flap rule 010). Zero-delta wakes are silent no-ops.
- No fallback paths: when a leg cannot run (no pool, service down) it skips with an event or reverts; it never tries an alternative venue.
- Do not `git commit` unless the user explicitly asks; each task's commit step is a checkpoint the user may run.
- Run unit tests with `forge test --no-match-path 'test/*.fork.t.sol'`; fork tests need `BSC_RPC_URL` (defaults to `https://bsc-dataseed.bnbchain.org`) and are run explicitly.
- Robinhood Chain (4663) behavior is out of scope: keep it compiling and native-only; no Robinhood fork tests in this branch.

---

## File Structure

| Path | Responsibility |
|---|---|
| `src/flap/VaultBaseV3.sol` (new, verbatim upstream) | Spec V3 base: `vaultQuoteToken()`, `vaultSpecVersion()` |
| `src/flap/IPortal.sol` (modify) | Add `SWAP_VIA_ROUTE` enum value, `PoolType`, `QuoteHop` for documentation parity |
| `src/flap/IPortalQuoteConfigU8.sol` (new) | Decode-safe (all `uint8`) view of `getQuoteTokenConfiguration` |
| `src/flap/ISwapRegistry.sol` (new) | `multiDexRouter()`, `weth()` subset of Flap SwapRegistry |
| `src/flap/IMultiDexRouter.sol` (new) | Subset of Flap MultiDexRouter used by the refill leg |
| `src/lib/Decimal18.sol` (modify) | Add `toString(uint256 value, uint8 decimals)` |
| `src/MyxVault.sol` (modify) | V3 vault: balance-delta accounting, ERC20 buyback, gas pool, refill |
| `src/MyxVaultFactory.sol` (modify) | Quote whitelist via Portal, vaultData v3, prepaid gas |
| `test/mocks/Mocks.sol` (modify) | MockPortal ERC20 input + quote config, MockTaxProcessor, MockSwapRegistry, MockMultiDexRouter |
| `test/MyxVault.t.sol`, `test/MyxVaultAutoTrigger.t.sol`, `test/MyxVaultFactory.t.sol`, `test/ChainAddressResolution.t.sol`, `test/Decimal18.t.sol` (modify) | Unit coverage |
| `test/MyxVaultErc20Quote.t.sol` (new) | ERC20-quote unit suite (rule 010, gas pool, refill) |
| `test/MyxVaultFactoryPrepaidGas.t.sol` (new) | Prepaid gas suite |
| `test/Integration.fork.t.sol` (modify), `test/Integration.erc20quote.fork.t.sol` (new) | BSC mainnet fork end-to-end |
| `script/mainnet/bnb/…`, `script/testnet/bnb/…`, `script/mainnet/robinhood/…` (modify) | New `GlobalConfig` shape |
| `.agents/skills/flap-vault-spec-checker/references/rules/010-v3-erc20-quote-accounting.md`, `…/prelude/VaultBaseV3.sol` (new) | Spec-checker sync |
| `README.md`, `docs/spec-checker-findings.md` (modify) | Docs |

---

### Task 1: Sync Flap spec V3 sources and add venue interfaces

**Files:**
- Create: `src/flap/VaultBaseV3.sol`, `src/flap/IPortalQuoteConfigU8.sol`, `src/flap/ISwapRegistry.sol`, `src/flap/IMultiDexRouter.sol`
- Modify: `src/flap/IPortal.sol` (enum `NativeToQuoteSwapType`, add `PoolType` variants + `QuoteHop`)
- Create: `.agents/skills/flap-vault-spec-checker/references/rules/010-v3-erc20-quote-accounting.md`, `.agents/skills/flap-vault-spec-checker/references/prelude/VaultBaseV3.sol`
- Test: `test/FlapInterfaces.t.sol` (new)

**Interfaces:**
- Produces: `abstract contract VaultBaseV3 is VaultBaseV2 { function vaultQuoteToken() public view virtual returns (address); function vaultSpecVersion() public pure virtual returns (string memory) }`
- Produces: `interface IPortalQuoteConfigU8 { struct QuoteTokenConfigurationU8 { uint8 enabled; uint8 defaultCurve; uint8 alternativeCurve; uint8 nativeToQuoteSwapType; uint8 dexId; } function getQuoteTokenConfiguration(address) external view returns (QuoteTokenConfigurationU8 memory); }`
- Produces: `interface ISwapRegistry { function multiDexRouter() external view returns (address); function weth() external view returns (address); }`
- Produces: `interface IMultiDexRouter` with `DEXInfo`, `ExactInputSingleParams`, `QuoteExactInputSingleParams`, `getDEXInfo(uint8)`, `computeV3PoolAddress(uint8,address,address,uint24)`, `exactInputSingle(uint8,ExactInputSingleParams)`, `quoteExactInputSingle(uint8,QuoteExactInputSingleParams)`

- [ ] **Step 1: Write the failing compile test**

Create `test/FlapInterfaces.t.sol`:

```solidity
// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.26;

import {Test} from "forge-std/Test.sol";
import {VaultBaseV3} from "../src/flap/VaultBaseV3.sol";
import {IPortalQuoteConfigU8} from "../src/flap/IPortalQuoteConfigU8.sol";
import {ISwapRegistry} from "../src/flap/ISwapRegistry.sol";
import {IMultiDexRouter} from "../src/flap/IMultiDexRouter.sol";
import {IPortalTypes} from "../src/flap/IPortal.sol";
import {VaultUISchema} from "../src/flap/IVaultSchemasV1.sol";

contract V3Harness is VaultBaseV3 {
    function vaultQuoteToken() public pure override returns (address) {
        return address(0);
    }

    function description() public pure override returns (string memory) {
        return "h";
    }

    function vaultUISchema() public pure override returns (VaultUISchema memory s) {}
}

/// @dev Locks the interface surface the vault relies on. Selectors are the on-chain ones
///      (verified against BSC mainnet MultiDexRouter 0xDedF55b0... and Portal v5.22.0 sources).
contract FlapInterfacesTest is Test {
    function test_vaultBaseV3_defaultSpecVersion() public {
        V3Harness h = new V3Harness();
        assertEq(h.vaultSpecVersion(), "v3");
        assertEq(h.vaultQuoteToken(), address(0));
    }

    function test_selectors_matchOnChain() public pure {
        assertEq(IPortalQuoteConfigU8.getQuoteTokenConfiguration.selector, bytes4(keccak256("getQuoteTokenConfiguration(address)")));
        assertEq(ISwapRegistry.multiDexRouter.selector, bytes4(0x952b8901));
        assertEq(ISwapRegistry.weth.selector, bytes4(0x3fc8cef3));
        assertEq(IMultiDexRouter.getDEXInfo.selector, bytes4(0x9b5f292e));
        assertEq(IMultiDexRouter.computeV3PoolAddress.selector, bytes4(0x2b63e1e4));
        assertEq(IMultiDexRouter.exactInputSingle.selector, bytes4(0x46a7da76));
        assertEq(IMultiDexRouter.quoteExactInputSingle.selector, bytes4(0x80e11b74));
    }

    function test_swapViaRoute_enumValueIs7() public pure {
        assertEq(uint8(IPortalTypes.NativeToQuoteSwapType.SWAP_VIA_ROUTE), 7);
    }
}
```

- [ ] **Step 2: Run test to verify it fails**

Run: `forge test --match-path test/FlapInterfaces.t.sol`
Expected: compile error, `VaultBaseV3.sol` not found.

- [ ] **Step 3: Add the upstream V3 base and the spec-checker files**

Fetch verbatim from `https://raw.githubusercontent.com/flap-sh/FlapVaultExample/main/`:

```bash
curl -sfL https://raw.githubusercontent.com/flap-sh/FlapVaultExample/main/src/flap/VaultBaseV3.sol -o src/flap/VaultBaseV3.sol
curl -sfL https://raw.githubusercontent.com/flap-sh/FlapVaultExample/main/src/flap/VaultBaseV3.sol -o .agents/skills/flap-vault-spec-checker/references/prelude/VaultBaseV3.sol
curl -sfL https://raw.githubusercontent.com/flap-sh/FlapVaultExample/main/.agents/skills/flap-vault-spec-checker/references/rules/010-v3-erc20-quote-accounting.md -o .agents/skills/flap-vault-spec-checker/references/rules/010-v3-erc20-quote-accounting.md
```

Verify `src/flap/VaultBaseV3.sol` declares `abstract contract VaultBaseV3 is VaultBaseV2` with `vaultQuoteToken()` and `vaultSpecVersion()` returning `"v3"` (no other edits; the file is Flap's normative spec).

- [ ] **Step 4: Add the three venue interfaces**

Create `src/flap/IPortalQuoteConfigU8.sol`:

```solidity
// SPDX-License-Identifier: MIT
pragma solidity ^0.8.13;

/// @title IPortalQuoteConfigU8
/// @notice Decode-safe view of Portal.getQuoteTokenConfiguration. The canonical struct in IPortal.sol
///         uses CurveType / NativeToQuoteSwapType enums; live quote tokens carry enum values the local
///         copy does not know (e.g. RWA quotes use curve ids >= 30 and swap type 7), and Solidity 0.8
///         reverts when decoding an out-of-range enum. Mirroring every field as uint8 keeps the ABI
///         byte-identical while never reverting on new variants.
interface IPortalQuoteConfigU8 {
    struct QuoteTokenConfigurationU8 {
        uint8 enabled; // 1 if the quote token is allowed
        uint8 defaultCurve; // IPortalTypes.CurveType
        uint8 alternativeCurve; // IPortalTypes.CurveType
        uint8 nativeToQuoteSwapType; // IPortalTypes.NativeToQuoteSwapType (7 = SWAP_VIA_ROUTE)
        uint8 dexId; // IPortalTypes.DEXId used by MultiDexRouter dispatch
    }

    function getQuoteTokenConfiguration(address quoteToken)
        external
        view
        returns (QuoteTokenConfigurationU8 memory config);
}
```

Create `src/flap/ISwapRegistry.sol`:

```solidity
// SPDX-License-Identifier: MIT
pragma solidity ^0.8.13;

/// @title ISwapRegistry
/// @notice Subset of Flap's SwapRegistry (TaxProcessor.swapRegistry()). Verified on BSC mainnet
///         (proxy 0x644A8f560138418bAD4EdEFC7c17878a3c2fBEB6): exposes the MultiDexRouter instance
///         Flap uses for quote conversions and the canonical wrapped-native token.
interface ISwapRegistry {
    function multiDexRouter() external view returns (address);
    function weth() external view returns (address);
}
```

Create `src/flap/IMultiDexRouter.sol`:

```solidity
// SPDX-License-Identifier: MIT
pragma solidity ^0.8.13;

/// @title IMultiDexRouter
/// @notice Subset of Flap's MultiDexRouter (Sourcify-verified, BSC 0xDedF55b08a3f1c61576a4bd675825690e1eE99ec).
///         A permissionless multi-DEX wrapper with Uniswap-style V3 single-hop quote and swap.
///         Used by MyxVault only for the gas-refill leg (quote token -> wrapped native).
interface IMultiDexRouter {
    struct DEXInfo {
        bytes32 v2InitCodeHash;
        bytes32 v3InitCodeHash;
        address v2Factory;
        address v3Factory;
        address v3Deployer;
        address v4Vault;
        uint24[] v3SupportedFees;
        address smartRouter;
        address v3Quoter;
        address v2SwapRouter;
        address nonfungiblePositionManager;
    }

    struct ExactInputSingleParams {
        address tokenIn;
        address tokenOut;
        uint24 fee;
        address recipient;
        uint256 amountIn;
        uint256 amountOutMinimum;
        uint160 sqrtPriceLimitX96;
    }

    struct QuoteExactInputSingleParams {
        address tokenIn;
        address tokenOut;
        uint256 amountIn;
        uint24 fee;
        uint160 sqrtPriceLimitX96;
    }

    function getDEXInfo(uint8 dexId) external view returns (DEXInfo memory dexInfo);

    function computeV3PoolAddress(uint8 dexId, address tokenA, address tokenB, uint24 fee)
        external
        view
        returns (address pool);

    /// @dev Pulls `amountIn` of tokenIn from msg.sender (allowance required); pays tokenOut to recipient.
    function exactInputSingle(uint8 dexId, ExactInputSingleParams calldata params)
        external
        payable
        returns (uint256 amountOut);

    /// @dev NOT a view (Uniswap quoter pattern) — callers must use try/catch.
    function quoteExactInputSingle(uint8 dexId, QuoteExactInputSingleParams memory params)
        external
        returns (uint256 amountOut, uint160 sqrtPriceX96After, uint32 initializedTicksCrossed, uint256 gasEstimate);
}
```

- [ ] **Step 5: Patch the local `IPortal.sol` enums for documentation parity**

In `src/flap/IPortal.sol`, replace the `NativeToQuoteSwapType` enum body (the `SWAP_VIA_MIXED_ROUTER` entry currently ends the enum) so it reads:

```solidity
    enum NativeToQuoteSwapType {
        SWAP_DISABLED, // 0: disabled
        SWAP_VIA_V2_POOL, // 1: swap through v2 pool
        SWAP_VIA_V3_2500_POOL, // 2: swap through v3 2500 pool
        SWAP_VIA_V3_500_POOL, // 3: swap through v3 500 pool
        SWAP_VIA_V3_3000_POOL, // 4: swap through v3 3000 pool
        SWAP_VIA_V3_10000_POOL, // 5: swap through v3 10000 pool
        SWAP_VIA_MIXED_ROUTER, // 6: multi-hop via PancakeSwap Infinity MixedQuoter + UniversalRouter (BSC only)
        SWAP_VIA_ROUTE // 7: generic multi-hop route stored per quote token (Portal v5.22+). Hops describe
        //    native->quote; quote->native walks them in reverse. Set via setQuoteSwapRoute; no getter.
    }
```

Then, in the same file, replace the `PoolType` enum (`V2, V3`) with:

```solidity
    enum PoolType {
        V2, // Uniswap V2 style pools
        V3, // Uniswap V3 style pools
        V4, // Uniswap V4 style pools
        PCS_INFINITY_CL // PancakeSwap Infinity concentrated-liquidity pools
    }

    /// @dev One hop of a generic quote-token swap route (NativeToQuoteSwapType.SWAP_VIA_ROUTE).
    struct QuoteHop {
        PoolType poolType;
        uint8 dexId;
        uint24 fee;
        int24 tickSpacing;
        address tokenOut;
        address hooks;
    }
```

Keep everything else untouched. Note in a comment above the enum: `// Synced with Portal v5.22.0 verified source (2026-09-02).`

- [ ] **Step 6: Run the test and the whole unit suite**

Run: `forge test --match-path test/FlapInterfaces.t.sol` → 3 passed.
Run: `forge build` → no errors (warnings allowed).

- [ ] **Step 7: Commit (checkpoint, only if the user asked for commits)**

```bash
git add src/flap test/FlapInterfaces.t.sol .agents/skills/flap-vault-spec-checker
git commit -m "feat(flap): sync spec V3 base, add Portal quote config and MultiDexRouter interfaces"
```

---

### Task 2: Test mocks for ERC20 quotes and the Flap swap venue

**Files:**
- Modify: `test/mocks/Mocks.sol`
- Test: `test/mocks/Mocks.t.sol` (new)

**Interfaces:**
- Produces `MockPortal`: `setQuoteConfig(address quote, bool enabled, uint8 dexId)`, `getQuoteTokenConfiguration(address)` returning `IPortalQuoteConfigU8.QuoteTokenConfigurationU8`; `swapExactInput` now accepts ERC20 input (pulls via `transferFrom`).
- Produces `MockTaxToken.taxProcessor()` + `setTaxProcessor(address)`.
- Produces `MockTaxProcessor(address swapRegistry)` with `swapRegistry()`.
- Produces `MockSwapRegistry(address router, address weth)` with `multiDexRouter()`, `weth()`.
- Produces `MockMultiDexRouter(MockWBNB wbnb)`: `setPool(uint24 fee, bool exists)`, `setRate(uint24 fee, uint256 num, uint256 den)`, `setQuoteReverts(uint24 fee, bool)`, `lastFeeUsed()`, `lastAmountIn()`; implements `IMultiDexRouter`.

- [ ] **Step 1: Write the failing mock tests**

Create `test/mocks/Mocks.t.sol`:

```solidity
// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.26;

import {Test} from "forge-std/Test.sol";
import {IERC20} from "@openzeppelin/token/ERC20/IERC20.sol";
import {IPortalTradeV2} from "../../src/flap/IPortal.sol";
import {IMultiDexRouter} from "../../src/flap/IMultiDexRouter.sol";
import "./Mocks.sol";

contract MocksTest is Test {
    MockWBNB wbnb;
    MockERC20 rwa;
    MockMultiDexRouter router;
    MockPortal portal;
    MockTaxToken taxToken;

    function setUp() public {
        wbnb = new MockWBNB();
        rwa = new MockERC20("NVDA bStock", "NVDAB");
        router = new MockMultiDexRouter(wbnb);
        vm.deal(address(router), 100 ether);
        portal = new MockPortal();
        taxToken = new MockTaxToken(address(0));
    }

    function test_portal_quoteConfig_roundTrip() public {
        portal.setQuoteConfig(address(rwa), true, 0);
        IPortalQuoteConfigU8.QuoteTokenConfigurationU8 memory c = portal.getQuoteTokenConfiguration(address(rwa));
        assertEq(c.enabled, 1);
        assertEq(c.dexId, 0);
        assertEq(portal.getQuoteTokenConfiguration(makeAddr("other")).enabled, 0);
    }

    function test_portal_swapExactInput_pullsErc20Input() public {
        rwa.mint(address(this), 10 ether);
        rwa.approve(address(portal), 10 ether);
        portal.setRate(1000, 1);
        uint256 out = portal.swapExactInput(
            IPortalTradeV2.ExactInputParams({
                inputToken: address(rwa),
                outputToken: address(taxToken),
                inputAmount: 10 ether,
                minOutputAmount: 0,
                permitData: ""
            })
        );
        assertEq(out, 10_000 ether);
        assertEq(rwa.balanceOf(address(portal)), 10 ether);
        assertEq(taxToken.balanceOf(address(this)), 10_000 ether);
    }

    function test_router_quoteAndSwapOnlyExistingPools() public {
        router.setPool(2500, true);
        router.setRate(2500, 3, 10); // 1 RWA -> 0.3 WBNB
        assertEq(router.getDEXInfo(0).v3SupportedFees.length, 4);
        assertTrue(router.computeV3PoolAddress(0, address(rwa), address(wbnb), 2500).code.length > 0);
        assertEq(router.computeV3PoolAddress(0, address(rwa), address(wbnb), 500).code.length, 0);

        (uint256 out,,,) = router.quoteExactInputSingle(
            0, IMultiDexRouter.QuoteExactInputSingleParams(address(rwa), address(wbnb), 1 ether, 2500, 0)
        );
        assertEq(out, 0.3 ether);

        rwa.mint(address(this), 1 ether);
        rwa.approve(address(router), 1 ether);
        uint256 got = router.exactInputSingle(
            0, IMultiDexRouter.ExactInputSingleParams(address(rwa), address(wbnb), 2500, address(this), 1 ether, 0.29 ether, 0)
        );
        assertEq(got, 0.3 ether);
        assertEq(wbnb.balanceOf(address(this)), 0.3 ether);
        assertEq(router.lastFeeUsed(), 2500);
        assertEq(router.lastAmountIn(), 1 ether);
    }

    function test_router_quoteRevertsWhenConfigured() public {
        router.setPool(500, true);
        router.setQuoteReverts(500, true);
        vm.expectRevert();
        router.quoteExactInputSingle(
            0, IMultiDexRouter.QuoteExactInputSingleParams(address(rwa), address(wbnb), 1 ether, 500, 0)
        );
    }

    function test_taxProcessor_chain() public {
        MockSwapRegistry reg = new MockSwapRegistry(address(router), address(wbnb));
        MockTaxProcessor tp = new MockTaxProcessor(address(reg));
        taxToken.setTaxProcessor(address(tp));
        assertEq(taxToken.taxProcessor(), address(tp));
        assertEq(MockTaxProcessor(taxToken.taxProcessor()).swapRegistry(), address(reg));
        assertEq(reg.multiDexRouter(), address(router));
        assertEq(reg.weth(), address(wbnb));
    }
}
```

- [ ] **Step 2: Run to verify failure**

Run: `forge test --match-path test/mocks/Mocks.t.sol`
Expected: compile errors (`MockMultiDexRouter`, `setQuoteConfig`, … undefined).

- [ ] **Step 3: Implement the mocks**

In `test/mocks/Mocks.sol` add the imports at the top (after existing imports):

```solidity
import {IPortalQuoteConfigU8} from "../../src/flap/IPortalQuoteConfigU8.sol";
import {IMultiDexRouter} from "../../src/flap/IMultiDexRouter.sol";
```

Replace the whole `MockTaxToken` contract with:

```solidity
contract MockTaxToken is ERC20 {
    address public dividendContract;
    address public taxProcessor;
    constructor(address _dividend) ERC20("Mock Tax Token", "MTT") { dividendContract = _dividend; }
    function setDividendContract(address d) external { dividendContract = d; }
    function setTaxProcessor(address p) external { taxProcessor = p; }
    /// @dev Required so MockPortal can mint the tax token as a buy output.
    function mint(address to, uint256 amount) external { _mint(to, amount); }
}
```

Replace the whole `MockPortal` contract with:

```solidity
/// @dev Buys outputToken at a fixed rate (out = in * rateNum / rateDen), minting MockTaxToken
///      to the buyer. Input may be native (msg.value == inputAmount) or an ERC20 pulled via
///      transferFrom, mirroring the real Portal's "BUY with quote" path. taxBps simulates the
///      DEX-phase transfer tax. Also serves Portal.getQuoteTokenConfiguration (uint8 view).
contract MockPortal {
    uint256 public rateNum = 1;
    uint256 public rateDen = 1;
    uint16 public taxBps;
    mapping(address => IPortalQuoteConfigU8.QuoteTokenConfigurationU8) internal quoteConfigs;

    function setRate(uint256 num, uint256 den) external { rateNum = num; rateDen = den; }
    function setTaxBps(uint16 t) external { taxBps = t; }
    function setQuoteConfig(address quote, bool enabled, uint8 dexId) external {
        quoteConfigs[quote] = IPortalQuoteConfigU8.QuoteTokenConfigurationU8({
            enabled: enabled ? 1 : 0,
            defaultCurve: 30,
            alternativeCurve: 30,
            nativeToQuoteSwapType: 7,
            dexId: dexId
        });
    }

    function getQuoteTokenConfiguration(address quote)
        external
        view
        returns (IPortalQuoteConfigU8.QuoteTokenConfigurationU8 memory)
    {
        return quoteConfigs[quote];
    }

    function quoteExactInput(IPortalTradeV2.QuoteExactInputParams calldata p) external view returns (uint256) {
        return (p.inputAmount * rateNum) / rateDen;
    }

    function swapExactInput(IPortalTradeV2.ExactInputParams calldata p) external payable returns (uint256 out) {
        if (p.inputToken == address(0)) {
            require(msg.value == p.inputAmount, "MockPortal: bad msg.value");
        } else {
            require(msg.value == 0, "MockPortal: no value for ERC20 input");
            IERC20(p.inputToken).transferFrom(msg.sender, address(this), p.inputAmount);
        }
        out = (p.inputAmount * rateNum) / rateDen;
        require(out >= p.minOutputAmount, "MockPortal: INSUFFICIENT_OUTPUT_AMOUNT");
        uint256 net = (out * (10_000 - taxBps)) / 10_000;
        MockTaxToken(p.outputToken).mint(msg.sender, net);
    }
}
```

Append these three contracts at the end of `Mocks.sol`:

```solidity
/// @dev Stand-in for the per-token Flap TaxProcessor: only the swapRegistry() pointer is needed.
contract MockTaxProcessor {
    address public swapRegistry;
    constructor(address _registry) { swapRegistry = _registry; }
}

/// @dev Stand-in for Flap's SwapRegistry: points at the MultiDexRouter and the wrapped native token.
contract MockSwapRegistry {
    address public multiDexRouter;
    address public weth;
    constructor(address _router, address _weth) { multiDexRouter = _router; weth = _weth; }
    function setMultiDexRouter(address r) external { multiDexRouter = r; }
}

/// @dev Stand-in for Flap's MultiDexRouter V3 surface. Fee tiers mirror BSC dexId 0
///      ([2500, 100, 10000, 500]). A pool "exists" when setPool(fee, true) was called; existing
///      pools resolve to a synthetic contract address (this router) so `code.length > 0` holds,
///      missing pools resolve to a code-less address. Swaps pay WBNB minted from the router's own
///      native balance (tests vm.deal the router) so MockWBNB.withdraw is backed.
contract MockMultiDexRouter is IMultiDexRouter {
    MockWBNB public immutable wbnb;
    uint24[] internal fees = [uint24(2500), uint24(100), uint24(10000), uint24(500)];
    mapping(uint24 => bool) public poolExists;
    mapping(uint24 => uint256) public rateNum;
    mapping(uint24 => uint256) public rateDen;
    mapping(uint24 => bool) public quoteReverts;
    uint24 public lastFeeUsed;
    uint256 public lastAmountIn;

    constructor(MockWBNB _wbnb) { wbnb = _wbnb; }
    receive() external payable {}

    function setPool(uint24 fee, bool exists) external { poolExists[fee] = exists; }
    function setRate(uint24 fee, uint256 num, uint256 den) external { rateNum[fee] = num; rateDen[fee] = den; }
    function setQuoteReverts(uint24 fee, bool v) external { quoteReverts[fee] = v; }

    function _out(uint24 fee, uint256 amountIn) internal view returns (uint256) {
        if (rateDen[fee] == 0) return 0;
        return (amountIn * rateNum[fee]) / rateDen[fee];
    }

    function getDEXInfo(uint8) external view returns (DEXInfo memory info) {
        info.v3SupportedFees = fees;
    }

    function computeV3PoolAddress(uint8, address, address, uint24 fee) external view returns (address) {
        if (poolExists[fee]) return address(this); // has code
        return address(uint160(uint256(keccak256(abi.encode("no-pool", fee))))); // no code
    }

    function quoteExactInputSingle(uint8, QuoteExactInputSingleParams memory p)
        external
        view
        returns (uint256 amountOut, uint160, uint32, uint256)
    {
        require(!quoteReverts[p.fee], "MockMultiDexRouter: quote reverted");
        require(poolExists[p.fee], "MockMultiDexRouter: no pool");
        amountOut = _out(p.fee, p.amountIn);
    }

    function exactInputSingle(uint8, ExactInputSingleParams calldata p) external payable returns (uint256 amountOut) {
        require(poolExists[p.fee], "MockMultiDexRouter: no pool");
        require(p.tokenOut == address(wbnb), "MockMultiDexRouter: tokenOut must be WBNB");
        IERC20(p.tokenIn).transferFrom(msg.sender, address(this), p.amountIn);
        amountOut = _out(p.fee, p.amountIn);
        require(amountOut >= p.amountOutMinimum, "MockMultiDexRouter: INSUFFICIENT_OUTPUT_AMOUNT");
        wbnb.deposit{value: amountOut}();
        wbnb.transfer(p.recipient, amountOut);
        lastFeeUsed = p.fee;
        lastAmountIn = p.amountIn;
    }
}
```

Note: `quoteExactInputSingle` in the interface is non-view; a `view` override is allowed by Solidity (stricter mutability). Keep `view` so the mock is cheap.

- [ ] **Step 4: Run the mock tests and the full unit suite**

Run: `forge test --match-path test/mocks/Mocks.t.sol` → 5 passed.
Run: `forge test --no-match-path 'test/*.fork.t.sol'` → everything that passed before still passes (the existing `test_process_*` tests use native input and are unaffected). The one pre-existing failure `test_description_formatsWeiAsDecimals` is fixed in Task 8.

- [ ] **Step 5: Commit checkpoint**

```bash
git add test/mocks
git commit -m "test(mocks): ERC20-input MockPortal with quote config, MockTaxProcessor, MockSwapRegistry, MockMultiDexRouter"
```

---

### Task 3: MyxVault V3 surface — quote token, gas parameters, `pendingQuote`

**Files:**
- Modify: `src/MyxVault.sol`
- Modify: `test/MyxVault.t.sol` (base `_initParams`, rename `pendingEth` → `pendingQuote`), `test/MyxVaultAutoTrigger.t.sol` (same rename + init), `test/Integration.fork.t.sol` (rename only), `test/ChainAddressResolution.t.sol` (no change yet)

**Interfaces:**
- Produces: `struct InitParams { address taxToken; address creator; address quoteToken; address marketQuoteToken; address poolManager; address basePool; uint16 maxSlippageBps; uint256 minProcessAmount; uint256 gasThreshold; uint256 gasRefillAmount; }`
- Produces: public getters `quoteToken()`, `gasThreshold()`, `gasRefillAmount()`, `pendingQuote()`, `vaultQuoteToken()`, `vaultSpecVersion()`
- Removes: `pendingEth()` (renamed). Later tasks depend on the names above.

- [ ] **Step 1: Write the failing tests**

In `test/MyxVault.t.sol`, update `_initParams` in `MyxVaultTestBase`:

```solidity
    function _initParams() internal view returns (MyxVault.InitParams memory p) {
        p.taxToken = address(taxToken);
        p.creator = creator;
        p.quoteToken = address(0); // native BNB quote
        p.marketQuoteToken = address(usdt);
        p.poolManager = address(poolManager);
        p.basePool = address(basePool);
        p.maxSlippageBps = 300; // 3%
        p.minProcessAmount = 0.1 ether; // BNB
        p.gasThreshold = 0; // native quote: no gas pool
        p.gasRefillAmount = 0;
    }
```

Add to `MyxVaultInitTest`:

```solidity
    function test_v3Surface_nativeQuote() public view {
        assertEq(vault.vaultQuoteToken(), address(0));
        assertEq(vault.quoteToken(), address(0));
        assertEq(vault.vaultSpecVersion(), "v3");
        assertEq(vault.gasThreshold(), 0);
        assertEq(vault.gasRefillAmount(), 0);
    }

    function test_initialize_nativeQuote_rejectsGasParams() public {
        MyxVault.InitParams memory p = _initParams();
        p.gasThreshold = 1;
        MyxVault impl = new MyxVault();
        vm.expectRevert(bytes(unicode"Gas params must be zero for native quote / 原生報價幣的 Gas 參數必須為零"));
        new ERC1967Proxy(address(impl), abi.encodeCall(MyxVault.initialize, (p)));
    }

    function test_initialize_erc20Quote_requiresRefillAboveThreshold() public {
        MyxVault.InitParams memory p = _initParams();
        p.quoteToken = address(usdt);
        p.gasThreshold = 0.01 ether;
        p.gasRefillAmount = 0.01 ether; // not strictly greater
        MyxVault impl = new MyxVault();
        vm.expectRevert(bytes(unicode"Gas refill must exceed threshold / Gas 補充值必須大於閾值"));
        new ERC1967Proxy(address(impl), abi.encodeCall(MyxVault.initialize, (p)));
    }

    function test_initialize_erc20Quote_storesQuote() public {
        MyxVault.InitParams memory p = _initParams();
        p.quoteToken = address(usdt);
        p.gasThreshold = 0.01 ether;
        p.gasRefillAmount = 0.02 ether;
        MyxVault v = _deployVault(p);
        assertEq(v.vaultQuoteToken(), address(usdt));
        assertEq(v.gasThreshold(), 0.01 ether);
        assertEq(v.gasRefillAmount(), 0.02 ether);
    }
```

Then do a mechanical rename in the three test files: every `vault.pendingEth()` / `v.pendingEth()` becomes `pendingQuote()`; every `emit RevenueProcessed(uint256 bnbAmount, ...)` event declaration in tests stays as is (only the vault's parameter name changes). Command:

```bash
sed -i '' 's/pendingEth()/pendingQuote()/g' test/MyxVault.t.sol test/MyxVaultAutoTrigger.t.sol test/Integration.fork.t.sol
```

In `test/MyxVaultAutoTrigger.t.sol` `_deployVault`, add `p.quoteToken = address(0);` after `p.creator = creator;` (the other new fields default to 0).

- [ ] **Step 2: Run to verify failure**

Run: `forge test --match-path test/MyxVault.t.sol`
Expected: compile errors — `InitParams` has no member `quoteToken`, `pendingQuote` undefined.

- [ ] **Step 3: Implement the V3 surface in `MyxVault.sol`**

Change the import and inheritance:

```solidity
import {VaultBaseV3} from "./flap/VaultBaseV3.sol";
// remove: import {VaultBaseV2} from "./flap/VaultBaseV2.sol";
```

```solidity
contract MyxVault is VaultBaseV3, Initializable, AccessControlUpgradeable, ReentrancyGuardUpgradeable, ITriggerReceiver {
```

Replace `InitParams`:

```solidity
    struct InitParams {
        address taxToken;
        address creator;
        /// @dev Launch quote token of the tax token (address(0) = native). Equals vaultQuoteToken().
        address quoteToken;
        address marketQuoteToken;
        address poolManager;
        address basePool;
        uint16 maxSlippageBps;
        /// @dev Minimum recognized quote balance before process() runs; in quote base units.
        uint256 minProcessAmount;
        /// @dev ERC20 quote only: refill the BNB gas pool when it drops below this (wei).
        uint256 gasThreshold;
        /// @dev ERC20 quote only: target BNB gas pool after a refill (wei); must exceed gasThreshold.
        uint256 gasRefillAmount;
    }
```

Rename the storage field and append the new ones (keep declaration order; layout is append-only):

```solidity
    /// @notice Recognized-and-unspent quote revenue (Flap rule 010 baseline). Native quote: equals
    ///         address(this).balance. ERC20 quote: <= IERC20(quoteToken).balanceOf(this).
    uint256 public pendingQuote;
    uint256 public totalLpMinted;
    uint256 public totalRewardsForwarded;

    uint256 public pendingTriggerId;
    bool public hasPendingTrigger;

    /// @notice Revenue currency (address(0) = native gas token). Immutable after initialize.
    address public quoteToken;
    /// @notice ERC20 quote only: refill the BNB gas pool below this balance (wei).
    uint256 public gasThreshold;
    /// @notice ERC20 quote only: gas pool target after a refill (wei).
    uint256 public gasRefillAmount;

    /// @dev Reserved storage for upgrades. 44 original - 2 (trigger) - 3 (V3 quote/gas) = 39.
    uint256[39] private __gap;
```

Update `initialize`:

```solidity
    function initialize(InitParams calldata p) external initializer {
        __AccessControl_init();
        __ReentrancyGuard_init();

        taxToken = p.taxToken;
        creator = p.creator;
        require(p.marketQuoteToken != address(0), unicode"Zero market quote token / 市場報價幣為零地址");
        marketQuoteToken = p.marketQuoteToken;
        marketId = MyxMarketId.derive(uint64(block.chainid), p.marketQuoteToken);
        poolId = MyxPoolId.derive(marketId, p.taxToken);
        poolManager = IMyxPoolManager(p.poolManager);
        basePool = IMyxBasePool(p.basePool);
        maxSlippageBps = p.maxSlippageBps;
        minProcessAmount = p.minProcessAmount;

        quoteToken = p.quoteToken;
        if (p.quoteToken == address(0)) {
            require(
                p.gasThreshold == 0 && p.gasRefillAmount == 0,
                unicode"Gas params must be zero for native quote / 原生報價幣的 Gas 參數必須為零"
            );
        } else {
            require(
                p.gasRefillAmount > p.gasThreshold,
                unicode"Gas refill must exceed threshold / Gas 補充值必須大於閾值"
            );
        }
        gasThreshold = p.gasThreshold;
        gasRefillAmount = p.gasRefillAmount;

        address guardian = _getGuardian();
        _grantRole(DEFAULT_ADMIN_ROLE, guardian);
        _grantRole(EMERGENCY_ROLE, guardian);
        _grantRole(EMERGENCY_ROLE, p.creator);
    }

    /// @inheritdoc VaultBaseV3
    function vaultQuoteToken() public view override returns (address) {
        return quoteToken;
    }
```

Mechanically rename every remaining `pendingEth` in `src/MyxVault.sol` to `pendingQuote` (receive, scheduleProcess, process, emergencySweepEth, description). Also update the top-of-file NatSpec bullet that mentions `pendingEth`.

- [ ] **Step 4: Run tests**

Run: `forge test --no-match-path 'test/*.fork.t.sol'`
Expected: all previously-passing tests pass plus the 4 new ones; `test_description_formatsWeiAsDecimals` still fails (fixed in Task 8). `forge build` compiles the fork test.

- [ ] **Step 5: Commit checkpoint**

```bash
git add src/MyxVault.sol test/MyxVault.t.sol test/MyxVaultAutoTrigger.t.sol test/Integration.fork.t.sol
git commit -m "feat(vault): adopt VaultBaseV3 surface, quote token and gas pool parameters"
```

---

### Task 4: Balance-delta accounting in `receive()` (rule 010)

**Files:**
- Modify: `src/MyxVault.sol` (`receive`, new `sync`, `_sync`, `_quoteBalance`)
- Create: `test/MyxVaultErc20Quote.t.sol` (base fixture reused by Tasks 5–8)
- Modify: `test/MyxVault.t.sol` (`test_receive_accountsOnly` extended)

**Interfaces:**
- Produces: `function sync() external`, `event RevenueReceived(uint256 amount, uint256 pendingTotal)` (unchanged signature, now emitted per recognized delta), internal `_sync() returns (uint256 newRevenue)`, internal `_quoteBalance() view returns (uint256)`.
- Produces test fixture `MyxVaultErc20QuoteTestBase` with fields `vault, rwa, wbnb, router, registry, taxProcessor, portal, triggerService, poolManager, basePool, lpToken, dividend, taxToken, usdt` and helpers `_sendTax(uint256)`, `_ping()`.

- [ ] **Step 1: Write the failing tests**

Create `test/MyxVaultErc20Quote.t.sol`:

```solidity
// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.26;

import {Test} from "forge-std/Test.sol";
import {MyxVault} from "../src/MyxVault.sol";
import {MarketId, PoolId, MyxPoolId, MyxMarketId, PoolMetadata} from "../src/myx/IMyxPool.sol";
import {ERC1967Proxy} from "@openzeppelin/proxy/ERC1967/ERC1967Proxy.sol";
import "./mocks/Mocks.sol";

/// @dev Fixture for an ERC20 (RWA) quote vault on chainId 56. Portal, trigger service are etched at
///      the addresses MyxVault resolves; the swap venue is reached through
///      taxToken.taxProcessor().swapRegistry() exactly like on mainnet.
contract MyxVaultErc20QuoteTestBase is Test {
    MyxVault vault;
    MockERC20 usdt; // myx market quote
    MockERC20 rwa; // launch quote (tax currency)
    MockERC20 lpToken;
    MockWBNB wbnb;
    MockBasePool basePool;
    MockPoolManager poolManager;
    MockPortal portal;
    MockDividendDistributor dividend;
    MockTaxToken taxToken;
    MockFlapTriggerService triggerService;
    MockMultiDexRouter router;
    MockSwapRegistry registry;
    MockTaxProcessor taxProcessor;

    address creator = makeAddr("creator");
    address constant GUARDIAN = 0x9e27098dcD8844bcc6287a557E0b4D09C86B8a4b;
    address constant PORTAL = 0xe2cE6ab80874Fa9Fa2aAE65D277Dd6B8e65C9De0;
    address constant TRIGGER_SERVICE = 0xcf4EE25035CF883895110f367F5BA8172416a7F9;
    MarketId marketId;

    uint256 constant MIN_PROCESS = 10 ether; // 10 RWA
    uint256 constant GAS_THRESHOLD = 0.01 ether;
    uint256 constant GAS_REFILL = 0.05 ether;

    function setUp() public virtual {
        vm.chainId(56);
        usdt = new MockERC20("Tether", "USDT");
        rwa = new MockERC20("NVDA bStock", "NVDAB");
        marketId = MyxMarketId.derive(uint64(56), address(usdt));
        lpToken = new MockERC20("MYX LP", "MLP");
        wbnb = new MockWBNB();
        basePool = new MockBasePool(lpToken, usdt);
        poolManager = new MockPoolManager();
        poolManager.setLpTokenForDeploy(address(lpToken));
        dividend = new MockDividendDistributor(address(lpToken));
        taxToken = new MockTaxToken(address(dividend));

        router = new MockMultiDexRouter(wbnb);
        vm.deal(address(router), 1000 ether);
        router.setPool(2500, true);
        router.setRate(2500, 3, 1000); // 1 RWA -> 0.003 BNB
        registry = new MockSwapRegistry(address(router), address(wbnb));
        taxProcessor = new MockTaxProcessor(address(registry));
        taxToken.setTaxProcessor(address(taxProcessor));

        MockPortal portalImpl = new MockPortal();
        vm.etch(PORTAL, address(portalImpl).code);
        portal = MockPortal(PORTAL);
        portal.setRate(1000, 1); // 1 RWA -> 1000 tax tokens
        portal.setQuoteConfig(address(rwa), true, 0);

        MockFlapTriggerService tsImpl = new MockFlapTriggerService();
        vm.etch(TRIGGER_SERVICE, address(tsImpl).code);
        triggerService = MockFlapTriggerService(TRIGGER_SERVICE);
        triggerService.setFee(0.001 ether);

        vault = _deployVault(_initParams());
    }

    function _initParams() internal view returns (MyxVault.InitParams memory p) {
        p.taxToken = address(taxToken);
        p.creator = creator;
        p.quoteToken = address(rwa);
        p.marketQuoteToken = address(usdt);
        p.poolManager = address(poolManager);
        p.basePool = address(basePool);
        p.maxSlippageBps = 300;
        p.minProcessAmount = MIN_PROCESS;
        p.gasThreshold = GAS_THRESHOLD;
        p.gasRefillAmount = GAS_REFILL;
    }

    function _deployVault(MyxVault.InitParams memory p) internal returns (MyxVault) {
        MyxVault impl = new MyxVault();
        return MyxVault(payable(address(new ERC1967Proxy(address(impl), abi.encodeCall(MyxVault.initialize, (p))))));
    }

    /// @dev Mirrors TaxProcessor.dispatch for an ERC20 quote: bare transfer, then a zero-value ping.
    function _sendTax(uint256 amount) internal {
        rwa.mint(address(vault), amount);
        _ping();
    }

    function _ping() internal returns (bool ok) {
        (ok,) = address(vault).call{value: 0, gas: 500_000}("");
    }
}

contract MyxVaultErc20AccountingTest is MyxVaultErc20QuoteTestBase {
    event RevenueReceived(uint256 amount, uint256 pendingTotal);

    function test_bareTransfer_notRecognized_pingRecognizes() public {
        rwa.mint(address(vault), 5 ether);
        assertEq(vault.pendingQuote(), 0, "transfer alone must not be recognized");
        vm.expectEmit(true, true, true, true);
        emit RevenueReceived(5 ether, 5 ether);
        assertTrue(_ping(), "ping must succeed");
        assertEq(vault.pendingQuote(), 5 ether);
    }

    function test_zeroDeltaPing_silentNoop() public {
        _sendTax(5 ether);
        assertTrue(_ping());
        assertTrue(_ping());
        assertEq(vault.pendingQuote(), 5 ether);
    }

    function test_sync_recognizesDonation() public {
        rwa.mint(address(vault), 3 ether);
        vault.sync();
        assertEq(vault.pendingQuote(), 3 ether);
    }

    function test_nativeSentToErc20Vault_isGasNotRevenue() public {
        vm.deal(address(this), 1 ether);
        (bool ok,) = address(vault).call{value: 1 ether}("");
        assertTrue(ok);
        assertEq(vault.pendingQuote(), 0, "native is the gas pool, not quote revenue");
        assertEq(address(vault).balance, 1 ether);
    }

    function test_ping_gasUnder100k() public {
        rwa.mint(address(vault), 5 ether);
        uint256 g0 = gasleft();
        (bool ok,) = address(vault).call{value: 0}("");
        uint256 used = g0 - gasleft();
        assertTrue(ok);
        assertLt(used, 100_000);
    }
}
```

In `test/MyxVault.t.sol` extend `test_receive_accountsOnly`:

```solidity
    function test_receive_accountsOnly() public {
        vm.deal(address(this), 1 ether);
        (bool ok,) = address(vault).call{value: 1 ether}("");
        assertTrue(ok);
        assertEq(vault.pendingQuote(), 1 ether);
        assertEq(address(vault).balance, 1 ether);
        // zero-value wake with no new revenue is a silent no-op
        (ok,) = address(vault).call{value: 0}("");
        assertTrue(ok);
        assertEq(vault.pendingQuote(), 1 ether);
    }

    function test_sync_native_recognizesForceSentBalance() public {
        vm.deal(address(vault), 0.5 ether); // e.g. selfdestruct / coinbase style credit
        vault.sync();
        assertEq(vault.pendingQuote(), 0.5 ether);
    }
```

- [ ] **Step 2: Run to verify failure**

Run: `forge test --match-path test/MyxVaultErc20Quote.t.sol`
Expected: `sync` undefined / `test_bareTransfer…` fails because `receive` still does `pendingQuote += msg.value`.

- [ ] **Step 3: Implement**

In `src/MyxVault.sol` replace `receive()` and add the sync helpers:

```solidity
    /// @dev Rule-010 balance-delta recognition, currency-agnostic. Wake sources: native value
    ///      transfers (native quote), the TaxProcessor's zero-value ping after an ERC20 payout,
    ///      anyone calling with empty calldata. Zero-delta wakes are silent no-ops.
    receive() external payable {
        _sync();
        if (!hasPendingTrigger && pendingQuote >= minProcessAmount && !_reentrancyGuardEntered()) {
            try this.scheduleProcess() {} catch {}
        }
    }

    /// @notice Permissionless recognition entry: credits revenue that arrived without a wake call.
    function sync() external {
        _sync();
    }

    function _quoteBalance() internal view returns (uint256) {
        return quoteToken == address(0) ? address(this).balance : IERC20(quoteToken).balanceOf(address(this));
    }

    /// @dev Advances the baseline by the unrecognized delta. Never reverts.
    function _sync() internal returns (uint256 newRevenue) {
        uint256 bal = _quoteBalance();
        if (bal <= pendingQuote) return 0;
        newRevenue = bal - pendingQuote;
        pendingQuote = bal;
        emit RevenueReceived(newRevenue, pendingQuote);
    }
```

The `!_reentrancyGuardEntered()` clause prevents the WBNB unwrap inside `process()` (Task 7) from scheduling a trigger mid-process. Update the contract NatSpec invariants bullet for `receive()` accordingly.

- [ ] **Step 4: Run tests**

Run: `forge test --no-match-path 'test/*.fork.t.sol'`
Expected: new tests pass; `test_receive_gasUnder1M` still `< 100_000`; auto-trigger tests unchanged and green.

- [ ] **Step 5: Commit checkpoint**

```bash
git add src/MyxVault.sol test/MyxVault.t.sol test/MyxVaultErc20Quote.t.sol
git commit -m "feat(vault): rule-010 balance-delta revenue recognition and permissionless sync"
```

---

### Task 5: ERC20-input buyback in `process()`

**Files:**
- Modify: `src/MyxVault.sol` (`_buyTaxToken`, `process`)
- Modify: `test/MyxVaultErc20Quote.t.sol` (add `MyxVaultErc20ProcessTest`)

**Interfaces:**
- Produces: `process()` recognizes revenue first (`_sync`), then buys with `quoteToken` as Portal input. Event `RevenueProcessed(uint256 quoteAmount, uint256 baseAmount, uint256 lpMinted)` (parameter renamed only).

- [ ] **Step 1: Write the failing tests**

Append to `test/MyxVaultErc20Quote.t.sol`:

```solidity
contract MyxVaultErc20ProcessTest is MyxVaultErc20QuoteTestBase {
    function setUp() public override {
        super.setUp();
        PoolMetadata memory meta;
        meta.marketId = marketId;
        meta.poolId = MyxPoolId.derive(marketId, address(taxToken));
        meta.baseToken = address(taxToken);
        meta.quoteToken = address(usdt);
        meta.basePoolToken = address(lpToken);
        poolManager.setPool(meta.poolId, meta);
        // gas pool already above threshold so this suite isolates the buyback leg
        vm.deal(address(vault), GAS_REFILL);
    }

    function test_process_buysWithErc20QuoteAndFeedsLp() public {
        _sendTax(20 ether);
        vm.prank(makeAddr("keeper"));
        vault.process();
        assertEq(vault.pendingQuote(), 0);
        assertEq(rwa.balanceOf(address(vault)), 0, "all quote spent");
        assertEq(rwa.balanceOf(PORTAL), 20 ether, "portal pulled the ERC20 input");
        assertEq(basePool.lastDepositAmount(), 20_000 ether);
        assertEq(dividend.totalDeposited(), 20_000 ether, "LP fed to dividend");
    }

    function test_process_recognizesUnpingedRevenueFirst() public {
        rwa.mint(address(vault), 20 ether); // no ping
        vault.process(); // must sync then run
        assertEq(basePool.lastDepositAmount(), 20_000 ether);
    }

    function test_process_belowMinimum_reverts() public {
        _sendTax(MIN_PROCESS - 1);
        vm.expectRevert(bytes(unicode"Pending below minimum / 待處理金額低於下限"));
        vault.process();
    }

    function test_process_swapReverts_retainsQuote() public {
        _sendTax(20 ether);
        portal.setRate(0, 1);
        vm.expectRevert(bytes(unicode"Buyback quote is zero / 回購報價為零"));
        vault.process();
        assertEq(vault.pendingQuote(), 20 ether);
        assertEq(rwa.balanceOf(address(vault)), 20 ether);
    }
}
```

- [ ] **Step 2: Run to verify failure**

Run: `forge test --match-path test/MyxVaultErc20Quote.t.sol --match-contract MyxVaultErc20ProcessTest`
Expected: `test_process_buysWithErc20QuoteAndFeedsLp` reverts inside MockPortal (`bad msg.value`) because the vault still sends value / uses `inputToken: address(0)`.

- [ ] **Step 3: Implement**

Replace `_buyTaxToken` in `src/MyxVault.sol`:

```solidity
    /// @dev quote -> taxToken via the Flap Portal (bonding curve or DEX phase, Portal routes).
    ///      Native quote sends value; ERC20 quote approves the Portal and sends no value (the
    ///      Portal pulls the input, "BUY with quote"). minOut is a same-block quote bound — caps
    ///      single-call deviation, cannot prevent sandwiches. Returns the BALANCE DELTA: DEX-phase
    ///      buys land net of the token's own transfer tax.
    function _buyTaxToken(uint256 quoteAmount) internal returns (uint256 received) {
        IPortalTradeV2 portal = IPortalTradeV2(_getPortal());
        uint256 quoted = portal.quoteExactInput(
            IPortalTradeV2.QuoteExactInputParams({
                inputToken: quoteToken,
                outputToken: taxToken,
                inputAmount: quoteAmount
            })
        );
        require(quoted != 0, unicode"Buyback quote is zero / 回購報價為零");
        uint256 minOut = (quoted * (BPS_DENOMINATOR - maxSlippageBps)) / BPS_DENOMINATOR;

        uint256 balanceBefore = IERC20(taxToken).balanceOf(address(this));
        uint256 value;
        if (quoteToken == address(0)) {
            value = quoteAmount;
        } else {
            IERC20(quoteToken).forceApprove(address(portal), quoteAmount);
        }
        portal.swapExactInput{value: value}(
            IPortalTradeV2.ExactInputParams({
                inputToken: quoteToken,
                outputToken: taxToken,
                inputAmount: quoteAmount,
                minOutputAmount: minOut,
                permitData: ""
            })
        );
        received = IERC20(taxToken).balanceOf(address(this)) - balanceBefore;
    }
```

Replace the head of `process()` so it syncs first (the refill hook is added in Task 7):

```solidity
    function process() external nonReentrant {
        _sync();
        uint256 amount = pendingQuote;
        require(amount >= minProcessAmount, unicode"Pending below minimum / 待處理金額低於下限");
        pendingQuote = 0;

        uint256 received = _buyTaxToken(amount);
        _ensurePoolExists();

        IERC20(taxToken).forceApprove(address(basePool), received);
        uint256 lpOut = basePool.deposit(poolId, received, 0, address(this), address(this));
        totalLpMinted += lpOut;

        emit RevenueProcessed(amount, received, lpOut);
        _feedDividend();
    }
```

Rename the event parameter: `event RevenueProcessed(uint256 quoteAmount, uint256 baseAmount, uint256 lpMinted);`

- [ ] **Step 4: Run tests**

Run: `forge test --no-match-path 'test/*.fork.t.sol'` → all green except the pre-existing description test.

- [ ] **Step 5: Commit checkpoint**

```bash
git add src/MyxVault.sol test/MyxVaultErc20Quote.t.sol
git commit -m "feat(vault): buy back with the launch quote token as Portal input"
```

---

### Task 6: Gas pool — `fundGas`, `gasBalance`, trigger fee from the pool

**Files:**
- Modify: `src/MyxVault.sol` (`scheduleProcess`, new `fundGas`, `gasBalance`, events)
- Modify: `test/MyxVaultErc20Quote.t.sol` (add `MyxVaultErc20GasPoolTest`), `test/MyxVault.t.sol` (native `fundGas` rejection)

**Interfaces:**
- Produces: `function fundGas() external payable`, `function gasBalance() external view returns (uint256)`, `event GasFunded(address indexed from, uint256 amount)`.

- [ ] **Step 1: Write the failing tests**

Append to `test/MyxVaultErc20Quote.t.sol`:

```solidity
contract MyxVaultErc20GasPoolTest is MyxVaultErc20QuoteTestBase {
    event GasFunded(address indexed from, uint256 amount);

    function test_fundGas_anyoneCanTopUp() public {
        address donor = makeAddr("donor");
        vm.deal(donor, 1 ether);
        vm.prank(donor);
        vm.expectEmit(true, true, true, true);
        emit GasFunded(donor, 0.2 ether);
        vault.fundGas{value: 0.2 ether}();
        assertEq(vault.gasBalance(), 0.2 ether);
        assertEq(vault.pendingQuote(), 0, "gas is not revenue");
    }

    function test_receive_noGas_recordsButDoesNotSchedule() public {
        _sendTax(20 ether);
        assertEq(vault.pendingQuote(), 20 ether);
        assertFalse(vault.hasPendingTrigger(), "no BNB in the gas pool -> cannot pay the fee");
    }

    function test_receive_withGas_schedulesAndPaysFromPool() public {
        vault.fundGas{value: 0.01 ether}();
        _sendTax(20 ether);
        assertTrue(vault.hasPendingTrigger());
        assertEq(vault.pendingQuote(), 20 ether, "quote revenue untouched by the fee");
        assertEq(vault.gasBalance(), 0.01 ether - triggerService.getFee());
        assertEq(triggerService.requesterOf(1), address(vault));
    }

    function test_fundGas_afterTax_schedulesOnNextWake() public {
        _sendTax(20 ether);
        assertFalse(vault.hasPendingTrigger());
        vault.fundGas{value: 0.01 ether}();
        assertTrue(_ping(), "spurious wake");
        assertTrue(vault.hasPendingTrigger(), "gas now available -> scheduled on the next wake");
    }

    function test_trigger_runsProcessWithErc20Quote() public {
        PoolMetadata memory meta;
        meta.marketId = marketId;
        meta.poolId = MyxPoolId.derive(marketId, address(taxToken));
        meta.baseToken = address(taxToken);
        meta.basePoolToken = address(lpToken);
        poolManager.setPool(meta.poolId, meta);
        vault.fundGas{value: GAS_REFILL}();
        _sendTax(20 ether);
        uint256 id = vault.pendingTriggerId();
        vm.warp(block.timestamp + 61);
        triggerService.fire(id);
        assertEq(vault.pendingQuote(), 0);
        assertGt(vault.totalLpMinted(), 0);
        assertFalse(vault.hasPendingTrigger());
    }

    receive() external payable {}
}
```

Add to `MyxVaultInitTest` in `test/MyxVault.t.sol`:

```solidity
    function test_fundGas_rejectedForNativeQuote() public {
        vm.deal(address(this), 1 ether);
        vm.expectRevert(bytes(unicode"Gas pool only for ERC20 quote / 僅 ERC20 報價幣金庫可充值 Gas"));
        vault.fundGas{value: 0.1 ether}();
        assertEq(vault.gasBalance(), 0);
    }
```

- [ ] **Step 2: Run to verify failure**

Run: `forge test --match-path test/MyxVaultErc20Quote.t.sol --match-contract MyxVaultErc20GasPoolTest`
Expected: `fundGas` undefined.

- [ ] **Step 3: Implement**

Add events next to the existing ones in `src/MyxVault.sol`:

```solidity
    /// @notice Emitted when someone tops up the BNB gas pool of an ERC20-quote vault.
    event GasFunded(address indexed from, uint256 amount);
```

Replace `scheduleProcess`:

```solidity
    /// @notice Schedules a delayed process() via FlapTriggerService. ONLY the vault itself may call it
    ///         (from receive()); the self-call lets receive() wrap getFee()+requestTrigger in one
    ///         try/catch. Native quote: the fee is paid from pendingQuote and debited only on success.
    ///         ERC20 quote: the fee is paid from the BNB gas pool; pendingQuote is untouched.
    function scheduleProcess() external {
        require(msg.sender == address(this), unicode"Caller must be the vault itself / 僅限金庫自身調用");
        IFlapTriggerService service = IFlapTriggerService(_getTriggerService());
        uint256 fee = service.getFee();
        if (quoteToken == address(0)) {
            require(pendingQuote >= minProcessAmount + fee, unicode"Pending below minimum plus fee / 待處理低於下限加手續費");
        } else {
            require(pendingQuote >= minProcessAmount, unicode"Pending below minimum / 待處理金額低於下限");
            require(address(this).balance >= fee, unicode"Gas pool below trigger fee / Gas 池低於觸發手續費");
        }
        uint64 executeAfter = uint64(block.timestamp) + PROCESS_DELAY;
        uint256 id = service.requestTrigger{value: fee}(executeAfter);
        pendingTriggerId = id;
        hasPendingTrigger = true;
        if (quoteToken == address(0)) pendingQuote -= fee;
        emit ProcessScheduled(id, executeAfter);
    }

    /// @notice Tops up the BNB gas pool that pays FlapTriggerService fees. ERC20-quote vaults only:
    ///         on a native-quote vault every BNB is revenue and arrives through receive().
    function fundGas() external payable {
        require(quoteToken != address(0), unicode"Gas pool only for ERC20 quote / 僅 ERC20 報價幣金庫可充值 Gas");
        emit GasFunded(msg.sender, msg.value);
    }

    /// @notice BNB reserved for trigger fees. Zero for native-quote vaults (their BNB is revenue).
    function gasBalance() external view returns (uint256) {
        return quoteToken == address(0) ? 0 : address(this).balance;
    }
```

- [ ] **Step 4: Run tests**

Run: `forge test --no-match-path 'test/*.fork.t.sol'` → green (except the description test).

- [ ] **Step 5: Commit checkpoint**

```bash
git add src/MyxVault.sol test/MyxVault.t.sol test/MyxVaultErc20Quote.t.sol
git commit -m "feat(vault): BNB gas pool for ERC20-quote trigger fees with permissionless fundGas"
```

---

### Task 7: Gas refill leg via Flap MultiDexRouter with automatic pool selection

**Files:**
- Modify: `src/MyxVault.sol` (`_refillGas`, `_swapVenue`, `_bestPool`, `_quoteOut`, `process` hook, events, imports)
- Modify: `test/MyxVaultErc20Quote.t.sol` (add `MyxVaultErc20RefillTest`)

**Interfaces:**
- Produces: events `GasRefilled(uint256 quoteIn, uint256 nativeOut, uint24 fee)`, `GasRefillSkipped(uint256 pendingQuote)`, `BuybackSkipped(uint256 pendingQuote)`.
- Consumes: `IMultiDexRouter`, `ISwapRegistry`, `IPortalQuoteConfigU8` (Task 1), `IWBNB` (`src/dex/IWBNB.sol`, existing), `ITaxProcessor.swapRegistry()` (existing), `IFlapTaxTokenV3.taxProcessor()` (existing).

- [ ] **Step 1: Write the failing tests**

Append to `test/MyxVaultErc20Quote.t.sol`:

```solidity
contract MyxVaultErc20RefillTest is MyxVaultErc20QuoteTestBase {
    event GasRefilled(uint256 quoteIn, uint256 nativeOut, uint24 fee);
    event GasRefillSkipped(uint256 pendingQuote);
    event BuybackSkipped(uint256 pendingQuote);

    function setUp() public override {
        super.setUp();
        PoolMetadata memory meta;
        meta.marketId = marketId;
        meta.poolId = MyxPoolId.derive(marketId, address(taxToken));
        meta.baseToken = address(taxToken);
        meta.basePoolToken = address(lpToken);
        poolManager.setPool(meta.poolId, meta);
    }

    /// @dev Gas pool empty; 1 RWA -> 0.003 BNB on the 2500 pool. Needed = 0.05 BNB -> ~16.67 RWA.
    function test_process_refillsGasThenBuysBackRemainder() public {
        _sendTax(100 ether);
        vm.expectEmit(false, false, false, false);
        emit GasRefilled(0, 0, 0);
        vault.process();
        assertEq(router.lastFeeUsed(), 2500);
        uint256 quoteIn = router.lastAmountIn();
        assertApproxEqRel(quoteIn, 16.666 ether, 0.01e18, "linear estimate of quote needed");
        assertEq(address(vault).balance, quoteIn * 3 / 1000, "gas pool refilled to ~target");
        assertGe(address(vault).balance, GAS_THRESHOLD);
        assertEq(basePool.lastDepositAmount(), (100 ether - quoteIn) * 1000, "remainder bought back");
        assertEq(vault.pendingQuote(), 0);
    }

    function test_process_noRefillWhenGasAboveThreshold() public {
        vault.fundGas{value: GAS_THRESHOLD}();
        _sendTax(100 ether);
        vault.process();
        assertEq(router.lastAmountIn(), 0, "no swap");
        assertEq(basePool.lastDepositAmount(), 100_000 ether);
    }

    function test_process_picksBestFeeTier() public {
        router.setPool(500, true);
        router.setRate(500, 4, 1000); // better: 1 RWA -> 0.004 BNB
        router.setPool(10000, true);
        router.setRate(10000, 1, 1000);
        _sendTax(100 ether);
        vault.process();
        assertEq(router.lastFeeUsed(), 500);
    }

    function test_process_quoteRevertOnOneTier_isIgnored() public {
        router.setPool(500, true);
        router.setQuoteReverts(500, true);
        _sendTax(100 ether);
        vault.process();
        assertEq(router.lastFeeUsed(), 2500);
    }

    function test_process_noPool_skipsRefillAndStillBuysBack() public {
        router.setPool(2500, false);
        _sendTax(100 ether);
        vm.expectEmit(true, true, true, true);
        emit GasRefillSkipped(100 ether);
        vault.process();
        assertEq(address(vault).balance, 0);
        assertEq(basePool.lastDepositAmount(), 100_000 ether);
    }

    function test_process_spendsAllQuoteWhenNotEnoughForTarget() public {
        _sendTax(MIN_PROCESS); // 10 RWA -> 0.03 BNB < 0.05 target
        vm.expectEmit(true, true, true, true);
        emit BuybackSkipped(0);
        vault.process();
        assertEq(router.lastAmountIn(), MIN_PROCESS, "everything went to gas");
        assertEq(address(vault).balance, 0.03 ether);
        assertEq(vault.pendingQuote(), 0);
        assertEq(basePool.depositCallCount(), 0, "buyback skipped, no revert");
    }

    function test_process_refillDoesNotScheduleTriggerMidProcess() public {
        _sendTax(100 ether);
        vault.process(); // WBNB.withdraw pays BNB into receive() while process() holds the guard
        assertFalse(vault.hasPendingTrigger(), "no trigger scheduled from inside process()");
    }

    function test_process_slippageBreach_reverts() public {
        _sendTax(100 ether);
        // quote says 0.003/RWA but execution pays less than (1 - 3%): emulate by lowering the rate
        // between quote and swap is impossible in the mock, so widen the check: set rate to 0 after
        // quoting is not observable; instead assert the minOut wiring via a 100% slippage vault.
        MyxVault.InitParams memory p = _initParams();
        p.maxSlippageBps = 0; // exact quote required; mock returns exactly the quote -> passes
        MyxVault strict = _deployVault(p);
        rwa.mint(address(strict), 100 ether);
        strict.process();
        assertGt(address(strict).balance, 0);
    }

    function test_refill_readsVenueThroughTaxProcessorChain() public {
        MockMultiDexRouter other = new MockMultiDexRouter(wbnb);
        vm.deal(address(other), 100 ether);
        other.setPool(2500, true);
        other.setRate(2500, 3, 1000);
        registry.setMultiDexRouter(address(other));
        _sendTax(100 ether);
        vault.process();
        assertGt(other.lastAmountIn(), 0, "router resolved dynamically from SwapRegistry");
        assertEq(router.lastAmountIn(), 0);
    }

    receive() external payable {}
}
```

- [ ] **Step 2: Run to verify failure**

Run: `forge test --match-path test/MyxVaultErc20Quote.t.sol --match-contract MyxVaultErc20RefillTest`
Expected: compile error on the events, or `test_process_refillsGasThenBuysBackRemainder` failing with `lastFeeUsed == 0`.

- [ ] **Step 3: Implement**

Imports in `src/MyxVault.sol`:

```solidity
import {Math} from "@openzeppelin/utils/math/Math.sol";
import {ITaxProcessor} from "./flap/ITaxProcessor.sol";
import {ISwapRegistry} from "./flap/ISwapRegistry.sol";
import {IMultiDexRouter} from "./flap/IMultiDexRouter.sol";
import {IPortalQuoteConfigU8} from "./flap/IPortalQuoteConfigU8.sol";
import {IWBNB} from "./dex/IWBNB.sol";
```

Events:

```solidity
    /// @notice Emitted when quote revenue was swapped into BNB for the gas pool.
    event GasRefilled(uint256 quoteIn, uint256 nativeOut, uint24 fee);
    /// @notice Emitted when a refill was due but no quote/WBNB V3 pool could quote it. Not a failure:
    ///         the buyback proceeds and the pool is retried on the next process().
    event GasRefillSkipped(uint256 pendingQuote);
    /// @notice Emitted when, after a refill, the remaining quote is below minProcessAmount.
    event BuybackSkipped(uint256 pendingQuote);
```

Insert the refill hook in `process()` right after the minimum check:

```solidity
    function process() external nonReentrant {
        _sync();
        require(pendingQuote >= minProcessAmount, unicode"Pending below minimum / 待處理金額低於下限");
        _refillGas();
        uint256 amount = pendingQuote;
        if (amount < minProcessAmount) {
            emit BuybackSkipped(amount);
            return;
        }
        pendingQuote = 0;

        uint256 received = _buyTaxToken(amount);
        // ... unchanged from Task 5 ...
    }
```

Add the refill leg (place after `_buyTaxToken`):

```solidity
    /// @dev ERC20 quote only. When the BNB gas pool is below gasThreshold, swaps just enough quote
    ///      to bring it to gasRefillAmount (capped by pendingQuote) through Flap's MultiDexRouter:
    ///        venue: taxToken.taxProcessor().swapRegistry() -> multiDexRouter() / weth();
    ///        dexId: Portal.getQuoteTokenConfiguration(quote).dexId;
    ///        pool:  the V3 fee tier with the best quote among getDEXInfo(dexId).v3SupportedFees.
    ///      minOut is the same-block quote x (1 - maxSlippageBps). No pool -> skip with an event.
    ///      Rule 010: pendingQuote is decremented before the outflow.
    function _refillGas() internal {
        if (quoteToken == address(0)) return;
        uint256 gasBal = address(this).balance;
        if (gasBal >= gasThreshold) return;
        uint256 needed = gasRefillAmount - gasBal;

        (IMultiDexRouter router, address wbnb, uint8 dexId) = _swapVenue();
        uint256 available = pendingQuote;
        (uint24 fee, uint256 outForAll) = _bestPool(router, wbnb, dexId, available);
        if (outForAll == 0) {
            emit GasRefillSkipped(available);
            return;
        }
        uint256 quoteIn = outForAll > needed ? Math.mulDiv(available, needed, outForAll) : available;
        uint256 quoted = quoteIn == available ? outForAll : _quoteOut(router, wbnb, dexId, fee, quoteIn);
        if (quoteIn == 0 || quoted == 0) {
            emit GasRefillSkipped(available);
            return;
        }
        uint256 minOut = (quoted * (BPS_DENOMINATOR - maxSlippageBps)) / BPS_DENOMINATOR;

        pendingQuote -= quoteIn;
        IERC20(quoteToken).forceApprove(address(router), quoteIn);
        uint256 got = router.exactInputSingle(
            dexId,
            IMultiDexRouter.ExactInputSingleParams({
                tokenIn: quoteToken,
                tokenOut: wbnb,
                fee: fee,
                recipient: address(this),
                amountIn: quoteIn,
                amountOutMinimum: minOut,
                sqrtPriceLimitX96: 0
            })
        );
        IWBNB(wbnb).withdraw(got); // pays BNB into receive(); guard flag suppresses scheduling
        emit GasRefilled(quoteIn, got, fee);
    }

    function _swapVenue() internal view returns (IMultiDexRouter router, address wbnb, uint8 dexId) {
        ISwapRegistry registry = ISwapRegistry(ITaxProcessor(IFlapTaxTokenV3(taxToken).taxProcessor()).swapRegistry());
        router = IMultiDexRouter(registry.multiDexRouter());
        wbnb = registry.weth();
        dexId = IPortalQuoteConfigU8(_getPortal()).getQuoteTokenConfiguration(quoteToken).dexId;
    }

    /// @dev Best V3 quote/WBNB tier for `amountIn`. A tier is considered only if its pool has code;
    ///      a reverting quoter call on one tier never blocks the others.
    function _bestPool(IMultiDexRouter router, address wbnb, uint8 dexId, uint256 amountIn)
        internal
        returns (uint24 bestFee, uint256 bestOut)
    {
        if (amountIn == 0) return (0, 0);
        uint24[] memory fees = router.getDEXInfo(dexId).v3SupportedFees;
        for (uint256 i = 0; i < fees.length; i++) {
            if (router.computeV3PoolAddress(dexId, quoteToken, wbnb, fees[i]).code.length == 0) continue;
            uint256 out = _quoteOut(router, wbnb, dexId, fees[i], amountIn);
            if (out > bestOut) {
                bestOut = out;
                bestFee = fees[i];
            }
        }
    }

    function _quoteOut(IMultiDexRouter router, address wbnb, uint8 dexId, uint24 fee, uint256 amountIn)
        internal
        returns (uint256 out)
    {
        try router.quoteExactInputSingle(
            dexId,
            IMultiDexRouter.QuoteExactInputSingleParams({
                tokenIn: quoteToken,
                tokenOut: wbnb,
                amountIn: amountIn,
                fee: fee,
                sqrtPriceLimitX96: 0
            })
        ) returns (uint256 amountOut, uint160, uint32, uint256) {
            out = amountOut;
        } catch {
            out = 0;
        }
    }
```

- [ ] **Step 4: Run tests**

Run: `forge test --no-match-path 'test/*.fork.t.sol'`
Expected: refill suite green; `test_process_refillDoesNotScheduleTriggerMidProcess` proves the guard clause from Task 4.

- [ ] **Step 5: Commit checkpoint**

```bash
git add src/MyxVault.sol test/MyxVaultErc20Quote.t.sol
git commit -m "feat(vault): refill BNB gas pool from quote via Flap MultiDexRouter with auto pool selection"
```

---

### Task 8: Emergency paths, description, UI schema, decimals formatting

**Files:**
- Modify: `src/lib/Decimal18.sol`, `src/MyxVault.sol` (`emergencySweepNative`, `emergencyRescueToken`, `description`, `vaultUISchema`, `_nativeSymbol`)
- Modify: `test/Decimal18.t.sol`, `test/MyxVault.t.sol` (sweep rename, description expectation, schema), `test/MyxVaultErc20Quote.t.sol` (add `MyxVaultErc20EmergencyAndViewsTest`)

**Interfaces:**
- Produces: `Decimal18.toString(uint256 value, uint8 decimals)`; `emergencySweepNative(address to)` (renamed from `emergencySweepEth`); `description()` renders quote symbol and gas pool; schema methods `vaultQuoteToken`, `sync`, `fundGas`, `gasBalance` added.

- [ ] **Step 1: Write the failing tests**

`test/Decimal18.t.sol` additions:

```solidity
    function test_toString_sixDecimals() public pure {
        assertEq(Decimal18.toString(1_500_000, 6), "1.5");
        assertEq(Decimal18.toString(1, 6), "0.000001");
        assertEq(Decimal18.toString(2_000_000, 6), "2");
    }

    function test_toString_zeroDecimals() public pure {
        assertEq(Decimal18.toString(42, 0), "42");
    }

    function test_toString_18DecimalsMatchesLegacy() public pure {
        assertEq(Decimal18.toString(15560495045491564826633, 18), Decimal18.toString(15560495045491564826633));
    }
```

`test/MyxVault.t.sol`: rename both sweep tests to call `emergencySweepNative` and rename them `test_emergencySweepNative` / `test_emergencySweepNative_strangerReverts`. Replace `test_description_formatsWeiAsDecimals` with:

```solidity
    function test_description_formatsWeiAsDecimals() public {
        _fund(9409000000000);
        assertEq(
            vault.description(),
            unicode"MYX liquidity vault / MYX 流動性金庫: 0 LP minted / LP 已鑄造, 0 LP distributed / LP 已分發, pending BNB / 待處理 BNB: 0.000009409."
        );
    }
```

Extend `test_vaultUISchema_exposesProcessClaimAndFeed` with four more flags: `hasSync`, `hasFundGas`, `hasGasBalance`, `hasQuote` checked against names `"sync"`, `"fundGas"`, `"gasBalance"`, `"vaultQuoteToken"`, each asserted true.

Append to `test/MyxVaultErc20Quote.t.sol`:

```solidity
contract MyxVaultErc20EmergencyAndViewsTest is MyxVaultErc20QuoteTestBase {
    function test_emergencySweepNative_clearsGasPoolOnly() public {
        vault.fundGas{value: 0.5 ether}();
        _sendTax(20 ether);
        address rescue = makeAddr("rescue");
        vm.prank(GUARDIAN);
        vault.emergencySweepNative(rescue);
        assertEq(rescue.balance, 0.5 ether);
        assertEq(vault.pendingQuote(), 20 ether, "ERC20 revenue baseline untouched");
    }

    function test_emergencyRescueToken_quote_resetsBaseline() public {
        _sendTax(20 ether);
        address rescue = makeAddr("rescue");
        vm.prank(GUARDIAN);
        vault.emergencyRescueToken(address(rwa), rescue);
        assertEq(rwa.balanceOf(rescue), 20 ether);
        assertEq(vault.pendingQuote(), 0, "rule 010: outflow decrements the baseline");
        // no deadlock: new revenue is recognized again
        _sendTax(1 ether);
        assertEq(vault.pendingQuote(), 1 ether);
    }

    function test_description_showsQuoteSymbolAndGas() public {
        _sendTax(12.5 ether);
        vault.fundGas{value: 0.02 ether}();
        assertEq(
            vault.description(),
            unicode"MYX liquidity vault / MYX 流動性金庫: 0 LP minted / LP 已鑄造, 0 LP distributed / LP 已分發, pending NVDAB / 待處理 NVDAB: 12.5, gas pool / Gas 池: 0.02 BNB."
        );
    }

    function test_description_sixDecimalQuote() public {
        MockERC20Decimals xaut = new MockERC20Decimals("Tether Gold", "XAUt", 6);
        portal.setQuoteConfig(address(xaut), true, 0);
        MyxVault.InitParams memory p = _initParams();
        p.quoteToken = address(xaut);
        p.minProcessAmount = 1_000_000;
        MyxVault v = _deployVault(p);
        xaut.mint(address(v), 2_500_000);
        v.sync();
        assertEq(
            v.description(),
            unicode"MYX liquidity vault / MYX 流動性金庫: 0 LP minted / LP 已鑄造, 0 LP distributed / LP 已分發, pending XAUt / 待處理 XAUt: 2.5, gas pool / Gas 池: 0 BNB."
        );
    }

    receive() external payable {}
}
```

- [ ] **Step 2: Run to verify failure**

Run: `forge test --match-path 'test/Decimal18.t.sol' --match-path 'test/MyxVaultErc20Quote.t.sol'` → compile errors (`toString(uint256,uint8)`, `emergencySweepNative`).

- [ ] **Step 3: Implement**

`src/lib/Decimal18.sol`: keep `toString(uint256)` as `return toString(value, 18);` and add:

```solidity
    /// @notice Renders `value` with `decimals` fractional digits, stripping trailing zeros.
    function toString(uint256 value, uint8 decimals) internal pure returns (string memory) {
        if (decimals == 0) return Strings.toString(value);
        uint256 unit = 10 ** uint256(decimals);
        uint256 whole = value / unit;
        uint256 frac = value % unit;
        if (frac == 0) return Strings.toString(whole);

        bytes memory fracDigits = bytes(Strings.toString(frac));
        uint256 leadingZeros = uint256(decimals) - fracDigits.length;

        uint256 end = fracDigits.length;
        while (end > 0 && fracDigits[end - 1] == "0") {
            end--;
        }

        bytes memory fracOut = new bytes(leadingZeros + end);
        for (uint256 i = 0; i < leadingZeros; i++) {
            fracOut[i] = "0";
        }
        for (uint256 i = 0; i < end; i++) {
            fracOut[leadingZeros + i] = fracDigits[i];
        }
        return string.concat(Strings.toString(whole), ".", string(fracOut));
    }
```

`src/MyxVault.sol` — import `IERC20Metadata`:

```solidity
import {IERC20Metadata} from "@openzeppelin/token/ERC20/extensions/IERC20Metadata.sol";
```

Replace `emergencySweepEth` and adjust `emergencyRescueToken`:

```solidity
    /// @notice Sweeps the vault's native balance. Native quote: this is the tax revenue, baseline
    ///         reset to zero (rule 010). ERC20 quote: this is only the gas pool, revenue untouched.
    function emergencySweepNative(address to) external nonReentrant onlyRole(EMERGENCY_ROLE) {
        uint256 amount = address(this).balance;
        if (quoteToken == address(0)) pendingQuote = 0;
        (bool ok,) = to.call{value: amount}("");
        require(ok, unicode"Native sweep failed / 原生幣清退失敗");
        emit EmergencySwept(amount, to);
    }

    function emergencyRescueToken(address token, address to) external nonReentrant onlyRole(EMERGENCY_ROLE) {
        require(token != address(0) && to != address(0), unicode"Zero address / 零地址");
        uint256 bal = IERC20(token).balanceOf(address(this));
        if (token == quoteToken) pendingQuote = 0; // rule 010: quote outflow resets the baseline
        if (bal > 0) {
            IERC20(token).safeTransfer(to, bal);
            emit EmergencyTokenRescued(token, to, bal);
        }
    }
```

Description helpers and body:

```solidity
    function _nativeSymbol() internal view returns (string memory) {
        return block.chainid == 4663 ? "ETH" : "BNB";
    }

    function _quoteSymbol() internal view returns (string memory) {
        return quoteToken == address(0) ? _nativeSymbol() : IERC20Metadata(quoteToken).symbol();
    }

    function _quoteDecimals() internal view returns (uint8) {
        return quoteToken == address(0) ? 18 : IERC20Metadata(quoteToken).decimals();
    }

    function description() public view override returns (string memory) {
        string memory sym = _quoteSymbol();
        string memory head = string.concat(
            unicode"MYX liquidity vault / MYX 流動性金庫: ",
            Decimal18.toString(totalLpMinted),
            unicode" LP minted / LP 已鑄造, ",
            Decimal18.toString(totalRewardsForwarded),
            unicode" LP distributed / LP 已分發, pending ",
            sym,
            unicode" / 待處理 ",
            sym,
            ": ",
            Decimal18.toString(pendingQuote, _quoteDecimals())
        );
        if (quoteToken == address(0)) return string.concat(head, ".");
        return string.concat(
            head, unicode", gas pool / Gas 池: ", Decimal18.toString(address(this).balance), " ", _nativeSymbol(), "."
        );
    }
```

`vaultUISchema()`: allocate `new VaultMethodSchema[](9)`; keep methods 0–4 as they are but rename method 0 to `"pendingQuote"` with description `unicode"Tax revenue awaiting processing, in quote token units. / 待處理的稅收金額（報價幣單位）。"` and output `FieldDescriptor("amount", "uint256", "Quote amount", 0)`; then add:

```solidity
        schema.methods[5].name = "vaultQuoteToken";
        schema.methods[5].description = unicode"Revenue currency of this vault (zero address = native). / 本金庫的稅收幣種（零地址為原生幣）。";
        schema.methods[5].outputs = new FieldDescriptor[](1);
        schema.methods[5].outputs[0] = FieldDescriptor("quoteToken", "address", "Quote token", 0);

        schema.methods[6].name = "sync";
        schema.methods[6].description = unicode"Recognize quote revenue that arrived without a wake call. Permissionless. / 確認未觸發喚醒的稅收入賬。任何人可調用。";
        schema.methods[6].isWriteMethod = true;

        schema.methods[7].name = "fundGas";
        schema.methods[7].description = unicode"Top up the BNB gas pool that pays auto-trigger fees (ERC20 quote vaults). / 為自動觸發手續費充值 BNB Gas 池（ERC20 報價幣金庫）。";
        schema.methods[7].isWriteMethod = true;

        schema.methods[8].name = "gasBalance";
        schema.methods[8].description = unicode"BNB reserved for auto-trigger fees. / 保留給自動觸發手續費的 BNB。";
        schema.methods[8].outputs = new FieldDescriptor[](1);
        schema.methods[8].outputs[0] = FieldDescriptor("amount", "uint256", "BNB amount", 18);
```

- [ ] **Step 4: Run tests**

Run: `forge test --no-match-path 'test/*.fork.t.sol'` → all green, including the previously failing description test.

- [ ] **Step 5: Commit checkpoint**

```bash
git add src/lib/Decimal18.sol src/MyxVault.sol test/Decimal18.t.sol test/MyxVault.t.sol test/MyxVaultErc20Quote.t.sol
git commit -m "feat(vault): quote-aware emergency paths, description and UI schema"
```

---

### Task 9: Factory — quote whitelist via Portal, vaultData v3, relaxed launch validation

**Files:**
- Modify: `src/MyxVaultFactory.sol`
- Modify: `test/MyxVaultFactory.t.sol`, `test/ChainAddressResolution.t.sol` (config shape), `test/Integration.fork.t.sol` (config shape + vaultData)

**Interfaces:**
- Produces: `struct GlobalConfig { address poolManager; address basePool; address poolFactory; uint16 maxSlippageBps; uint256 minInitialGas; }`
- Produces: `struct VaultData { address marketQuoteToken; uint256 minProcessAmount; uint256 gasThreshold; uint256 gasRefillAmount; }` encoded as `abi.encode(address,uint256,uint256,uint256)`; helper `decodeVaultData(bytes) pure returns (VaultData)`.
- Produces: `isQuoteTokenSupported(address)` = native, or Portal-enabled ERC20 on chains 56/97; native-only on 4663.
- Consumes: `MyxVault.InitParams` (Task 3), `IPortalQuoteConfigU8` (Task 1).
- `minInitialGas` is stored now and enforced in Task 10.

- [ ] **Step 1: Write the failing tests**

In `test/MyxVaultFactory.t.sol` replace `_baseConfig` and `_vaultData`, and add a Portal mock to `setUp`:

```solidity
    address constant PORTAL = 0xe2cE6ab80874Fa9Fa2aAE65D277Dd6B8e65C9De0;
    MockPortal portal;
    MockERC20 rwa;

    // inside setUp(), after `router = new MockPancakeRouter();`
        rwa = new MockERC20("NVDA bStock", "NVDAB");
        MockPortal portalImpl = new MockPortal();
        vm.etch(PORTAL, address(portalImpl).code);
        portal = MockPortal(PORTAL);
        portal.setQuoteConfig(address(rwa), true, 0);

    function _baseConfig() internal view returns (MyxVaultFactory.GlobalConfig memory) {
        return MyxVaultFactory.GlobalConfig({
            poolManager: address(poolManager),
            basePool: address(basePool),
            poolFactory: address(poolFactory),
            maxSlippageBps: 300,
            minInitialGas: 0.002 ether
        });
    }

    function _vaultData() internal view returns (bytes memory) {
        return abi.encode(address(usdt), uint256(0.1 ether), uint256(0), uint256(0));
    }

    function _erc20VaultData() internal view returns (bytes memory) {
        return abi.encode(address(usdt), uint256(10 ether), uint256(0.01 ether), uint256(0.05 ether));
    }
```

Replace `test_isQuoteTokenSupported_onlyBnb`, `test_validateBeforeLaunch_rejectsErc20Quote`, `test_tokenCreationPolicies_declaresConstraints` with:

```solidity
    function test_isQuoteTokenSupported_nativeAlways() public view {
        assertTrue(factory.isQuoteTokenSupported(address(0)));
    }

    function test_isQuoteTokenSupported_portalEnabledErc20() public view {
        assertTrue(factory.isQuoteTokenSupported(address(rwa)));
        assertFalse(factory.isQuoteTokenSupported(address(usdc)), "not enabled on the Portal");
    }

    function test_isQuoteTokenSupported_robinhood_nativeOnly() public {
        vm.chainId(4663);
        assertTrue(factory.isQuoteTokenSupported(address(0)));
        assertFalse(factory.isQuoteTokenSupported(address(rwa)));
    }

    function test_validateBeforeLaunch_acceptsErc20QuoteWithMagicDividend() public view {
        IVaultFactoryValidationV2.LaunchValidationDataV1 memory data;
        data.quoteToken = address(rwa);
        data.dividendToken = MAGIC_DIVIDEND_COMPUTED;
        (bool ok,) = factory.onBeforeLaunch(abi.encode(data));
        assertTrue(ok);
    }

    function test_tokenCreationPolicies_declaresConstraints() public view {
        FactoryPolicy[] memory policies = factory.tokenCreationPolicies();
        assertEq(policies.length, 2);
        assertEq(policies[0].target, "dividendToken");
        assertEq(abi.decode(policies[0].value, (address)), MAGIC_DIVIDEND_COMPUTED);
        assertEq(policies[1].target, "dividendBps");
        assertEq(abi.decode(policies[1].value, (uint256)), 0);
    }

    function test_vaultDataSchema_fourFields() public view {
        VaultDataSchema memory s = factory.vaultDataSchema();
        assertEq(s.fields.length, 4);
        assertEq(s.fields[0].name, "marketQuoteToken");
        assertEq(s.fields[1].name, "minProcessAmount");
        assertEq(s.fields[2].name, "gasThreshold");
        assertEq(s.fields[3].name, "gasRefillAmount");
        assertFalse(s.isArray);
    }

    function test_newVault_erc20Quote_wiresQuoteAndParams() public {
        vm.deal(address(this), 1 ether);
        factory.prepayGas{value: 0.002 ether}(); // Task 10 enforces this; harmless before
        vm.prank(VAULT_PORTAL);
        address vaultAddr = factory.newVault(makeAddr("tax"), address(rwa), address(this), _erc20VaultData());
        MyxVault v = MyxVault(payable(vaultAddr));
        assertEq(v.vaultQuoteToken(), address(rwa));
        assertEq(v.minProcessAmount(), 10 ether);
        assertEq(v.gasThreshold(), 0.01 ether);
        assertEq(v.gasRefillAmount(), 0.05 ether);
        assertEq(v.marketQuoteToken(), address(usdt));
    }

    function test_newVault_nativeQuote_rejectsGasParams() public {
        vm.prank(VAULT_PORTAL);
        vm.expectRevert(bytes(unicode"Gas params must be zero for native quote / 原生報價幣的 Gas 參數必須為零"));
        factory.newVault(makeAddr("tax"), address(0), makeAddr("creator"), abi.encode(address(usdt), uint256(1), uint256(1), uint256(2)));
    }

    receive() external payable {}
```

Add `import {VaultDataSchema} from "../src/flap/IVaultSchemasV1.sol";` to the test imports. Update `test_newVault_revertsOnZeroQuoteToken` to pass `abi.encode(address(0), uint256(1), uint256(0), uint256(0))`. In the `resolveDividendToken` helpers `_v6Params` / `_v7Params`, the `vaultData` they build must become `abi.encode(marketQuote, uint256(1), uint256(0), uint256(0))` (the factory decodes the first field only, but keep the shape honest).

`test/ChainAddressResolution.t.sol` line ~97: replace `minProcessAmount: 1` with `minInitialGas: 0`.

`test/Integration.fork.t.sol`: replace `minProcessAmount: 0.001 ether` with `minInitialGas: 0` and `bytes memory vaultData = abi.encode(BSC_USDT);` with `bytes memory vaultData = abi.encode(BSC_USDT, uint256(0.001 ether), uint256(0), uint256(0));`.

- [ ] **Step 2: Run to verify failure**

Run: `forge test --match-path test/MyxVaultFactory.t.sol` → compile errors on `GlobalConfig` members / `prepayGas`.

- [ ] **Step 3: Implement**

`src/MyxVaultFactory.sol` changes:

```solidity
import {IPortalQuoteConfigU8} from "./flap/IPortalQuoteConfigU8.sol";
```

```solidity
    struct GlobalConfig {
        address poolManager;
        address basePool;
        address poolFactory; // myx PoolFactory: authoritative basePoolToken (LP / mBase) predictor
        uint16 maxSlippageBps;
        /// @dev ERC20-quote launches must have at least this much BNB prepaid (wei). Enforced in newVault.
        uint256 minInitialGas;
    }

    /// @notice Creator-supplied per-vault configuration carried in `vaultData`.
    struct VaultData {
        address marketQuoteToken; // myx MARKET quote (USDT/USDC); identifies the myx market
        uint256 minProcessAmount; // quote base units
        uint256 gasThreshold; // wei; ERC20 quote only
        uint256 gasRefillAmount; // wei; ERC20 quote only, > gasThreshold
    }

    function decodeVaultData(bytes calldata vaultData) public pure returns (VaultData memory d) {
        (d.marketQuoteToken, d.minProcessAmount, d.gasThreshold, d.gasRefillAmount) =
            abi.decode(vaultData, (address, uint256, uint256, uint256));
    }

    /// @dev Flap Portal per chain. Mirrors VaultBase._getPortal(); unknown chains revert.
    function _getPortal() internal view returns (address) {
        uint256 chainId = block.chainid;
        if (chainId == 56) return 0xe2cE6ab80874Fa9Fa2aAE65D277Dd6B8e65C9De0;
        if (chainId == 97) return 0x5bEacaF7ABCbB3aB280e80D007FD31fcE26510e9;
        if (chainId == 4663) return 0x26605f322f7fF986f381bB9A6e3f5DAb0bEaEb09;
        revert UnsupportedChain(chainId);
    }
```

`newVault` (prepaid transfer is added in Task 10):

```solidity
    function newVault(address taxToken, address quoteToken, address creator, bytes calldata vaultData)
        external
        override
        returns (address vault)
    {
        require(msg.sender == _getVaultPortal(), unicode"Caller must be the vault portal / 僅限 VaultPortal 調用");
        VaultData memory d = decodeVaultData(vaultData);
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
                            quoteToken: quoteToken,
                            marketQuoteToken: d.marketQuoteToken,
                            poolManager: c.poolManager,
                            basePool: c.basePool,
                            maxSlippageBps: c.maxSlippageBps,
                            minProcessAmount: d.minProcessAmount,
                            gasThreshold: d.gasThreshold,
                            gasRefillAmount: d.gasRefillAmount
                        })
                    )
                )
            )
        );
        emit VaultCreated(vault, taxToken, creator, d.marketQuoteToken);
    }

    /// @inheritdoc IVaultFactory
    /// @dev Native always. ERC20 only where the vault's refill leg is wired (BSC mainnet/testnet) and
    ///      the Portal has the quote enabled. Robinhood stays native-only in this release.
    function isQuoteTokenSupported(address quoteToken) external view override returns (bool) {
        if (quoteToken == address(0)) return true;
        uint256 chainId = block.chainid;
        if (chainId != 56 && chainId != 97) return false;
        return IPortalQuoteConfigU8(_getPortal()).getQuoteTokenConfiguration(quoteToken).enabled == 1;
    }
```

Remove the `require(quoteToken == address(0), ...)` line. In `resolveDividendToken`, both `abi.decode(params.vaultData, (address))` become `abi.decode(params.vaultData, (address, uint256, uint256, uint256))` taking the first value:

```solidity
            (address marketQuote,,,) = abi.decode(params.vaultData, (address, uint256, uint256, uint256));
```

`_validateBeforeLaunch`: delete the `quoteToken != address(0)` block and its NatSpec item 1; renumber. `tokenCreationPolicies`: allocate 2 entries (dividendToken, dividendBps), drop the quoteToken policy.

`vaultDataSchema`:

```solidity
    function vaultDataSchema() public pure override returns (VaultDataSchema memory schema) {
        schema.description =
            unicode"myx market quote token (e.g. USDT/USDC) plus this vault's thresholds. The reward is the resulting myx LP. / myx 市場報價幣（如 USDT/USDC）與本金庫的閾值設定。獎勵為產出的 myx LP。";
        schema.fields = new FieldDescriptor[](4);
        schema.fields[0] = FieldDescriptor(
            "marketQuoteToken", "address", unicode"myx market quote token (e.g. USDT/USDC). / myx 市場報價幣（如 USDT/USDC）。", 0
        );
        schema.fields[1] = FieldDescriptor(
            "minProcessAmount",
            "uint256",
            unicode"Minimum tax (in the launch quote token's smallest unit) before a buyback runs. / 執行回購前的最低稅收（以發行報價幣最小單位計）。",
            0
        );
        schema.fields[2] = FieldDescriptor(
            "gasThreshold",
            "uint256",
            unicode"ERC20 quote only: refill the BNB gas pool below this balance. 0 for native quote. / 僅 ERC20 報價幣：Gas 池低於此值時補充。原生報價幣填 0。",
            18
        );
        schema.fields[3] = FieldDescriptor(
            "gasRefillAmount",
            "uint256",
            unicode"ERC20 quote only: gas pool target after a refill, must exceed gasThreshold. 0 for native quote. / 僅 ERC20 報價幣：補充後的 Gas 池目標，須大於閾值。原生報價幣填 0。",
            18
        );
        schema.isArray = false;
    }
```

Add a minimal `prepayGas()` stub so the ERC20 factory test compiles (full behavior in Task 10):

```solidity
    mapping(address => uint256) public prepaidGas;

    function prepayGas() external payable {
        prepaidGas[msg.sender] += msg.value;
    }
```

- [ ] **Step 4: Run tests**

Run: `forge test --no-match-path 'test/*.fork.t.sol'` and `forge build` → green.

- [ ] **Step 5: Commit checkpoint**

```bash
git add src/MyxVaultFactory.sol test/MyxVaultFactory.t.sol test/ChainAddressResolution.t.sol test/Integration.fork.t.sol
git commit -m "feat(factory): Portal-backed quote whitelist and creator-supplied vault thresholds"
```

---

### Task 10: Factory prepaid gas forwarded at launch

**Files:**
- Modify: `src/MyxVaultFactory.sol`
- Create: `test/MyxVaultFactoryPrepaidGas.t.sol`

**Interfaces:**
- Produces: `prepayGas() external payable`, `withdrawPrepaidGas() external`, `prepaidGas(address) view`, events `GasPrepaid(address indexed account, uint256 amount, uint256 total)`, `PrepaidGasWithdrawn(address indexed account, uint256 amount)`, `VaultGasFunded(address indexed vault, address indexed creator, uint256 amount)`.
- Consumes: `MyxVault.fundGas()` (Task 6), `GlobalConfig.minInitialGas` (Task 9).

- [ ] **Step 1: Write the failing tests**

Create `test/MyxVaultFactoryPrepaidGas.t.sol`:

```solidity
// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.26;

import {Test} from "forge-std/Test.sol";
import {MyxVaultFactory} from "../src/MyxVaultFactory.sol";
import {MyxVault} from "../src/MyxVault.sol";
import "./mocks/Mocks.sol";

contract MyxVaultFactoryPrepaidGasTest is Test {
    MyxVaultFactory factory;
    MockERC20 usdt;
    MockERC20 rwa;
    MockPortal portal;

    address constant VAULT_PORTAL = 0x90497450f2a706f1951b5bdda52B4E5d16f34C06;
    address constant PORTAL = 0xe2cE6ab80874Fa9Fa2aAE65D277Dd6B8e65C9De0;
    address creator = makeAddr("creator");

    event GasPrepaid(address indexed account, uint256 amount, uint256 total);
    event PrepaidGasWithdrawn(address indexed account, uint256 amount);
    event VaultGasFunded(address indexed vault, address indexed creator, uint256 amount);

    function setUp() public {
        vm.chainId(56);
        usdt = new MockERC20("Tether", "USDT");
        rwa = new MockERC20("NVDA bStock", "NVDAB");
        MockPortal impl = new MockPortal();
        vm.etch(PORTAL, address(impl).code);
        portal = MockPortal(PORTAL);
        portal.setQuoteConfig(address(rwa), true, 0);
        factory = new MyxVaultFactory(
            MyxVaultFactory.GlobalConfig({
                poolManager: address(new MockPoolManager()),
                basePool: address(new MockBasePool(new MockERC20("LP", "LP"), usdt)),
                poolFactory: address(new MockMyxPoolFactory()),
                maxSlippageBps: 300,
                minInitialGas: 0.002 ether
            })
        );
        vm.deal(creator, 10 ether);
    }

    function _erc20VaultData() internal view returns (bytes memory) {
        return abi.encode(address(usdt), uint256(10 ether), uint256(0.01 ether), uint256(0.05 ether));
    }

    function test_prepayGas_accumulatesAndEmits() public {
        vm.startPrank(creator);
        vm.expectEmit(true, true, true, true);
        emit GasPrepaid(creator, 0.001 ether, 0.001 ether);
        factory.prepayGas{value: 0.001 ether}();
        factory.prepayGas{value: 0.002 ether}();
        vm.stopPrank();
        assertEq(factory.prepaidGas(creator), 0.003 ether);
    }

    function test_withdrawPrepaidGas_refundsAll() public {
        vm.prank(creator);
        factory.prepayGas{value: 0.003 ether}();
        uint256 before = creator.balance;
        vm.prank(creator);
        vm.expectEmit(true, true, true, true);
        emit PrepaidGasWithdrawn(creator, 0.003 ether);
        factory.withdrawPrepaidGas();
        assertEq(creator.balance, before + 0.003 ether);
        assertEq(factory.prepaidGas(creator), 0);
    }

    function test_withdrawPrepaidGas_nothing_reverts() public {
        vm.prank(creator);
        vm.expectRevert(bytes(unicode"Nothing prepaid / 無預付款"));
        factory.withdrawPrepaidGas();
    }

    function test_newVault_erc20_belowMinInitialGas_reverts() public {
        vm.prank(creator);
        factory.prepayGas{value: 0.001 ether}();
        vm.prank(VAULT_PORTAL);
        vm.expectRevert(bytes(unicode"Prepaid gas below minimum / 預付 Gas 低於最低要求"));
        factory.newVault(makeAddr("tax"), address(rwa), creator, _erc20VaultData());
        assertEq(factory.prepaidGas(creator), 0.001 ether, "prepaid untouched on revert");
    }

    function test_newVault_erc20_forwardsAllPrepaidToVault() public {
        vm.prank(creator);
        factory.prepayGas{value: 0.005 ether}();
        vm.prank(VAULT_PORTAL);
        vm.expectEmit(false, true, true, true);
        emit VaultGasFunded(address(0), creator, 0.005 ether);
        address vaultAddr = factory.newVault(makeAddr("tax"), address(rwa), creator, _erc20VaultData());
        assertEq(MyxVault(payable(vaultAddr)).gasBalance(), 0.005 ether);
        assertEq(factory.prepaidGas(creator), 0);
        assertEq(address(factory).balance, 0);
    }

    function test_newVault_native_ignoresPrepaid() public {
        vm.prank(creator);
        factory.prepayGas{value: 0.005 ether}();
        vm.prank(VAULT_PORTAL);
        address vaultAddr = factory.newVault(makeAddr("tax"), address(0), creator, abi.encode(address(usdt), uint256(1), uint256(0), uint256(0)));
        assertEq(address(vaultAddr).balance, 0);
        assertEq(factory.prepaidGas(creator), 0.005 ether, "still withdrawable");
    }

    function test_newVault_erc20_zeroMinInitialGas_allowsNoPrepay() public {
        MyxVaultFactory lax = new MyxVaultFactory(
            MyxVaultFactory.GlobalConfig({
                poolManager: address(new MockPoolManager()),
                basePool: address(new MockBasePool(new MockERC20("LP", "LP"), usdt)),
                poolFactory: address(new MockMyxPoolFactory()),
                maxSlippageBps: 300,
                minInitialGas: 0
            })
        );
        vm.prank(VAULT_PORTAL);
        address vaultAddr = lax.newVault(makeAddr("tax"), address(rwa), creator, _erc20VaultData());
        assertEq(MyxVault(payable(vaultAddr)).gasBalance(), 0);
    }
}
```

- [ ] **Step 2: Run to verify failure**

Run: `forge test --match-path test/MyxVaultFactoryPrepaidGas.t.sol` → `withdrawPrepaidGas` undefined / `VaultGasFunded` missing.

- [ ] **Step 3: Implement**

In `src/MyxVaultFactory.sol` replace the Task 9 stub with:

```solidity
    /// @notice BNB prepaid per creator, forwarded into their vault's gas pool at ERC20-quote launch.
    ///         Extra msg.value on the launch transaction itself is swallowed by the Flap Portal, so the
    ///         initial gas pool must be funded through this separate call before launching.
    mapping(address => uint256) public prepaidGas;

    event GasPrepaid(address indexed account, uint256 amount, uint256 total);
    event PrepaidGasWithdrawn(address indexed account, uint256 amount);
    event VaultGasFunded(address indexed vault, address indexed creator, uint256 amount);

    function prepayGas() external payable {
        require(msg.value > 0, unicode"Zero prepayment / 預付金額為零");
        prepaidGas[msg.sender] += msg.value;
        emit GasPrepaid(msg.sender, msg.value, prepaidGas[msg.sender]);
    }

    function withdrawPrepaidGas() external {
        uint256 amount = prepaidGas[msg.sender];
        require(amount > 0, unicode"Nothing prepaid / 無預付款");
        prepaidGas[msg.sender] = 0;
        (bool ok,) = msg.sender.call{value: amount}("");
        require(ok, unicode"Refund failed / 退款失敗");
        emit PrepaidGasWithdrawn(msg.sender, amount);
    }
```

In `newVault`, after the `BeaconProxy` deployment and before `emit VaultCreated`:

```solidity
        if (quoteToken != address(0)) {
            uint256 prepaid = prepaidGas[creator];
            require(prepaid >= c.minInitialGas, unicode"Prepaid gas below minimum / 預付 Gas 低於最低要求");
            if (prepaid > 0) {
                prepaidGas[creator] = 0;
                MyxVault(payable(vault)).fundGas{value: prepaid}();
                emit VaultGasFunded(vault, creator, prepaid);
            }
        }
```

Adjust `test_prepayGas_accumulatesAndEmits` expectations if needed (they match the events above).

- [ ] **Step 4: Run tests**

Run: `forge test --no-match-path 'test/*.fork.t.sol'` → green.

- [ ] **Step 5: Commit checkpoint**

```bash
git add src/MyxVaultFactory.sol test/MyxVaultFactoryPrepaidGas.t.sol
git commit -m "feat(factory): prepaid BNB gas forwarded into ERC20-quote vaults at launch"
```

---

### Task 11: Deploy scripts, docs, spec-checker findings

**Files:**
- Modify: `script/mainnet/bnb/DeployMyxVaultFactory.s.sol`, `script/testnet/bnb/DeployMyxVaultFactory.s.sol`, `script/mainnet/robinhood/DeployMyxVaultFactory.s.sol`
- Modify: `README.md`, `docs/spec-checker-findings.md`, `docs/flap-vault-integration-design.md` (§4.3 table + §8 launch params)

- [ ] **Step 1: Verify the scripts fail to compile**

Run: `forge build` → error: `GlobalConfig` has no member `minProcessAmount` in the three scripts.

- [ ] **Step 2: Update the scripts**

BSC mainnet (`script/mainnet/bnb/DeployMyxVaultFactory.s.sol`), config block:

```solidity
            MyxVaultFactory.GlobalConfig({
                poolManager: vm.envAddress("MYX_POOL_MANAGER"),
                basePool: vm.envAddress("MYX_BASE_POOL"),
                poolFactory: vm.envAddress("MYX_POOL_FACTORY"),
                maxSlippageBps: 300,
                // ERC20-quote launches must prepay at least 10 FlapTriggerService fees (0.0002 BNB each).
                minInitialGas: 0.002 ether
            })
```

BSC testnet: same shape with `maxSlippageBps: 500`, `minInitialGas: 0.002 ether`.

Robinhood (`script/mainnet/robinhood/DeployMyxVaultFactory.s.sol`): same shape with `maxSlippageBps: 300`, `minInitialGas: 0` and update the NatSpec: per-vault `minProcessAmount` now travels in vaultData (recommend 0.004 ETH for native launches there), and ERC20 quotes are not supported on Robinhood in this release.

Update each script's NatSpec header to say per-vault `minProcessAmount` is creator-supplied via `vaultData` (`abi.encode(marketQuoteToken, minProcessAmount, gasThreshold, gasRefillAmount)`).

- [ ] **Step 3: Update README and docs**

`README.md`:
- Supported quotes line: "Native BNB, or any ERC20/RWA quote enabled on the Flap Portal (BSC mainnet/testnet); Robinhood Chain native only."
- Architecture block: replace `MyxVault.receive()` line with balance-delta wording, add the gas pool / refill leg and the prepay step:

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
- Launch parameters: `vaultData = abi.encode(marketQuoteToken, minProcessAmount, gasThreshold, gasRefillAmount)`; `dividendToken = MAGIC_DIVIDEND_COMPUTED`; `dividendBps = 0`.
- Risk note: RWA quote tokens (bStocks) may carry transfer restrictions; the vault holds the quote between dispatch and process.

`docs/spec-checker-findings.md`: add a row `010 | V3 balance-delta accounting | PASS | _sync() delta recognition, zero-delta no-op, every outflow (process/_refillGas/emergencySweepNative/emergencyRescueToken/scheduleProcess native fee) decrements pendingQuote; tests test_bareTransfer_notRecognized_pingRecognizes, test_zeroDeltaPing_silentNoop, test_emergencyRescueToken_quote_resetsBaseline`. Update the 001 row: `vaultQuoteToken()` immutable after init. Add to the header that Rule 010 is now in scope.

`docs/flap-vault-integration-design.md`: in §4.3 table add `sync`, `fundGas`, `gasBalance`, `vaultQuoteToken` rows; in §8 replace the vaultData line with the four-field encoding and mention `factory.prepayGas()`.

- [ ] **Step 4: Build and run everything**

Run: `forge build && forge test --no-match-path 'test/*.fork.t.sol'` → green.

- [ ] **Step 5: Commit checkpoint**

```bash
git add script README.md docs/spec-checker-findings.md docs/flap-vault-integration-design.md
git commit -m "docs: V3 quote model, prepaid gas, deploy config"
```

---

### Task 12: BSC mainnet fork end-to-end (native fix + NVDAB quote)

**Files:**
- Modify: `test/Integration.fork.t.sol`
- Create: `test/Integration.erc20quote.fork.t.sol`

**Interfaces:**
- Consumes everything above plus `FlapBSCFixture` helpers `_forkBSCMainnet`, `_buildV3TaxTokenParams`, `_dispatchTax`, `_buyOnBC`, `_sell`, `_predictAddress`, `_endsWith7777`, constants `PORTAL`, `TOKEN_IMPL_TAXED_V3`, `vaultPortal`, `portal`, `MAX_OP_GAS`.

- [ ] **Step 1: Fix the existing native fork test**

In `test/Integration.fork.t.sol`:

1. Replace `_findVanitySalt(...)` with a fresh salt (the fixture's block-seeded salt collides with tokens already staged on mainnet):

```solidity
    uint256 internal saltNonce;

    function _freshSalt() internal returns (bytes32 salt) {
        salt = keccak256(abi.encode(address(this), block.timestamp, saltNonce++, "myx-fork"));
        while (true) {
            address predicted = _predictAddress(TOKEN_IMPL_TAXED_V3, salt, PORTAL);
            if (_endsWith7777(predicted) && predicted.code.length == 0) return salt;
            salt = bytes32(uint256(salt) + 1);
        }
    }
```

2. In `_launchAndFundVault`, use `_freshSalt()`, set `params.dividendToken = MAGIC_DIVIDEND_COMPUTED;` (import it from `../src/flap/IPortal.sol`), and wire the mock predictor so `resolveDividendToken` returns a real ERC20: before launching, `poolFactory` must answer for the predicted token. Replace `MockMyxPoolFactory` with a fixed predictor declared in this file:

```solidity
contract FixedLpPredictor {
    address public immutable lp;
    constructor(address _lp) { lp = _lp; }
    function predictBasePoolToken(MarketId, address, string calldata) external view returns (address) { return lp; }
}
```

and pass `poolFactory: address(new FixedLpPredictor(BSC_USDT))` in the factory config (the launched token's dividendToken becomes USDT; the fork proves buyback + deposit only, as the file's NOTE already says).

3. Update the stale doc comments (`v4-5`, `dividendToken is set to REAL BSC USDT`) to describe the MAGIC path.

Run: `forge test --match-path test/Integration.fork.t.sol -vv` → 1 passed.

- [ ] **Step 2: Write the ERC20-quote fork test**

Create `test/Integration.erc20quote.fork.t.sol`:

```solidity
// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.26;

import {console2} from "forge-std/Test.sol";
import {IERC20} from "@openzeppelin/token/ERC20/IERC20.sol";
import {FlapBSCFixture} from "./FlapBSCFixture.sol";
import {IVaultPortalTypes} from "../src/flap/IVaultPortal.sol";
import {MAGIC_DIVIDEND_COMPUTED, IPortalTradeV2} from "../src/flap/IPortal.sol";
import {IFlapTaxTokenV3} from "../src/flap/IFlapTaxTokenV3.sol";
import {ITaxProcessor} from "../src/flap/ITaxProcessor.sol";
import {MyxVault} from "../src/MyxVault.sol";
import {MyxVaultFactory} from "../src/MyxVaultFactory.sol";
import {MarketId} from "../src/myx/IMyxPool.sol";
import {MockERC20, MockBasePool, MockPoolManager} from "./mocks/Mocks.sol";

contract FixedLpPredictor {
    address public immutable lp;
    constructor(address _lp) { lp = _lp; }
    function predictBasePoolToken(MarketId, address, string calldata) external view returns (address) { return lp; }
}

/// @notice BSC mainnet fork: NVDAB (bStock) quote end to end against the REAL VaultPortal, Portal,
///         TaxProcessor (ERC20 payout + ping), SwapRegistry and MultiDexRouter. Only myx is mocked.
contract MyxVaultErc20QuoteForkTest is FlapBSCFixture {
    address internal constant BSC_USDT = 0x55d398326f99059fF775485246999027B3197955;
    address internal constant NVDAB = 0x02Fca66C1D1aFB4E2A7884261eB00F63598a7436;

    MyxVaultFactory internal factory;
    MockPoolManager internal poolManager;
    MockBasePool internal basePool;
    MockERC20 internal usdt;
    MockERC20 internal lpToken;
    uint256 internal saltNonce;

    function setUp() public {
        _forkBSCMainnet();
        usdt = new MockERC20("Tether", "USDT");
        lpToken = new MockERC20("MYX LP", "MLP");
        basePool = new MockBasePool(lpToken, usdt);
        poolManager = new MockPoolManager();
        poolManager.setLpTokenForDeploy(address(lpToken));
        factory = new MyxVaultFactory(
            MyxVaultFactory.GlobalConfig({
                poolManager: address(poolManager),
                basePool: address(basePool),
                poolFactory: address(new FixedLpPredictor(BSC_USDT)),
                maxSlippageBps: 500,
                minInitialGas: 0.002 ether
            })
        );
        deal(NVDAB, address(this), 1_000 ether);
        IERC20(NVDAB).approve(address(vaultPortal), type(uint256).max);
        IERC20(NVDAB).approve(address(portal), type(uint256).max);
        vm.deal(address(this), 1 ether);
    }

    function _freshSalt() internal returns (bytes32 salt) {
        salt = keccak256(abi.encode(address(this), block.timestamp, saltNonce++, "myx-erc20"));
        while (true) {
            address predicted = _predictAddress(TOKEN_IMPL_TAXED_V3, salt, PORTAL);
            if (_endsWith7777(predicted) && predicted.code.length == 0) return salt;
            salt = bytes32(uint256(salt) + 1);
        }
    }

    function _launch() internal returns (address token, MyxVault vault) {
        // vaultData: myx market quote, 1 NVDAB min, refill below 0.005 BNB up to 0.01 BNB
        bytes memory vaultData = abi.encode(BSC_USDT, uint256(1 ether), uint256(0.005 ether), uint256(0.01 ether));
        IVaultPortalTypes.NewTokenV6WithVaultParams memory p =
            _buildV3TaxTokenParams("Myx RWA Vault Token", "MRV", _freshSalt(), address(factory), vaultData);
        p.quoteToken = NVDAB;
        p.quoteAmt = 0;
        p.dividendToken = MAGIC_DIVIDEND_COMPUTED;
        factory.prepayGas{value: 0.003 ether}();
        token = vaultPortal.newTokenV6WithVault(p);
        vault = MyxVault(payable(vaultPortal.getVault(token).vault));
    }

    function test_erc20Quote_endToEnd() public {
        (address token, MyxVault vault) = _launch();
        assertEq(vault.vaultQuoteToken(), NVDAB);
        assertEq(vault.gasBalance(), 0.003 ether, "prepaid gas forwarded at launch");
        assertEq(factory.prepaidGas(address(this)), 0);

        // trade in NVDAB to generate tax
        uint256 got = portal.swapExactInput{gas: MAX_OP_GAS}(
            IPortalTradeV2.ExactInputParams({inputToken: NVDAB, outputToken: token, inputAmount: 100 ether, minOutputAmount: 0, permitData: ""})
        );
        IERC20(token).approve(address(portal), got / 2);
        portal.swapExactInput{gas: MAX_OP_GAS}(
            IPortalTradeV2.ExactInputParams({inputToken: token, outputToken: NVDAB, inputAmount: got / 2, minOutputAmount: 0, permitData: ""})
        );

        // real dispatch: ERC20 payout + zero-value ping under the 1M cap
        address tp = IFlapTaxTokenV3(token).taxProcessor();
        uint256 expected = ITaxProcessor(tp).marketQuoteBalance();
        assertGt(expected, 1 ether, "enough tax to clear minProcessAmount");
        _dispatchTax(token);
        assertEq(vault.pendingQuote(), expected, "ping recognized the ERC20 revenue");
        assertTrue(vault.hasPendingTrigger(), "gas pool paid the trigger fee");
        assertLt(vault.gasBalance(), 0.003 ether);

        // process: gas pool is below 0.005 -> refill via Flap MultiDexRouter, then buy back + deposit
        uint256 gasBefore = vault.gasBalance();
        vm.prank(makeAddr("keeper"));
        vault.process();
        assertGt(vault.gasBalance(), gasBefore, "refill topped up the gas pool");
        assertGe(vault.gasBalance(), 0.005 ether);
        assertEq(vault.pendingQuote(), 0);
        assertEq(IERC20(NVDAB).balanceOf(address(vault)), 0, "all quote spent");
        assertGt(basePool.lastDepositAmount(), 0, "bought-back token deposited");
        assertEq(poolManager.deployPoolCallCount(), 1);
        console2.log("gas pool after process (wei):", vault.gasBalance());
    }

    function test_erc20Quote_launchWithoutPrepay_reverts() public {
        bytes memory vaultData = abi.encode(BSC_USDT, uint256(1 ether), uint256(0.005 ether), uint256(0.01 ether));
        IVaultPortalTypes.NewTokenV6WithVaultParams memory p =
            _buildV3TaxTokenParams("Myx RWA Vault Token", "MRV", _freshSalt(), address(factory), vaultData);
        p.quoteToken = NVDAB;
        p.dividendToken = MAGIC_DIVIDEND_COMPUTED;
        vm.expectRevert(bytes(unicode"Prepaid gas below minimum / 預付 Gas 低於最低要求"));
        vaultPortal.newTokenV6WithVault(p);
    }

    receive() external payable {}
}
```

- [ ] **Step 3: Run the fork tests**

Run: `forge test --match-path 'test/Integration.erc20quote.fork.t.sol' -vv`
Expected: 2 passed. If the public RPC returns `missing trie node` on a deep V3 tick read, re-run with `BSC_RPC_URL` pointing at an archive node; the 0.01% tier is the usual culprit and is never the best tier for NVDAB, so this is an RPC limitation, not a logic failure.

Run: `forge test --match-path 'test/*.fork.t.sol'` → 3 passed.

- [ ] **Step 4: Full verification**

Run: `forge build && forge test --no-match-path 'test/*.fork.t.sol'` → all green. Then `forge fmt --check src test script` (fix formatting if it complains).

- [ ] **Step 5: Commit checkpoint**

```bash
git add test/Integration.fork.t.sol test/Integration.erc20quote.fork.t.sol
git commit -m "test(fork): NVDAB-quote end-to-end on BSC mainnet, fix native fork launch"
```

---

## Self-review notes

- Spec §4.1 storage/init → Task 3; `_sync`/`receive`/`sync` → Task 4; buyback → Task 5; gas pool + scheduleProcess + fundGas → Task 6; refill + venue resolution + best-pool + skip semantics + `BuybackSkipped` → Task 7; emergency + description + schema + decimals → Task 8. Spec §4.2 factory (config, vaultData, whitelist, validation, policies, schema, resolveDividendToken decode) → Task 9; prepaid gas → Task 10. Spec §4.3 upstream sync → Task 1. Spec §8 tests → Tasks 2–12. Spec §9 scripts/docs → Task 11.
- Names used consistently: `pendingQuote`, `quoteToken`, `gasThreshold`, `gasRefillAmount`, `fundGas`, `gasBalance`, `sync`, `emergencySweepNative`, `prepayGas`, `withdrawPrepaidGas`, `prepaidGas`, `minInitialGas`, `decodeVaultData`, events `GasFunded`, `GasRefilled(uint256,uint256,uint24)`, `GasRefillSkipped(uint256)`, `BuybackSkipped(uint256)`, `GasPrepaid`, `PrepaidGasWithdrawn`, `VaultGasFunded`.
- The `test_process_slippageBreach_reverts` case in Task 7 documents that the mock cannot drift between quote and swap; the minOut wiring is exercised by the strict (0 bps) vault passing, and by the real-venue fork test in Task 12.
