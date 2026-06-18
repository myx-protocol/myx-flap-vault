// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.26;

import {Test} from "forge-std/Test.sol";
import {MyxVaultFactory} from "../src/MyxVaultFactory.sol";
import {MyxVault} from "../src/MyxVault.sol";
import {MarketId, PoolId, MyxPoolId, MyxMarketId, IMyxPoolFactory} from "../src/myx/IMyxPool.sol";
import {IVaultFactoryValidationV2, DIVIDEND_TOKEN_LAUNCH_VERSION_V6, DIVIDEND_TOKEN_LAUNCH_VERSION_V7} from "../src/flap/IVaultFactory.sol";
import {IVaultPortalTypes} from "../src/flap/IVaultPortal.sol";
import {MAGIC_DIVIDEND_COMPUTED} from "../src/flap/IPortal.sol";
import {FactoryPolicy} from "../src/flap/IVaultSchemasV1.sol";
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

        factory = new MyxVaultFactory(_baseConfig());
    }

    function _baseConfig() internal view returns (MyxVaultFactory.GlobalConfig memory) {
        return MyxVaultFactory.GlobalConfig({
            poolManager: address(poolManager),
            basePool: address(basePool),
            poolFactory: address(poolFactory),
            maxSlippageBps: 300,
            minProcessAmount: 0.1 ether
        });
    }

    function _vaultData() internal view returns (bytes memory) {
        // v4-5: vaultData carries the market quote token (= the token's dividendToken); the vault
        // derives marketId = keccak256(chainId, quoteToken) and the pool key from it on-chain.
        return abi.encode(address(usdt));
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
                taxToken: address(1), creator: address(1),
                marketQuoteToken: address(usdt), poolManager: address(1), basePool: address(1),
                maxSlippageBps: 0, minProcessAmount: 0
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
        factory.newVault(makeAddr("tax"), address(0), makeAddr("creator"), abi.encode(address(0)));
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
        assertEq(policies.length, 3);
        assertEq(policies[0].target, "dividendToken");
        assertEq(policies[0].operator, "eq");
        assertEq(abi.decode(policies[0].value, (address)), MAGIC_DIVIDEND_COMPUTED);
        assertEq(policies[1].target, "quoteToken");
        assertEq(abi.decode(policies[1].value, (address)), address(0));
        assertEq(policies[2].target, "dividendBps");
        assertEq(abi.decode(policies[2].value, (uint256)), 0);
    }

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
        p.vaultData = abi.encode(marketQuote);
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
        p.vaultData = abi.encode(marketQuote);
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
        p.vaultData = abi.encode(address(usdt));
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

}
