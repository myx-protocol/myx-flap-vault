// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.26;

import {Test} from "forge-std/Test.sol";
import {MyxVaultFactory} from "../src/MyxVaultFactory.sol";
import {MyxVault} from "../src/MyxVault.sol";
import {MarketId, PoolId, MyxPoolId, MyxMarketId, IMyxPoolFactory} from "../src/myx/IMyxPool.sol";
import {IVaultFactoryValidationV2, DIVIDEND_TOKEN_LAUNCH_VERSION_V6, DIVIDEND_TOKEN_LAUNCH_VERSION_V7} from "../src/flap/IVaultFactory.sol";
import {IVaultPortalTypes} from "../src/flap/IVaultPortal.sol";
import {MAGIC_DIVIDEND_COMPUTED} from "../src/flap/IPortal.sol";
import {VaultDataSchema, FactoryPolicy} from "../src/flap/IVaultSchemasV1.sol";
import "./mocks/Mocks.sol";

contract MyxVaultFactoryTest is Test {
    MyxVaultFactory factory;
    MockWBNB wbnb;
    MockERC20 usdt;
    MockERC20 usdc;
    MockAggregatorV3 bnbFeed;
    MockAggregatorV3 usdtFeed;
    MockBasePool basePool;
    MockPoolManager poolManager;
    MockMyxPoolFactory poolFactory;
    MockPancakeRouter router;

    address constant VAULT_PORTAL = 0x90497450f2a706f1951b5bdda52B4E5d16f34C06; // BSC mainnet
    address constant GUARDIAN = 0x9e27098dcD8844bcc6287a557E0b4D09C86B8a4b;
    address constant PORTAL = 0xe2cE6ab80874Fa9Fa2aAE65D277Dd6B8e65C9De0;
    MockPortal portal;
    MockERC20 rwa;
    // v4-5: the launch param is the market quote token; the vault derives marketId on-chain.
    // Assigned in setUp() once usdt exists; tests run on chainId 56.
    MarketId marketId;

    function setUp() public {
        vm.chainId(56);
        wbnb = new MockWBNB();
        usdt = new MockERC20("Tether", "USDT");
        usdc = new MockERC20("USD Coin", "USDC");
        marketId = MyxMarketId.derive(uint64(56), address(usdt));
        bnbFeed = new MockAggregatorV3(600e8, 8);
        usdtFeed = new MockAggregatorV3(1e8, 8);
        basePool = new MockBasePool(new MockERC20("LP", "LP"), usdt);
        poolManager = new MockPoolManager();
        poolFactory = new MockMyxPoolFactory();
        router = new MockPancakeRouter();
        rwa = new MockERC20("NVDA bStock", "NVDAB");
        MockPortal portalImpl = new MockPortal();
        vm.etch(PORTAL, address(portalImpl).code);
        portal = MockPortal(PORTAL);
        portal.setQuoteConfig(address(rwa), true, 0);

        factory = new MyxVaultFactory(_baseConfig());
    }

    function _baseConfig() internal view returns (MyxVaultFactory.GlobalConfig memory) {
        return MyxVaultFactory.GlobalConfig({
            poolManager: address(poolManager),
            basePool: address(basePool),
            poolFactory: address(poolFactory),
            maxSlippageBps: 300,
            minInitialGas: 0.002 ether,
            maxGasRefillAmount: 0.05 ether
        });
    }

    function _vaultData() internal view returns (bytes memory) {
        // v4-5: vaultData carries the market quote token (= the token's dividendToken); the vault
        // derives marketId = keccak256(chainId, quoteToken) and the pool key from it on-chain.
        return abi.encode(address(usdt), uint256(0.1 ether), uint256(0), uint256(0), type(uint256).max);
    }

    function _erc20VaultData() internal view returns (bytes memory) {
        return abi.encode(address(usdt), uint256(10 ether), uint256(0.01 ether), uint256(0.05 ether), type(uint256).max);
    }

    function test_newVault_onlyVaultPortal() public {
        vm.expectRevert();
        factory.newVault(makeAddr("tax"), address(0), makeAddr("creator"), _vaultData());
    }

    function test_newVault_deploysInitializedProxy() public {
        vm.prank(VAULT_PORTAL);
        address vaultAddr =
            factory.newVault(makeAddr("tax"), address(0), makeAddr("creator"), _vaultData());
        MyxVault v = MyxVault(payable(vaultAddr));
        assertEq(v.taxToken(), makeAddr("tax"));
        // v4-5: marketId is derived from the quote token (usdt) and chainid; poolId keys off the tax token.
        assertEq(v.marketQuoteToken(), address(usdt));
        assertEq(PoolId.unwrap(v.poolId()), PoolId.unwrap(MyxPoolId.derive(marketId, makeAddr("tax"))));
        assertEq(v.creator(), makeAddr("creator"));
        vm.expectRevert();
        v.initialize(
            MyxVault.InitParams({
                taxToken: address(1), creator: address(1), quoteToken: address(0),
                marketQuoteToken: address(usdt), poolManager: address(1), basePool: address(1),
                maxSlippageBps: 0, minProcessAmount: 0, gasThreshold: 0, gasRefillAmount: 0,
                maxProcessAmount: 0
            })
        );
    }

    event VaultCreated(
        address indexed vault, address indexed taxToken, address indexed creator, address marketQuoteToken
    );

    function test_newVault_emitsVaultCreated() public {
        address taxToken = makeAddr("tax");
        address creator = makeAddr("creator");
        vm.prank(VAULT_PORTAL);
        // v4-5: VaultCreated's last param is the market quote token from vaultData (= usdt).
        // vault/taxToken/creator are indexed; assert only the non-indexed marketQuoteToken data.
        vm.expectEmit(false, true, true, false);
        emit VaultCreated(address(0), taxToken, creator, address(usdt));
        address vaultAddr = factory.newVault(taxToken, address(0), creator, _vaultData());
        assertTrue(vaultAddr != address(0));
        assertEq(MyxVault(payable(vaultAddr)).taxToken(), taxToken);
        assertEq(MyxVault(payable(vaultAddr)).marketQuoteToken(), address(usdt));
    }

    function test_newVault_revertsOnZeroQuoteToken() public {
        // A launcher passing abi.encode(address(0)) as vaultData must be rejected by the vault's
        // initializer (ZeroMarketQuoteToken), bubbling up through the factory's BeaconProxy deploy.
        vm.prank(VAULT_PORTAL);
        vm.expectRevert(bytes(unicode"Zero market quote token / 市場報價幣為零地址"));
        factory.newVault(makeAddr("tax"), address(0), makeAddr("creator"), abi.encode(address(0), uint256(1), uint256(0), uint256(0), type(uint256).max));
    }

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

    function test_validateBeforeLaunch_acceptsBnbQuoteWithMagicDividend() public view {
        IVaultFactoryValidationV2.LaunchValidationDataV1 memory data;
        data.quoteToken = address(0);
        data.dividendToken = MAGIC_DIVIDEND_COMPUTED; // v6 requires the computed sentinel
        (bool ok,) = factory.onBeforeLaunch(abi.encode(data));
        assertTrue(ok);
    }

    function test_validateBeforeLaunch_rejectsNonMagicDividendToken() public view {
        // The guard that would have BLOCKED the mis-configured launch: any non-sentinel dividendToken
        // (e.g. WBNB) is rejected on-chain, so the dividend can never be wired to the wrong token.
        IVaultFactoryValidationV2.LaunchValidationDataV1 memory data;
        data.quoteToken = address(0);
        data.dividendToken = address(usdt); // not MAGIC
        (bool ok, string memory reason) = factory.onBeforeLaunch(abi.encode(data));
        assertFalse(ok);
        assertGt(bytes(reason).length, 0);
    }

    function test_validateBeforeLaunch_rejectsZeroDividendToken() public view {
        // Even address(0) (no dividend) is rejected — this factory only makes sense with myx-LP dividends.
        IVaultFactoryValidationV2.LaunchValidationDataV1 memory data;
        data.quoteToken = address(0); // data.dividendToken defaults to address(0)
        (bool ok,) = factory.onBeforeLaunch(abi.encode(data));
        assertFalse(ok);
    }

    function test_validateBeforeLaunch_rejectsNonZeroDividendBps() public view {
        // v6 requires Flap's native dividend dispatch OFF (dividendBps == 0); the vault feeds the LP itself.
        IVaultFactoryValidationV2.LaunchValidationDataV1 memory data;
        data.quoteToken = address(0);
        data.dividendToken = MAGIC_DIVIDEND_COMPUTED;
        data.dividendBps = 100; // non-zero
        (bool ok,) = factory.onBeforeLaunch(abi.encode(data));
        assertFalse(ok);
    }

    function test_tokenCreationPolicies_declaresConstraints() public view {
        FactoryPolicy[] memory policies = factory.tokenCreationPolicies();
        assertEq(policies.length, 2);
        assertEq(policies[0].target, "dividendToken");
        assertEq(abi.decode(policies[0].value, (address)), MAGIC_DIVIDEND_COMPUTED);
        assertEq(policies[1].target, "dividendBps");
        assertEq(abi.decode(policies[1].value, (uint256)), 0);
    }

    function test_vaultDataSchema_fiveFields() public view {
        VaultDataSchema memory s = factory.vaultDataSchema();
        assertEq(s.fields.length, 5);
        assertEq(s.fields[0].name, "marketQuoteToken");
        assertEq(s.fields[1].name, "minProcessAmount");
        assertEq(s.fields[2].name, "gasThreshold");
        assertEq(s.fields[3].name, "gasRefillAmount");
        assertEq(s.fields[4].name, "maxProcessAmount");
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
        factory.newVault(makeAddr("tax"), address(0), makeAddr("creator"), abi.encode(address(usdt), uint256(1), uint256(1), uint256(2), type(uint256).max));
    }

    receive() external payable {}

    function test_upgradeOnlyGuardian() public {
        address newImpl = address(new MyxVault());
        vm.expectRevert();
        factory.upgradeVaultImplementation(newImpl);
        vm.prank(GUARDIAN);
        factory.upgradeVaultImplementation(newImpl);
        assertEq(factory.beacon().implementation(), newImpl);
    }

    function test_factorySpecVersion_v23() public view {
        assertEq(factory.factorySpecVersion(), "v2.3");
    }

    // ── Flap Spec v2.3 resolveDividendToken callback ──────────────────────────

    /// @dev Build a minimal V6WithVault params struct for resolveDividendToken tests.
    ///      All fields not relevant to the factory's resolution logic are left zero/empty.
    function _v6Params(address marketQuote, string memory symbol, address dividendToken)
        internal
        pure
        returns (bytes memory)
    {
        IVaultPortalTypes.NewTokenV6WithVaultParamsU8 memory p;
        p.symbol = symbol;
        // Flap bonding quote is native BNB (address(0)); the myx MARKET quote token travels in
        // vaultData — the same source newVault decodes — so the predicted LP and the vault's pool
        // share the same myx market.
        p.quoteToken = address(0);
        p.vaultData = abi.encode(marketQuote, uint256(1), uint256(0), uint256(0), type(uint256).max);
        p.dividendToken = dividendToken;
        return abi.encode(p);
    }

    function test_resolveDividendToken_v6_returnsPredictedLp() public {
        address predictedToken = makeAddr("predictedTaxToken");
        address someLpAddr = makeAddr("mBaseLp");
        // marketId is keyed off the launch quoteToken (usdt) + chainid; LP predictor keyed off
        // (marketId, predictedToken, symbol).
        MarketId mid = MyxMarketId.derive(uint64(block.chainid), address(usdt));
        poolFactory.setPrediction(mid, predictedToken, "DEMO", someLpAddr);

        bytes memory launchParams = _v6Params(address(usdt), "DEMO", MAGIC_DIVIDEND_COMPUTED);
        address resolved = factory.resolveDividendToken(predictedToken, DIVIDEND_TOKEN_LAUNCH_VERSION_V6, launchParams);
        assertEq(resolved, someLpAddr);
        // Assert result matches direct poolFactory call — confirms the delegation is correct.
        assertEq(
            resolved,
            IMyxPoolFactory(address(poolFactory)).predictBasePoolToken(mid, predictedToken, "DEMO")
        );
    }

    function test_resolveDividendToken_v6_marketIdFromQuoteToken() public {
        address predictedToken = makeAddr("predictedTaxToken");
        address lpForUsdtMarket = makeAddr("lpUsdtMarket");
        address lpForUsdcMarket = makeAddr("lpUsdcMarket");

        MarketId usdtMarket = MyxMarketId.derive(uint64(block.chainid), address(usdt));
        MarketId usdcMarket = MyxMarketId.derive(uint64(block.chainid), address(usdc));
        // Same predictedToken + symbol, different quoteToken → distinct markets → distinct LPs.
        poolFactory.setPrediction(usdtMarket, predictedToken, "DEMO", lpForUsdtMarket);
        poolFactory.setPrediction(usdcMarket, predictedToken, "DEMO", lpForUsdcMarket);

        assertEq(
            factory.resolveDividendToken(predictedToken, DIVIDEND_TOKEN_LAUNCH_VERSION_V6,
                _v6Params(address(usdt), "DEMO", MAGIC_DIVIDEND_COMPUTED)),
            lpForUsdtMarket
        );
        assertEq(
            factory.resolveDividendToken(predictedToken, DIVIDEND_TOKEN_LAUNCH_VERSION_V6,
                _v6Params(address(usdc), "DEMO", MAGIC_DIVIDEND_COMPUTED)),
            lpForUsdcMarket
        );
    }

    function test_resolveDividendToken_v6_rejectsNonMagicDividendToken() public {
        // If V6 params carry a non-MAGIC dividendToken, factory must revert.
        address predictedToken = makeAddr("predictedTaxToken");
        bytes memory launchParams = _v6Params(address(usdt), "DEMO", address(usdt));
        vm.expectRevert(bytes(unicode"Expected V6 MAGIC dividend token / 預期 V6 MAGIC 分紅幣"));
        factory.resolveDividendToken(predictedToken, DIVIDEND_TOKEN_LAUNCH_VERSION_V6, launchParams);
    }

    /// @dev Build a minimal V7WithVault params struct for resolveDividendToken tests.
    ///      ONE feeConfig entry has feeType=DIVIDEND(2) with the given dividendInFee;
    ///      the other three entries have feeType=NONE(0).
    function _v7Params(address marketQuote, string memory symbol, address dividendInFee)
        internal
        pure
        returns (bytes memory)
    {
        IVaultPortalTypes.NewTokenV7WithVaultParamsU8 memory p;
        p.symbol = symbol;
        p.quoteToken = address(0); // Flap bonding quote is native BNB
        p.vaultData = abi.encode(marketQuote, uint256(1), uint256(0), uint256(0), type(uint256).max);
        // feeConfigs[0] carries the DIVIDEND slot
        p.feeConfigs[0].feeType = 2; // DIVIDEND
        p.feeConfigs[0].dividendToken = dividendInFee;
        // feeConfigs[1..3] default to feeType=0 (NONE)
        return abi.encode(p);
    }

    function test_resolveDividendToken_v7_returnsPredictedLp() public {
        address predictedToken = makeAddr("predictedTaxTokenV7");
        address someLpAddr = makeAddr("mBaseLpV7");
        MarketId mid = MyxMarketId.derive(uint64(block.chainid), address(usdt));
        poolFactory.setPrediction(mid, predictedToken, "DEMO", someLpAddr);

        bytes memory launchParams = _v7Params(address(usdt), "DEMO", MAGIC_DIVIDEND_COMPUTED);
        address resolved = factory.resolveDividendToken(predictedToken, DIVIDEND_TOKEN_LAUNCH_VERSION_V7, launchParams);
        assertEq(resolved, someLpAddr);
        assertEq(
            resolved,
            IMyxPoolFactory(address(poolFactory)).predictBasePoolToken(mid, predictedToken, "DEMO")
        );
    }

    function test_resolveDividendToken_v7_rejectsNonMagicDividendToken() public {
        address predictedToken = makeAddr("predictedTaxTokenV7");
        // DIVIDEND feeConfig with wrong dividendToken (not the magic sentinel)
        bytes memory launchParams = _v7Params(address(usdt), "DEMO", address(usdt));
        vm.expectRevert(bytes(unicode"Expected V7 MAGIC dividend token / 預期 V7 MAGIC 分紅幣"));
        factory.resolveDividendToken(predictedToken, DIVIDEND_TOKEN_LAUNCH_VERSION_V7, launchParams);
    }

    function test_resolveDividendToken_v7_rejectsNoDividendFeeConfig() public {
        // All feeConfigs have feeType=NONE (0) — no DIVIDEND entry present
        address predictedToken = makeAddr("predictedTaxTokenV7");
        IVaultPortalTypes.NewTokenV7WithVaultParamsU8 memory p;
        p.symbol = "DEMO";
        p.quoteToken = address(0);
        p.vaultData = abi.encode(address(usdt), uint256(1), uint256(0), uint256(0), type(uint256).max);
        // All feeConfigs stay feeType=0 (NONE) — no DIVIDEND entry
        bytes memory launchParams = abi.encode(p);
        vm.expectRevert(bytes(unicode"No V7 dividend feeConfig / 無 V7 分紅費用配置"));
        factory.resolveDividendToken(predictedToken, DIVIDEND_TOKEN_LAUNCH_VERSION_V7, launchParams);
    }

    function test_resolveDividendToken_unknownVersion_reverts() public {
        // Any version other than 6 or 7 must revert.
        address predictedToken = makeAddr("predictedTaxToken");
        vm.expectRevert(bytes(unicode"Unsupported launch version / 不支援的發行版本"));
        factory.resolveDividendToken(predictedToken, 99, "");
    }

    function test_resolveDividendToken_isStaticallySafe() public {
        // Verify the function can be called via staticcall (i.e. it is `view`).
        // We use a low-level staticcall from this test contract to confirm no state mutation.
        address predictedToken = makeAddr("predictedTaxToken");
        address someLp = makeAddr("lp");
        MarketId mid = MyxMarketId.derive(uint64(block.chainid), address(usdt));
        poolFactory.setPrediction(mid, predictedToken, "DEMO", someLp);

        bytes memory callData = abi.encodeWithSignature(
            "resolveDividendToken(address,uint8,bytes)",
            predictedToken,
            DIVIDEND_TOKEN_LAUNCH_VERSION_V6,
            _v6Params(address(usdt), "DEMO", MAGIC_DIVIDEND_COMPUTED)
        );
        (bool ok, bytes memory ret) = address(factory).staticcall(callData);
        assertTrue(ok, "staticcall failed");
        address result = abi.decode(ret, (address));
        assertEq(result, someLp);
    }

    function test_validateBeforeLaunch_permitsMagicDividendToken() public view {
        // v2.3: dividendToken = MAGIC_DIVIDEND_COMPUTED must be permitted by _validateBeforeLaunch.
        IVaultFactoryValidationV2.LaunchValidationDataV1 memory data;
        data.quoteToken = address(0); // BNB
        data.dividendToken = MAGIC_DIVIDEND_COMPUTED;
        (bool ok,) = factory.onBeforeLaunch(abi.encode(data));
        assertTrue(ok);
    }

    function test_lockVaultUpgrades_blocksFurtherUpgrades() public {
        address newImpl = address(new MyxVault());
        vm.prank(GUARDIAN);
        factory.lockVaultUpgrades();
        vm.prank(GUARDIAN);
        vm.expectRevert(bytes(unicode"Upgrades are locked / 升級已鎖定"));
        factory.upgradeVaultImplementation(newImpl);
    }

    // ── Bounds on creator-supplied vault parameters ───────────────────────────
    // minProcessAmount, gasThreshold and gasRefillAmount are creator-supplied at launch and
    // immutable afterwards, so the factory is the only place that can bound them.

    function test_newVault_zeroMinProcessAmount_reverts_native() public {
        vm.prank(VAULT_PORTAL);
        vm.expectRevert(bytes(unicode"Min process amount must be non-zero / 最低處理金額不可為零"));
        factory.newVault(
            makeAddr("tax"), address(0), makeAddr("creator"),
            abi.encode(address(usdt), uint256(0), uint256(0), uint256(0), type(uint256).max)
        );
    }

    function test_newVault_zeroMinProcessAmount_reverts_erc20() public {
        vm.deal(address(this), 1 ether);
        factory.prepayGas{value: 0.002 ether}();
        vm.prank(VAULT_PORTAL);
        vm.expectRevert(bytes(unicode"Min process amount must be non-zero / 最低處理金額不可為零"));
        factory.newVault(
            makeAddr("tax"), address(rwa), address(this),
            abi.encode(address(usdt), uint256(0), uint256(0.01 ether), uint256(0.05 ether), type(uint256).max)
        );
    }

    function test_newVault_erc20_gasRefillAboveCap_reverts() public {
        vm.deal(address(this), 1 ether);
        factory.prepayGas{value: 0.002 ether}();
        vm.prank(VAULT_PORTAL);
        vm.expectRevert(bytes(unicode"Gas refill above factory cap / Gas 補充值超過工廠上限"));
        factory.newVault(
            makeAddr("tax"), address(rwa), address(this),
            abi.encode(address(usdt), uint256(10 ether), uint256(0.01 ether), uint256(0.05 ether + 1), type(uint256).max)
        );
    }

    function test_newVault_erc20_gasRefillAtCap_passes() public {
        vm.deal(address(this), 1 ether);
        factory.prepayGas{value: 0.002 ether}();
        vm.prank(VAULT_PORTAL);
        address vaultAddr = factory.newVault(
            makeAddr("tax"), address(rwa), address(this),
            abi.encode(address(usdt), uint256(10 ether), uint256(0.01 ether), uint256(0.05 ether), type(uint256).max)
        );
        assertEq(MyxVault(payable(vaultAddr)).gasRefillAmount(), 0.05 ether, "equal to the cap is allowed");
    }

    /// @dev The cap is ERC20-quote only: a native-quote vault never refills (its gas params must be
    ///      zero), so a factory configured with maxGasRefillAmount = 0 still launches native vaults.
    function test_newVault_nativeQuote_ignoresGasRefillCap() public {
        MyxVaultFactory strict = new MyxVaultFactory(
            MyxVaultFactory.GlobalConfig({
                poolManager: address(poolManager),
                basePool: address(basePool),
                poolFactory: address(poolFactory),
                maxSlippageBps: 300,
                minInitialGas: 0.002 ether,
                maxGasRefillAmount: 0
            })
        );
        vm.prank(VAULT_PORTAL);
        address vaultAddr = strict.newVault(makeAddr("tax"), address(0), makeAddr("creator"), _vaultData());
        assertEq(MyxVault(payable(vaultAddr)).vaultQuoteToken(), address(0));
        // Same factory: an ERC20 launch with any non-zero refill is rejected by the same cap.
        vm.deal(address(this), 1 ether);
        strict.prepayGas{value: 0.002 ether}();
        vm.prank(VAULT_PORTAL);
        vm.expectRevert(bytes(unicode"Gas refill above factory cap / Gas 補充值超過工廠上限"));
        strict.newVault(makeAddr("tax2"), address(rwa), address(this), _erc20VaultData());
    }

    function test_constructor_rejectsSlippageAbove100Percent() public {
        MyxVaultFactory.GlobalConfig memory c = _baseConfig();
        c.maxSlippageBps = 10_001;
        vm.expectRevert(bytes(unicode"Slippage above 100% / 滑點超過 100%"));
        new MyxVaultFactory(c);
    }

    function test_constructor_acceptsSlippageAt100Percent() public {
        MyxVaultFactory.GlobalConfig memory c = _baseConfig();
        c.maxSlippageBps = 10_000;
        MyxVaultFactory f = new MyxVaultFactory(c);
        (,,, uint16 bps,,) = f.config();
        assertEq(bps, 10_000);
    }
}

contract MyxVaultFactoryMaxProcessTest is MyxVaultFactoryTest {
    function test_newVault_maxProcessBelowMin_reverts() public {
        vm.prank(VAULT_PORTAL);
        vm.expectRevert(bytes(unicode"Max process amount below minimum / 單批處理上限低於最低處理金額"));
        factory.newVault(
            makeAddr("tax"), address(0), makeAddr("creator"),
            abi.encode(address(usdt), uint256(10 ether), uint256(0), uint256(0), uint256(10 ether - 1))
        );
    }

    function test_newVault_wiresMaxProcessAmount() public {
        vm.prank(VAULT_PORTAL);
        address v = factory.newVault(
            makeAddr("tax"), address(0), makeAddr("creator"),
            abi.encode(address(usdt), uint256(10 ether), uint256(0), uint256(0), uint256(25 ether))
        );
        assertEq(MyxVault(payable(v)).maxProcessAmount(), 25 ether);
    }
}
