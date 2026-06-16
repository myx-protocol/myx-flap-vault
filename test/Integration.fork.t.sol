// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.26;

import {console2} from "forge-std/Test.sol";
import {IERC20} from "@openzeppelin/token/ERC20/IERC20.sol";

import {FlapBSCFixture} from "./FlapBSCFixture.sol";
import {IVaultPortalTypes} from "../src/flap/IVaultPortal.sol";
import {IPortalTradeV2} from "../src/flap/IPortal.sol";

import {MyxVault} from "../src/MyxVault.sol";
import {MyxVaultFactory} from "../src/MyxVaultFactory.sol";
import {MarketId, PoolId, MyxPoolId, MyxMarketId} from "../src/myx/IMyxPool.sol";

import {MockERC20, MockBasePool, MockPoolManager, MockMyxPoolFactory} from "./mocks/Mocks.sol";

/// @title MyxVaultForkTest
/// @notice BSC mainnet fork end-to-end proof of the v6 buyback flow: launches a REAL Flap V3
///         tax token through the REAL VaultPortal pointed at OUR MyxVaultFactory, trades to
///         generate tax, dispatches the real TaxProcessor under a 1M gas cap (the live proof
///         of Flap Rule 005 compliance), then has ANY caller invoke the permissionless
///         process(): the vault buys back THE LAUNCHED TOKEN via the REAL Portal
///         (swapExactInput on its bonding curve) and deposits the balance delta into the
///         mock MYX base pool, auto-deploying the token-keyed pool on first use.
///
/// @dev Only the MYX-side infrastructure (PoolManager / BasePool / USDT / LP token) is mocked.
///      WBNB, PancakeRouter and the Chainlink feeds are wired to their REAL BSC addresses so
///      the factory config mirrors a production deployment. The buyback leg exercises the
///      REAL Portal quote-vs-swap basis: if quoteExactInput and swapExactInput disagreed
///      beyond maxSlippageBps the swap would revert. maxSlippageBps is 500 (5%) to absorb
///      the bonding-curve price impact of the vault's own buy (quoteExactInput is evaluated
///      pre-trade in the same block; the swap itself moves the curve).
contract MyxVaultForkTest is FlapBSCFixture {
    // ── Real BSC mainnet addresses (docs/phase0-findings.md) ──────────────────
    address internal constant WBNB = 0xbb4CdB9CBd36B01bD1cBaEBF2De08d9173bc095c;
    address internal constant PANCAKE_ROUTER = 0x10ED43C718714eb63d5aA57B78B54704E256024E;
    address internal constant BNB_USD_FEED = 0x0567F2323251f0Aab15c8dFb1967E4e8A7D42aeE;
    address internal constant USDT_USD_FEED = 0xB97Ad0E74fa7d920791E90258A6E2085088b4320;
    // Real BSC USDT (18 decimals). Used as the launched token's dividendToken so the launch
    // clears the factory's _validateBeforeLaunch precheck (native/self dividend are rejected),
    // and as the mock pool's quoteToken so harvest reads a real ERC20 (zero balance no-op).
    address internal constant BSC_USDT = 0x55d398326f99059fF775485246999027B3197955;

    // v4-5: the vault derives the MYX marketId on-chain from (block.chainid, quoteToken). The launch
    // passes BSC_USDT as the quote token (= the launched token's dividendToken), so the expected
    // marketId mirrors keccak256(56, BSC_USDT). chainId 56 holds on the BSC mainnet fork.
    MarketId internal marketId = MyxMarketId.derive(uint64(56), BSC_USDT);

    // ── Our deployments on the fork ───────────────────────────────────────────
    MyxVaultFactory internal factory;
    MockPoolManager internal poolManager;
    MockMyxPoolFactory internal poolFactory;
    MockBasePool internal basePool;
    MockERC20 internal usdt;
    MockERC20 internal lpToken;

    function setUp() public {
        _forkBSCMainnet();

        // Deploy the mocked MYX infrastructure. The real BasePool pulls base token on deposit;
        // the mock mints LP 1:1, does NOT pull the deposit, and tracks calls for assertions.
        usdt = new MockERC20("Tether", "USDT");
        lpToken = new MockERC20("MYX LP", "MLP");
        basePool = new MockBasePool(lpToken, usdt);
        poolManager = new MockPoolManager();
        poolFactory = new MockMyxPoolFactory();

        // Deploy OUR factory: MYX side pointed at the mocks.
        // TODO(v6): rework the dividend assertions for the v2.3 resolveDividendToken path — the
        // launched token will carry MAGIC_DIVIDEND_COMPUTED and the dividend token is the myx mBase
        // LP resolved via factory.resolveDividendToken(predicted, launchVersion, launchParams), not BSC_USDT. This fork
        // test proves only the permissionless buyback + deposit leg; the dividend-feed leg against a
        // real wired LP dividend stays unit-tested. The poolFactory mock here is wired only so the
        // constructor config is well-formed.
        factory = new MyxVaultFactory(
            MyxVaultFactory.GlobalConfig({
                poolManager: address(poolManager),
                basePool: address(basePool),
                poolFactory: address(poolFactory),
                // 5%: the buyback minOut is bounded by a pre-trade same-block Portal quote,
                // so the bound must absorb the curve impact of the vault's own buy.
                maxSlippageBps: 500,
                minProcessAmount: 0.001 ether // small so a modest trade clears it
            })
        );

        // NOTE: no pool pre-registration. The pool key is derived from the LAUNCHED token
        // address (unknown until the test runs), and process() must prove the
        // auto-deploy path via poolManager.deployPool().

        vm.label(WBNB, "WBNB");
        vm.label(PANCAKE_ROUTER, "PancakeRouter");
        vm.label(address(factory), "MyxVaultFactory");
    }

    /// @dev Shared launch + trade + dispatch flow used by BOTH fork tests. Launches a REAL Flap V3
    ///      tax token through the REAL VaultPortal pointed at OUR factory, trades on the bonding
    ///      curve to generate tax, then dispatches the real TaxProcessor under the 1M gas cap so the
    ///      vault is credited via receive(). Returns the launched token and its resolved vault, with
    ///      pendingBnb > 0.
    /// @dev dividendToken is set to REAL BSC USDT (not address(0)): the factory's _validateBeforeLaunch
    ///      now rejects native-BNB / self dividend, so the launch must carry a real ERC20 dividendToken
    ///      to clear onBeforeLaunch on the real VaultPortal.
    function _launchAndFundVault() internal returns (address token, MyxVault vault) {
        // 1. Launch a REAL Flap V3 tax token through the REAL VaultPortal, passing OUR factory.
        //    The VaultPortal will call factory.newVault(...) — the factory's _getVaultPortal()
        //    resolves to this same VaultPortal on chainId 56, so the access check passes.
        //    vaultData carries the single v4-5 field: the market quote token (= dividendToken).
        //    The vault derives marketId = keccak256(chainId, BSC_USDT) and the pool key from it.
        bytes memory vaultData = abi.encode(BSC_USDT);
        bytes32 salt = _findVanitySalt(VanityType.VANITY_7777, TOKEN_IMPL_TAXED_V3, PORTAL);

        IVaultPortalTypes.NewTokenV6WithVaultParams memory params =
            _buildV3TaxTokenParams("Myx Vault Token", "MVT", salt, address(factory), vaultData);
        params.dividendToken = BSC_USDT; // real ERC20: clears the factory dividend precheck

        token = vaultPortal.newTokenV6WithVault{value: params.quoteAmt}(params);
        assertTrue(token != address(0), "launch returned zero token");

        // Resolve the vault the VaultPortal created via our factory.
        IVaultPortalTypes.VaultInfo memory info = vaultPortal.getVault(token);
        vault = MyxVault(payable(info.vault));
        assertTrue(address(vault) != address(0), "vault not resolved");
        assertEq(vault.taxToken(), token, "vault taxToken mismatch");
        // v3: the pool key is derived from the launched token address.
        assertEq(
            PoolId.unwrap(vault.poolId()), PoolId.unwrap(MyxPoolId.derive(marketId, token)), "vault poolId mismatch"
        );

        // The creator role is granted to the token creator (the msg.sender of the VaultPortal
        // launch — this test contract). Verify the launch attribution.
        assertEq(vault.creator(), address(this), "creator must be the launch msg.sender");

        // 2. Trade to generate tax: buy on the bonding curve, then sell half back.
        vm.deal(address(this), 10 ether);
        _buyOnBC(token, 1 ether);

        uint256 sellAmount = IERC20(token).balanceOf(address(this)) / 2;
        assertGt(sellAmount, 0, "no tokens received from buy");
        vm.startPrank(address(this));
        _sell(token, sellAmount);
        vm.stopPrank();

        // 3. Dispatch tax via the REAL TaxProcessor under the 1M gas cap. This fans BNB out to
        //    the vault's receive() — the live proof of Flap Rule 005 compliance.
        _dispatchTax(token);

        // 4. The vault must have been credited through receive() (accounting only, no revert).
        assertGt(vault.pendingBnb(), 0, "dispatch must credit vault via receive()");
    }

    function test_endToEnd_launchTradeDispatchProcess() public {
        (address token, MyxVault vault) = _launchAndFundVault();

        uint256 dispatchedBnb = vault.pendingBnb();
        console2.log("dispatched BNB to vault (wei):", dispatchedBnb);

        // Pre-trade quote for the exact amount the vault is about to swap, on the same curve
        // state process() will see. This is the vault's own minOut basis; logged so a
        // slippage failure can be diagnosed against the observed quote/received pair.
        uint256 quoted = portal.quoteExactInput(
            IPortalTradeV2.QuoteExactInputParams({inputToken: address(0), outputToken: token, inputAmount: dispatchedBnb})
        );
        console2.log("portal quoteExactInput (token wei):", quoted);

        // 5. process() from a RANDOM caller (permissionless): buy back the launched token via the
        //    REAL Portal, then deposit the balance delta into the mock MYX base pool.
        vm.prank(makeAddr("keeper"));
        vault.process();

        // All pending BNB was consumed by the buyback.
        assertEq(vault.pendingBnb(), 0, "pendingBnb must zero after process");

        // Balance-delta accounting, end to end: the deposit amount recorded by the pool equals
        // the LP minted 1:1 to the vault AND the bought tokens still sitting in the vault
        // (MockBasePool records lastDepositAmount and mints LP but does NOT pull the tokens).
        uint256 deposited = basePool.lastDepositAmount();
        console2.log("bought + deposited token amount (wei):", deposited);
        assertGt(deposited, 0, "base pool deposit not invoked");
        assertEq(basePool.depositCallCount(), 1, "expected exactly one deposit");
        assertEq(lpToken.balanceOf(address(vault)), deposited, "LP minted must equal deposit amount");
        assertEq(
            IERC20(token).balanceOf(address(vault)), deposited, "vault token balance delta must equal deposit amount"
        );

        // Quote-vs-swap basis on the real Portal: the swap cleared the vault's minOut bound
        // (quoted * (1 - 5%)), otherwise process() would have reverted inside the Portal.
        assertGe(deposited, (quoted * 9_500) / 10_000, "received below the vault's own minOut bound");

        // Auto-deploy happened exactly once for the token-keyed pool (no pre-registration).
        assertEq(poolManager.deployPoolCallCount(), 1, "pool auto-deploy must run exactly once");
    }

    /// @dev Accept BNB so the EOA-style test contract can fund itself / receive trade proceeds.
    receive() external payable {}
}
