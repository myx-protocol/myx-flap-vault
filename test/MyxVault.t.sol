// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.26;

import {Test} from "forge-std/Test.sol";
import {MyxVault} from "../src/MyxVault.sol";
import {VaultMethodSchema} from "../src/flap/IVaultSchemasV1.sol";
import {MarketId, PoolId, MyxPoolId, MyxMarketId, IMyxBasePool, PoolMetadata} from "../src/myx/IMyxPool.sol";
import {IPortalTradeV2} from "../src/flap/IPortal.sol";
import {ERC1967Proxy} from "@openzeppelin/proxy/ERC1967/ERC1967Proxy.sol";
import "./mocks/Mocks.sol";

contract MyxVaultTestBase is Test {
    MyxVault vault;
    MockWBNB wbnb;
    MockERC20 usdt;
    MockERC20 lpToken;
    MockBasePool basePool;
    MockPoolManager poolManager;
    MockPancakeRouter router;
    MockPortal portal;
    MockAggregatorV3 bnbUsdFeed;
    MockAggregatorV3 usdtUsdFeed;
    MockDividendDistributor dividend;
    MockTaxToken taxToken;
    MockTriggerService triggerService;

    address creator = makeAddr("creator");
    // Guardian address hardcoded in VaultBase for chainId 56; tests etch chainid 56 via vm.chainId.
    address constant GUARDIAN = 0x9e27098dcD8844bcc6287a557E0b4D09C86B8a4b;
    // Portal address hardcoded in VaultBase for chainId 56; MockPortal code is etched there.
    address constant PORTAL = 0xe2cE6ab80874Fa9Fa2aAE65D277Dd6B8e65C9De0;
    // v4-5: the vault derives marketId on-chain from (block.chainid, marketQuoteToken). Tests run on
    // chainId 56 with usdt as the launch quote token, so the expected marketId mirrors that derivation.
    // Assigned in setUp() after usdt is constructed.
    MarketId marketId;

    function setUp() public virtual {
        vm.chainId(56);
        wbnb = new MockWBNB();
        usdt = new MockERC20("Tether", "USDT");
        marketId = MyxMarketId.derive(uint64(56), address(usdt));
        lpToken = new MockERC20("MYX LP", "MLP");
        basePool = new MockBasePool(lpToken, usdt);
        poolManager = new MockPoolManager();
        router = new MockPancakeRouter();
        bnbUsdFeed = new MockAggregatorV3(600e8, 8);  // BNB = $600
        usdtUsdFeed = new MockAggregatorV3(1e8, 8);   // USDT = $1
        // v6: the DIVIDEND ASSET is the myx base-pool LP (mBase), set at launch via
        // computeDividendToken. Construct the dividend with dividendToken() == the LP token so the
        // vault's _feedDividend pulls exactly the LP the mock pool mints (dividendToken == LP invariant).
        dividend = new MockDividendDistributor(address(lpToken));
        taxToken = new MockTaxToken(address(dividend));
        triggerService = new MockTriggerService();

        // The vault resolves the Portal via VaultBase._getPortal() (hardcoded per chainid),
        // so the mock must live at the BSC mainnet Portal address. vm.etch copies CODE but
        // not STORAGE: rateNum/rateDen are zero after etch and MUST be re-initialized.
        MockPortal portalImpl = new MockPortal();
        vm.etch(PORTAL, address(portalImpl).code);
        portal = MockPortal(PORTAL);
        portal.setRate(1, 1);

        vault = _deployVault(_initParams());
    }

    function _deployVault(MyxVault.InitParams memory p) internal returns (MyxVault) {
        MyxVault impl = new MyxVault();
        bytes memory initData = abi.encodeCall(MyxVault.initialize, (p));
        ERC1967Proxy proxy = new ERC1967Proxy(address(impl), initData);
        return MyxVault(payable(address(proxy)));
    }

    function _initParams() internal view returns (MyxVault.InitParams memory p) {
        p.taxToken = address(taxToken);
        p.creator = creator;
        p.marketQuoteToken = address(usdt);
        p.poolManager = address(poolManager);
        p.basePool = address(basePool);
        p.maxSlippageBps = 300;          // 3%
        p.minProcessAmount = 0.1 ether;  // BNB
        p.triggerService = address(triggerService);
        p.triggerInterval = 1 hours;
    }
}

contract MyxVaultInitTest is MyxVaultTestBase {
    function test_initialize_storesConfig() public view {
        assertEq(vault.taxToken(), address(taxToken));
        // v4-5: the launch param is the market quote token; the vault derives marketId on-chain
        // from (block.chainid, quoteToken), then poolId from (marketId, taxToken).
        assertEq(vault.marketQuoteToken(), address(usdt));
        MarketId expectedMarketId = MyxMarketId.derive(uint64(56), address(usdt));
        assertEq(MarketId.unwrap(vault.marketId()), MarketId.unwrap(expectedMarketId));
        assertEq(
            PoolId.unwrap(vault.poolId()),
            PoolId.unwrap(MyxPoolId.derive(expectedMarketId, address(taxToken)))
        );
    }

    function test_initialize_revertsOnZeroQuoteToken() public {
        MyxVault.InitParams memory p = _initParams();
        p.marketQuoteToken = address(0);
        MyxVault impl = new MyxVault();
        bytes memory initData = abi.encodeCall(MyxVault.initialize, (p));
        vm.expectRevert(MyxVault.ZeroMarketQuoteToken.selector);
        new ERC1967Proxy(address(impl), initData);
    }

    /// @dev Locks the on-chain derivation: marketId = keccak256(chainId, quoteToken) and the pool
    ///      key derives from it. Guards against any drift from the myx MarketKey/PoolKey hashing.
    function test_derivedMarketId_matchesPoolKey() public view {
        MarketId expectedMarketId = MyxMarketId.derive(uint64(56), address(usdt));
        assertEq(MarketId.unwrap(vault.marketId()), MarketId.unwrap(expectedMarketId));
        assertEq(
            PoolId.unwrap(vault.poolId()),
            PoolId.unwrap(MyxPoolId.derive(expectedMarketId, address(taxToken)))
        );
    }

    function test_initialize_revertsOnSecondCall() public {
        vm.expectRevert();
        vault.initialize(_initParams());
    }

    function test_initialize_storesTrimmedConfig() public view {
        // v4: feed/router/wbnb/quoteToken removed from InitParams; the surviving config persists.
        assertEq(address(vault.poolManager()), address(poolManager));
        assertEq(address(vault.basePool()), address(basePool));
        assertEq(vault.maxSlippageBps(), 300);
        assertEq(vault.minProcessAmount(), 0.1 ether);
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
        assertLt(used, 100_000); // gross call cost incl. CALL overhead — far below the 1M Rule-005 budget
    }
}

contract MyxVaultGuardianTest is MyxVaultTestBase {
    function test_guardianHasEmergencyAndAdminRole() public view {
        assertTrue(vault.hasRole(vault.EMERGENCY_ROLE(), GUARDIAN));
        assertTrue(vault.hasRole(vault.DEFAULT_ADMIN_ROLE(), GUARDIAN));
    }

    function test_creatorHasEmergencyRole() public view {
        assertTrue(vault.hasRole(vault.EMERGENCY_ROLE(), creator));
    }

    function test_operatorRoleGrantedToCreatorAndGuardian() public view {
        assertTrue(vault.hasRole(vault.OPERATOR_ROLE(), creator));
        assertTrue(vault.hasRole(vault.OPERATOR_ROLE(), GUARDIAN));
    }

    function test_revokeGuardianRole_reverts() public {
        bytes32 role = vault.EMERGENCY_ROLE();
        vm.prank(GUARDIAN); // even the admin itself cannot revoke the guardian
        vm.expectRevert(MyxVault.CannotRevokeGuardianRole.selector);
        vault.revokeRole(role, GUARDIAN);
    }

    function test_revokeGuardianOperatorRole_reverts() public {
        // v3: processRevenue is OPERATOR_ROLE-gated — the guardian's operator access
        // must be irrevocable just like its other roles (Flap mandate).
        bytes32 role = vault.OPERATOR_ROLE();
        vm.prank(GUARDIAN);
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

contract MyxVaultProcessTest is MyxVaultTestBase {
    function setUp() public override {
        super.setUp();
        // register the tax-token pool as already existing
        PoolMetadata memory meta;
        meta.marketId = marketId;
        meta.poolId = MyxPoolId.derive(marketId, address(taxToken));
        meta.baseToken = address(taxToken);
        meta.basePoolToken = address(lpToken);
        poolManager.setPool(meta.poolId, meta);
        // 1 BNB buys 1000 tax tokens on the mock Portal
        portal.setRate(1000, 1);
    }

    function _fund(uint256 amount) internal {
        vm.deal(address(this), amount);
        (bool ok,) = address(vault).call{value: amount}("");
        assertTrue(ok);
    }

    function test_processRevenue_buysAndDeposits() public {
        _fund(1 ether);
        vm.prank(creator);
        vault.processRevenue();
        assertEq(vault.pendingBnb(), 0);
        assertEq(basePool.depositCallCount(), 1);
        assertEq(basePool.lastDepositAmount(), 1000 ether);
        assertEq(basePool.lastDepositRecipient(), address(vault)); // LP minted to the vault first
        assertEq(vault.totalLpMinted(), 1000 ether);
        // v6: the minted LP is then fed into the dividend, so the vault retains none.
        assertEq(lpToken.balanceOf(address(vault)), 0, "LP fed to the dividend");
        assertEq(dividend.totalDeposited(), 1000 ether);
    }

    function test_defaultMode_isTriggered() public view {
        assertTrue(vault.mode() == MyxVault.Mode.TRIGGERED);
    }

    function test_auto_anyoneCanProcess() public {
        // AUTO mode: processRevenue is permissionless (default is now TRIGGERED).
        vm.prank(GUARDIAN);
        vault.setMode(MyxVault.Mode.AUTO);
        _fund(1 ether);
        vm.prank(makeAddr("stranger"));
        vault.processRevenue();
        assertEq(basePool.depositCallCount(), 1);
    }

    function test_manual_strangerReverts() public {
        address stranger = makeAddr("stranger");
        vm.prank(GUARDIAN);
        vault.setMode(MyxVault.Mode.MANUAL);
        _fund(1 ether);
        vm.prank(stranger);
        vm.expectRevert(MyxVault.NotAuthorized.selector);
        vault.processRevenue();
        assertEq(vault.pendingBnb(), 1 ether); // untouched
    }

    function test_manual_operatorAllowed() public {
        // creator holds OPERATOR_ROLE, so it can process even in MANUAL mode
        vm.prank(GUARDIAN);
        vault.setMode(MyxVault.Mode.MANUAL);
        _fund(1 ether);
        vm.prank(creator);
        vault.processRevenue();
        assertEq(basePool.depositCallCount(), 1);
    }

    function test_processRevenue_guardianAllowed() public {
        _fund(1 ether);
        vm.prank(GUARDIAN);
        vault.processRevenue();
        assertEq(basePool.depositCallCount(), 1);
    }

    function test_processRevenue_belowMinimum_reverts() public {
        _fund(0.05 ether); // below 0.1 ether minProcessAmount
        vm.prank(creator);
        vm.expectRevert(
            abi.encodeWithSelector(MyxVault.BelowMinimumProcessAmount.selector, 0.05 ether, 0.1 ether)
        );
        vault.processRevenue();
    }

    function test_processRevenue_dexPhaseTax_accountsBalanceDelta() public {
        portal.setTaxBps(400); // 4% DEX-phase transfer tax: gross 1000, net 960
        _fund(1 ether);
        vm.prank(creator);
        vault.processRevenue();
        // deposit must use the balance delta (net), never the Portal's gross output
        assertEq(basePool.lastDepositAmount(), 960 ether);
        // v6: the 960 LP minted is fed into the dividend
        assertEq(dividend.totalDeposited(), 960 ether);
        assertEq(lpToken.balanceOf(address(vault)), 0);
    }

    function test_processRevenue_zeroQuote_reverts() public {
        portal.setRate(0, 1); // Portal quotes zero output
        _fund(1 ether);
        vm.prank(creator);
        vm.expectRevert(MyxVault.ZeroQuote.selector);
        vault.processRevenue();
        assertEq(vault.pendingBnb(), 1 ether); // retained for retry
    }

    function test_processRevenue_swapReverts_retainsBnb() public {
        _fund(1 ether);
        vm.mockCallRevert(
            PORTAL,
            abi.encodeWithSelector(IPortalTradeV2.swapExactInput.selector),
            "PORTAL_FAIL"
        );
        vm.prank(creator);
        vm.expectRevert("PORTAL_FAIL");
        vault.processRevenue();
        // state rolled back: BNB safely retained for retry
        assertEq(vault.pendingBnb(), 1 ether);
        assertEq(address(vault).balance, 1 ether);
    }

    function test_processRevenue_failedDepositLeavesBnbPending() public {
        _fund(1 ether);
        vm.mockCallRevert(
            address(basePool),
            abi.encodeWithSelector(IMyxBasePool.deposit.selector),
            "POOL_PAUSED"
        );
        vm.prank(creator);
        vm.expectRevert();
        vault.processRevenue();
        // state rolled back: BNB safely retained for retry
        assertEq(vault.pendingBnb(), 1 ether);
        assertEq(address(vault).balance, 1 ether);
    }

    function test_setMode_roundTrip_autoRestoresPermissionless() public {
        _fund(2 ether);

        vm.prank(GUARDIAN);
        vault.setMode(MyxVault.Mode.MANUAL);
        address stranger = makeAddr("stranger");
        vm.prank(stranger);
        vm.expectRevert(MyxVault.NotAuthorized.selector);
        vault.processRevenue();

        vm.prank(GUARDIAN);
        vault.setMode(MyxVault.Mode.AUTO);

        vm.prank(stranger);
        vault.processRevenue();
        assertEq(basePool.depositCallCount(), 1);
    }

    function test_manual_newlyGrantedOperatorAllowed() public {
        address newKeeper = makeAddr("newKeeper");
        bytes32 opRole = vault.OPERATOR_ROLE();
        vm.prank(GUARDIAN);
        vault.grantRole(opRole, newKeeper);

        vm.prank(GUARDIAN);
        vault.setMode(MyxVault.Mode.MANUAL);

        _fund(1 ether);

        vm.prank(newKeeper);
        vault.processRevenue();
        assertEq(basePool.depositCallCount(), 1);
    }

    function test_processRevenue_belowMinimumAfterSuccess_reverts() public {
        _fund(1 ether);
        vm.prank(creator); // default mode is TRIGGERED: operator-only
        vault.processRevenue(); // succeeds, pendingBnb -> 0

        // second call with pendingBnb == 0 must revert below-minimum
        uint256 minAmt = vault.minProcessAmount();
        vm.prank(creator);
        vm.expectRevert(abi.encodeWithSelector(MyxVault.BelowMinimumProcessAmount.selector, 0, minAmt));
        vault.processRevenue();
    }
}

contract MyxVaultModeTest is MyxVaultTestBase {
    event ModeChanged(MyxVault.Mode newMode);

    function setUp() public override {
        super.setUp();
        // register the tax-token pool as already existing so processRevenue can deposit
        PoolMetadata memory meta;
        meta.marketId = marketId;
        meta.poolId = MyxPoolId.derive(marketId, address(taxToken));
        meta.baseToken = address(taxToken);
        meta.basePoolToken = address(lpToken);
        poolManager.setPool(meta.poolId, meta);
        portal.setRate(1000, 1);
    }

    function _fund(uint256 amount) internal {
        vm.deal(address(this), amount);
        (bool ok,) = address(vault).call{value: amount}("");
        assertTrue(ok);
    }

    function test_defaultMode_isTriggered() public view {
        // enum order is { TRIGGERED, AUTO, MANUAL } => TRIGGERED == 0
        assertEq(uint8(vault.mode()), 0);
    }

    function test_processRevenue_triggeredMode_operatorOnly() public {
        // default mode is TRIGGERED: only OPERATOR_ROLE may call processRevenue
        _fund(1 ether);
        vm.prank(makeAddr("stranger"));
        vm.expectRevert(MyxVault.NotAuthorized.selector);
        vault.processRevenue();

        vm.prank(creator); // creator holds OPERATOR_ROLE
        vault.processRevenue();
        assertEq(basePool.depositCallCount(), 1);
    }

    function test_processRevenue_autoMode_permissionless() public {
        vm.prank(creator);
        vault.setMode(MyxVault.Mode.AUTO);
        _fund(1 ether);
        vm.prank(makeAddr("stranger"));
        vault.processRevenue();
        assertEq(basePool.depositCallCount(), 1);
    }

    function test_processRevenue_manualMode_operatorOnly() public {
        vm.prank(creator);
        vault.setMode(MyxVault.Mode.MANUAL);
        _fund(1 ether);
        vm.prank(makeAddr("stranger"));
        vm.expectRevert(MyxVault.NotAuthorized.selector);
        vault.processRevenue();

        vm.prank(creator);
        vault.processRevenue();
        assertEq(basePool.depositCallCount(), 1);
    }

    function test_setMode_onlyCreatorOrGuardian() public {
        vm.prank(makeAddr("stranger"));
        vm.expectRevert(MyxVault.NotModeAdmin.selector);
        vault.setMode(MyxVault.Mode.AUTO);
    }

    function test_setMode_creatorAllowed() public {
        vm.prank(creator);
        vault.setMode(MyxVault.Mode.MANUAL);
        assertTrue(vault.mode() == MyxVault.Mode.MANUAL);
    }

    function test_setMode_guardianAllowed() public {
        vm.prank(GUARDIAN);
        vault.setMode(MyxVault.Mode.MANUAL);
        assertTrue(vault.mode() == MyxVault.Mode.MANUAL);
    }

    function test_setMode_strangerReverts() public {
        vm.prank(makeAddr("stranger"));
        vm.expectRevert(MyxVault.NotModeAdmin.selector);
        vault.setMode(MyxVault.Mode.MANUAL);
    }

    function test_setMode_emitsModeChanged() public {
        vm.expectEmit(false, false, false, true, address(vault));
        emit ModeChanged(MyxVault.Mode.MANUAL);
        vm.prank(creator);
        vault.setMode(MyxVault.Mode.MANUAL);
    }
}

contract MyxVaultTriggerTest is MyxVaultTestBase {
    event LoopStalled(uint256 pendingBnb);

    function setUp() public override {
        super.setUp();
        // v6: register the pool with basePoolToken == the LP, and set the dividend asset to that
        // SAME LP, so the in-cycle buyback mints LP and _feedDividend feeds it to the dividend.
        PoolMetadata memory meta;
        meta.marketId = marketId;
        meta.poolId = MyxPoolId.derive(marketId, address(taxToken));
        meta.baseToken = address(taxToken);
        meta.quoteToken = address(usdt);
        meta.basePoolToken = address(lpToken);
        poolManager.setPool(meta.poolId, meta);
        dividend.setDividendToken(address(lpToken)); // v6: dividend asset IS the LP
        portal.setRate(1000, 1); // 1 BNB -> 1000 tax tokens
    }

    function _fund(uint256 amount) internal {
        vm.deal(address(this), amount);
        (bool ok,) = address(vault).call{value: amount}("");
        assertTrue(ok);
    }

    function test_scheduleTrigger_bootstraps() public {
        _fund(1 ether);
        uint256 fee = triggerService.getFee();
        vault.scheduleTrigger();
        assertEq(vault.pendingTriggerId(), 1);
        assertEq(vault.pendingBnb(), 1 ether - fee);
    }

    function test_scheduleTrigger_revertsIfAlreadyScheduled() public {
        _fund(1 ether);
        vault.scheduleTrigger();
        vm.expectRevert(MyxVault.TriggerAlreadyScheduled.selector);
        vault.scheduleTrigger();
    }

    function test_scheduleTrigger_revertsIfInsufficientBnb() public {
        // pendingBnb (0) <= fee
        vm.expectRevert(
            abi.encodeWithSelector(
                MyxVault.BelowMinimumProcessAmount.selector, 0, triggerService.getFee()
            )
        );
        vault.scheduleTrigger();
    }

    function test_scheduleTrigger_revertsIfNotTriggeredMode() public {
        vm.prank(creator);
        vault.setMode(MyxVault.Mode.AUTO);
        _fund(1 ether);
        vm.expectRevert(MyxVault.NotAuthorized.selector);
        vault.scheduleTrigger();
    }

    function test_trigger_onlyTriggerService() public {
        _fund(1 ether);
        vault.scheduleTrigger();
        vm.prank(makeAddr("stranger"));
        vm.expectRevert(MyxVault.OnlyTriggerService.selector);
        vault.trigger(1);
    }

    function test_trigger_unknownRequestId_reverts() public {
        _fund(1 ether);
        vault.scheduleTrigger(); // id 1
        vm.expectRevert(abi.encodeWithSelector(MyxVault.UnknownTrigger.selector, uint256(999)));
        triggerService.fire(address(vault), 999);
    }

    function test_trigger_runsCycleAndReschedules() public {
        uint256 fee = triggerService.getFee();
        _fund(1 ether); // well above minProcessAmount + fee
        vault.scheduleTrigger(); // id 1, reserves one fee
        assertEq(vault.pendingTriggerId(), 1);
        uint256 bnbForBuyback = vault.pendingBnb() - fee; // remainder after the in-cycle reschedule fee

        triggerService.fire(address(vault), 1);

        // v6: the in-cycle buyback minted LP and the cycle fed the WHOLE LP into the dividend.
        uint256 expectedLp = bnbForBuyback * 1000; // mock Portal rate 1000, LP minted 1:1
        assertEq(basePool.depositCallCount(), 1);
        assertEq(vault.totalLpMinted(), expectedLp);
        assertEq(dividend.totalDeposited(), expectedLp, "cycle must feed the minted LP to the dividend");
        assertEq(lpToken.balanceOf(address(vault)), 0, "LP flushed to the dividend");
        // next cycle rescheduled (id 2), and pendingBnb consumed by the buyback
        assertEq(vault.pendingTriggerId(), 2);
        assertEq(vault.pendingBnb(), 0);

        // replay protection: firing id 1 again must revert (it has been consumed)
        vm.expectRevert(abi.encodeWithSelector(MyxVault.UnknownTrigger.selector, uint256(1)));
        triggerService.fire(address(vault), 1);
    }

    function test_trigger_feedBackstopFlushesDeferredEvenBelowBuybackThreshold() public {
        // v6: the cycle's feed backstop flushes any deferred LP first, even when the remaining
        // pendingBnb is below the buyback threshold. Arrange deferred LP via a failed feed, then
        // fire a cycle whose remainder is too small to buy back: the deferred LP must still flush.
        uint256 fee = triggerService.getFee();

        // Stage deferred LP: fund + processRevenue with deposit failing -> 1000 LP retained.
        // (This staging step itself runs one buyback to mint the LP, so depositCallCount becomes 1.)
        _fund(1 ether);
        dividend.setDepositSucceeds(false);
        vm.prank(creator);
        vault.processRevenue();
        assertEq(lpToken.balanceOf(address(vault)), 1000 ether, "LP deferred");
        assertEq(dividend.totalDeposited(), 0);
        uint256 depositsAfterStaging = basePool.depositCallCount(); // 1 from the staging buyback

        // Now shares exist: fund just enough that, after the reschedule fee, the remainder is below
        // minProcessAmount so the buyback is skipped — proving the feed runs independently.
        dividend.setDepositSucceeds(true);
        uint256 funded = fee + 0.05 ether; // 0.05 < minProcessAmount (0.1)
        _fund(funded);
        vault.scheduleTrigger(); // id 1, deducts one fee -> pendingBnb = 0.05 ether
        assertEq(vault.pendingBnb(), 0.05 ether);

        triggerService.fire(address(vault), 1);

        // feed backstop flushed the deferred LP
        assertEq(dividend.totalDeposited(), 1000 ether, "deferred LP flushed by the cycle feed");
        assertEq(lpToken.balanceOf(address(vault)), 0);
        // buyback skipped in the cycle (remainder below minProcessAmount): no NEW deposit
        assertEq(basePool.depositCallCount(), depositsAfterStaging);
        // rescheduled, and another fee consumed from the 0.05 remainder
        assertEq(vault.pendingTriggerId(), 2);
        assertEq(vault.pendingBnb(), 0.05 ether - fee);
    }

    function test_trigger_gasUnderCallbackCap() public {
        // Pool pre-registered (setUp) so no heavy deployPool runs inside the callback.
        // NOTE: real myx deployPool gas is UNMEASURED (myx is not on BSC); the first
        // triggered processRevenue per token may need an out-of-band ensurePoolDeployed().
        _fund(1 ether);
        vault.scheduleTrigger(); // id 1

        uint256 gasBefore = gasleft();
        triggerService.fire(address(vault), 1);
        uint256 used = gasBefore - gasleft();

        assertLt(used, 2_000_000);
        emit log_named_uint("trigger callback gas", used);
    }

    function test_ensurePoolDeployed_permissionless() public {
        // Remove the pre-registered pool by deploying a fresh vault without setPool.
        // Simpler: use a token whose pool is not registered. Here we re-init a vault.
        MyxVault fresh = _deployVault(_freshParams());
        vm.prank(makeAddr("stranger"));
        fresh.ensurePoolDeployed();
        assertEq(poolManager.deployPoolCallCount(), 1);
    }

    function test_scheduleTrigger_revertsIfPoolNotDeployed() public {
        // Fresh vault whose myx pool is NOT pre-registered: scheduleTrigger must refuse to start
        // the loop until the heavy deployPool has run out-of-band via ensurePoolDeployed().
        MyxVault fresh = _deployVault(_freshParams());
        vm.deal(address(this), 1 ether);
        (bool ok,) = address(fresh).call{value: 1 ether}(""); // pendingBnb > fee
        assertTrue(ok);

        vm.expectRevert(MyxVault.PoolNotDeployed.selector);
        fresh.scheduleTrigger();

        // deploy the pool out-of-band (permissionless), then the loop can start
        fresh.ensurePoolDeployed();
        fresh.scheduleTrigger();
        assertEq(fresh.pendingTriggerId(), 1);
    }

    function test_runCycle_emitsLoopStalledWhenUnderfunded() public {
        // Start the loop with pendingBnb just above fee, then raise the fee above the remaining
        // pendingBnb so the in-cycle reschedule cannot afford the next trigger: the loop stalls.
        uint256 fee = triggerService.getFee();
        _fund(fee + 1); // pendingBnb = fee + 1: enough for the first schedule, nothing left after
        vault.scheduleTrigger(); // id 1, deducts one fee -> pendingBnb = 1 wei
        assertEq(vault.pendingTriggerId(), 1);
        assertEq(vault.pendingBnb(), 1);

        // raise the fee above the 1 wei remainder so the reschedule branch is skipped
        triggerService.setFee(1 ether);

        vm.expectEmit(true, true, true, true, address(vault));
        emit LoopStalled(1);
        triggerService.fire(address(vault), 1);

        // loop stopped: no new trigger scheduled, pendingBnb left for a manual restart
        assertEq(vault.pendingTriggerId(), 0);
        assertEq(vault.pendingBnb(), 1);
    }

    function test_trigger_modeSwitchedToAuto_completesCycleButDoesNotReschedule() public {
        // Loop is running in TRIGGERED mode with a trigger in-flight. The creator switches to AUTO
        // mid-cycle. The in-flight trigger must still complete its current cycle (feed + buyback+feed)
        // but MUST NOT re-arm the loop, so switching away from TRIGGERED cleanly winds it down.
        _fund(1 ether);
        vault.scheduleTrigger(); // id 1
        assertEq(vault.pendingTriggerId(), 1);

        // operator/creator decides to abandon automation
        vm.prank(creator);
        vault.setMode(MyxVault.Mode.AUTO);

        triggerService.fire(address(vault), 1);

        // current cycle still ran the buyback and fed the resulting LP into the dividend...
        assertGt(dividend.totalDeposited(), 0);
        assertEq(basePool.depositCallCount(), 1);
        assertGt(vault.totalLpMinted(), 0);
        assertEq(lpToken.balanceOf(address(vault)), 0, "LP flushed to the dividend");
        // ...but the loop did NOT re-arm: no new trigger scheduled, no extra fee skimmed.
        assertEq(vault.pendingTriggerId(), 0);
    }

    function test_trigger_modeSwitchedToManual_doesNotReschedule() public {
        // Same wind-down guarantee for the MANUAL target mode.
        _fund(1 ether);
        vault.scheduleTrigger(); // id 1
        assertEq(vault.pendingTriggerId(), 1);

        vm.prank(creator);
        vault.setMode(MyxVault.Mode.MANUAL);

        triggerService.fire(address(vault), 1);

        // loop wound down: no reschedule
        assertEq(vault.pendingTriggerId(), 0);
    }

    function _freshParams() internal returns (MyxVault.InitParams memory p) {
        // a tax token whose pool key is not pre-registered in poolManager
        MockTaxToken freshTax = new MockTaxToken(address(dividend));
        p.taxToken = address(freshTax);
        p.creator = creator;
        p.marketQuoteToken = address(usdt);
        p.poolManager = address(poolManager);
        p.basePool = address(basePool);
        p.maxSlippageBps = 300;
        p.minProcessAmount = 0.1 ether;
        p.triggerService = address(triggerService);
        p.triggerInterval = 1 hours;
    }
}

contract MyxVaultAutoDeployPoolTest is MyxVaultTestBase {
    function setUp() public override {
        super.setUp();
        // v6: when the cycle auto-deploys the pool, the deployed basePoolToken must be the real LP
        // so _feedDividend can feed it (dividend asset == LP). Wire deployPool to stamp the lpToken.
        poolManager.setLpTokenForDeploy(address(lpToken));
        portal.setRate(1000, 1);
    }

    function _fund(uint256 amount) internal {
        vm.deal(address(this), amount);
        (bool ok,) = address(vault).call{value: amount}("");
        assertTrue(ok);
    }

    function test_processRevenue_deploysPoolWhenMissing() public {
        // no setPool() — pool does not exist yet
        _fund(1 ether);
        vm.prank(creator);
        vault.processRevenue();
        assertEq(poolManager.deployPoolCallCount(), 1);
        assertEq(basePool.depositCallCount(), 1);
        // v6: the LP minted by the buyback is fed into the dividend
        assertEq(dividend.totalDeposited(), 1000 ether);
    }

    function test_processRevenue_skipsDeployWhenPoolExists() public {
        PoolMetadata memory meta;
        meta.baseToken = address(taxToken);
        meta.basePoolToken = address(lpToken);
        poolManager.setPool(MyxPoolId.derive(marketId, address(taxToken)), meta);
        _fund(1 ether);
        vm.prank(creator);
        vault.processRevenue();
        assertEq(poolManager.deployPoolCallCount(), 0);
    }

    function test_processRevenue_marketMissing_revertsAndRetainsBnb() public {
        poolManager.setMarketExists(false);
        _fund(1 ether);
        vm.prank(creator);
        vm.expectRevert("MockPoolManager: market missing");
        vault.processRevenue();
        assertEq(vault.pendingBnb(), 1 ether); // safely retained for retry after governance creates market
    }
}

/// @dev v6: the DIVIDEND ASSET is the myx base-pool LP (mBase) itself, not USDT. processRevenue
///      buys back the token, deposits it into myx (LP minted to the vault), then feeds the WHOLE
///      LP balance into the token's native Flap Dividend contract (whose dividendToken == the LP,
///      set at launch via computeDividendToken). Holders claim the LP via the dividend; the vault
///      no longer claims/handles any USDT rebate.
contract MyxVaultFeedDividendTest is MyxVaultTestBase {
    event DividendDeferred(uint256 lpAmount);
    event Harvested(uint256 rebateAmount, uint256 forwarded);

    function setUp() public override {
        super.setUp();
        // Register the tax-token pool with basePoolToken == the LP the mock pool mints, so
        // _feedDividend discovers the LP. The dividendToken == that SAME LP (v6 invariant), so
        // deposit() pulls exactly what the pool minted.
        PoolMetadata memory meta;
        meta.marketId = marketId;
        meta.poolId = MyxPoolId.derive(marketId, address(taxToken));
        meta.baseToken = address(taxToken);
        meta.quoteToken = address(usdt);
        meta.basePoolToken = address(lpToken);
        poolManager.setPool(meta.poolId, meta);
        dividend.setDividendToken(address(lpToken)); // v6: dividend asset IS the LP
        portal.setRate(1000, 1); // 1 BNB -> 1000 tax tokens
    }

    function _fund(uint256 amount) internal {
        vm.deal(address(this), amount);
        (bool ok,) = address(vault).call{value: amount}("");
        assertTrue(ok);
    }

    function test_processRevenue_feedsLpToDividend() public {
        _fund(1 ether);
        vm.prank(creator);
        vault.processRevenue();
        // 1 BNB -> 1000 tax tokens -> 1000 LP minted 1:1 -> the WHOLE LP fed into the dividend.
        assertEq(vault.totalLpMinted(), 1000 ether);
        assertEq(dividend.totalDeposited(), 1000 ether, "dividend must receive the minted LP");
        assertEq(lpToken.balanceOf(address(vault)), 0, "vault LP flushed to the dividend");
        assertEq(vault.totalRewardsForwarded(), 1000 ether);
    }

    function test_processRevenue_emitsHarvestedWithLpFed() public {
        _fund(1 ether);
        vm.expectEmit(true, true, true, true, address(vault));
        emit Harvested(1000 ether, 1000 ether);
        vm.prank(creator);
        vault.processRevenue();
    }

    function test_feedDividend_defersWhenTotalSharesZero() public {
        _fund(1 ether);
        dividend.setDepositSucceeds(false); // simulate totalShares == 0: deposit() returns false
        vm.expectEmit(true, true, true, true, address(vault));
        emit DividendDeferred(1000 ether);
        vm.prank(creator);
        vault.processRevenue();
        // LP retained in the vault, nothing deposited, no rewards counted
        assertEq(dividend.totalDeposited(), 0);
        assertEq(lpToken.balanceOf(address(vault)), 1000 ether, "LP deferred in vault");
        assertEq(vault.totalRewardsForwarded(), 0);

        // recovery: a permissionless feedDividend() flushes the deferred LP once shares exist
        dividend.setDepositSucceeds(true);
        vm.prank(makeAddr("stranger"));
        vault.feedDividend();
        assertEq(dividend.totalDeposited(), 1000 ether);
        assertEq(lpToken.balanceOf(address(vault)), 0, "deferred LP flushed on retry");
        assertEq(vault.totalRewardsForwarded(), 1000 ether);
    }

    function test_feedDividend_defersWhenNoDividendContract() public {
        _fund(1 ether);
        taxToken.setDividendContract(address(0)); // dividend not wired yet
        vm.expectEmit(true, true, true, true, address(vault));
        emit DividendDeferred(1000 ether);
        vm.prank(creator);
        vault.processRevenue();
        assertEq(dividend.totalDeposited(), 0);
        assertEq(lpToken.balanceOf(address(vault)), 1000 ether, "LP retained when dividend unwired");

        // once wired, feedDividend() flushes the retained LP
        taxToken.setDividendContract(address(dividend));
        vault.feedDividend();
        assertEq(dividend.totalDeposited(), 1000 ether);
        assertEq(lpToken.balanceOf(address(vault)), 0);
    }

    function test_feedDividend_noLp_noop() public {
        // no LP held: feedDividend is a no-op, no deposit, no revert
        vault.feedDividend();
        assertEq(dividend.totalDeposited(), 0);
        assertEq(vault.totalRewardsForwarded(), 0);
    }

    function test_feedDividend_permissionless() public {
        // accumulate LP via a successful processRevenue, then a stranger can re-run feedDividend
        // as a no-op (whole balance already flushed) — proves the entrypoint is open to anyone.
        _fund(1 ether);
        vm.prank(creator);
        vault.processRevenue();
        assertEq(lpToken.balanceOf(address(vault)), 0);
        vm.prank(makeAddr("stranger"));
        vault.feedDividend(); // must not revert
    }

    function test_feedDividend_flushesDeferredPlusNew() public {
        // First cycle defers (shares zero); a later processRevenue with shares available must feed
        // the WHOLE balance: the deferred LP plus the freshly minted LP.
        _fund(1 ether);
        dividend.setDepositSucceeds(false);
        vm.prank(creator);
        vault.processRevenue(); // 1000 LP deferred
        assertEq(lpToken.balanceOf(address(vault)), 1000 ether);

        dividend.setDepositSucceeds(true);
        _fund(1 ether);
        vm.prank(creator);
        vault.processRevenue(); // mints +1000 LP, feeds the whole 2000
        assertEq(dividend.totalDeposited(), 2000 ether, "whole balance (deferred + new) fed");
        assertEq(lpToken.balanceOf(address(vault)), 0);
        assertEq(vault.totalRewardsForwarded(), 2000 ether);
    }
}

/// @dev v6 claim proxy (Lista pattern): holders claim their mBase LP either directly on the
///      dividend contract or via the vault's claimReward() convenience, which proxies to
///      withdrawDividendsFor(msg.sender). pendingReward proxies withdrawableDividends.
contract MyxVaultClaimTest is MyxVaultTestBase {
    function setUp() public override {
        super.setUp();
        dividend.setDividendToken(address(lpToken)); // v6: dividend asset IS the LP
    }

    function test_claimReward_proxiesToDividend() public {
        address alice = makeAddr("alice");
        // dividend holds LP and owes alice 7 LP; claimReward pays it out via withdrawDividendsFor.
        lpToken.mint(address(dividend), 7 ether);
        dividend.setPending(alice, 7 ether);
        vm.prank(alice);
        vault.claimReward();
        assertEq(lpToken.balanceOf(alice), 7 ether, "alice received her LP via the proxy");
        assertEq(dividend.withdrawableDividends(alice), 0, "pending cleared");
    }

    function test_pendingReward_proxies() public {
        address alice = makeAddr("alice");
        dividend.setPending(alice, 5 ether);
        assertEq(vault.pendingReward(alice), 5 ether);
    }

    function test_pendingReward_zeroWhenNoDividendContract() public {
        taxToken.setDividendContract(address(0));
        assertEq(vault.pendingReward(makeAddr("nobody")), 0);
    }
}

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

contract MyxVaultViewsTest is MyxVaultTestBase {
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

    function test_vaultUISchema_exposesClaimAndFeed() public view {
        VaultMethodSchema[] memory methods = vault.vaultUISchema().methods;
        bool hasClaim;
        bool hasFeed;
        bool hasPending;
        for (uint256 i = 0; i < methods.length; i++) {
            bytes32 n = keccak256(bytes(methods[i].name));
            if (n == keccak256("claimReward")) hasClaim = true;
            if (n == keccak256("feedDividend")) hasFeed = true;
            if (n == keccak256("pendingReward")) hasPending = true;
        }
        assertTrue(hasClaim, "schema must expose claimReward");
        assertTrue(hasFeed, "schema must expose feedDividend");
        assertTrue(hasPending, "schema must expose pendingReward");
    }
}

/// @dev Inlined verbatim from myx-contract-v2 src/types/MarketKey.sol so this suite can assert,
///      without depending on the myx repo, that MyxMarketId.derive matches the upstream marketId.
struct RefMarketKey {
    uint64 chainId;
    address quoteToken;
}

library RefMarketIdLib {
    function toId(RefMarketKey memory marketKey) internal pure returns (MarketId marketId) {
        assembly ("memory-safe") {
            marketId := keccak256(marketKey, 0x40)
        }
    }
}

/// @notice Locks the empirical equivalence MyxMarketId.derive == myx MarketIdLib.toId (concrete + fuzz).
contract MyxMarketIdEquivalenceTest is Test {
    using RefMarketIdLib for RefMarketKey;

    function test_derive_matchesMyxToId_concrete() public pure {
        address quote = 0x55d398326f99059fF775485246999027B3197955; // BSC USDT
        MarketId got = MyxMarketId.derive(uint64(56), quote);
        MarketId want = RefMarketIdLib.toId(RefMarketKey({chainId: 56, quoteToken: quote}));
        assertEq(MarketId.unwrap(got), MarketId.unwrap(want));
    }

    function testFuzz_derive_matchesMyxToId(uint64 chainId, address quote) public pure {
        MarketId got = MyxMarketId.derive(chainId, quote);
        MarketId want = RefMarketIdLib.toId(RefMarketKey({chainId: chainId, quoteToken: quote}));
        assertEq(MarketId.unwrap(got), MarketId.unwrap(want));
    }
}
