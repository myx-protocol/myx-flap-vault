// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.26;

import {Test} from "forge-std/Test.sol";
import {MyxVault} from "../src/MyxVault.sol";
import {MarketId, PoolId, MyxPoolId, IMyxBasePool, PoolMetadata} from "../src/myx/IMyxPool.sol";
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
    MarketId marketId = MarketId.wrap(bytes32(uint256(1)));

    function setUp() public virtual {
        vm.chainId(56);
        wbnb = new MockWBNB();
        usdt = new MockERC20("Tether", "USDT");
        lpToken = new MockERC20("MYX LP", "MLP");
        basePool = new MockBasePool(lpToken, usdt);
        poolManager = new MockPoolManager();
        router = new MockPancakeRouter();
        bnbUsdFeed = new MockAggregatorV3(600e8, 8);  // BNB = $600
        usdtUsdFeed = new MockAggregatorV3(1e8, 8);   // USDT = $1
        // v4: the pool's quote token IS the dividend token; the claimed rebate is distributed
        // directly. Construct the dividend with dividendToken() == usdt so harvest's invariant
        // (pool.quoteToken == dividend.dividendToken()) holds.
        dividend = new MockDividendDistributor(address(usdt));
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
        p.marketId = marketId;
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
        // v3: the pool is keyed by the tax token itself (buyback design)
        assertEq(PoolId.unwrap(vault.poolId()), PoolId.unwrap(MyxPoolId.derive(marketId, address(taxToken))));
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
        assertEq(basePool.lastDepositRecipient(), address(vault)); // LP held by vault
        assertEq(lpToken.balanceOf(address(vault)), 1000 ether);
        assertEq(vault.totalLpMinted(), 1000 ether);
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
        assertEq(lpToken.balanceOf(address(vault)), 960 ether);
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
        // Register the tax-token pool with quoteToken == usdt == dividend.dividendToken()
        // so both the buyback (deposit) and the harvest (direct distribution) work in-cycle.
        PoolMetadata memory meta;
        meta.marketId = marketId;
        meta.poolId = MyxPoolId.derive(marketId, address(taxToken));
        meta.baseToken = address(taxToken);
        meta.quoteToken = address(usdt);
        meta.basePoolToken = address(lpToken);
        poolManager.setPool(meta.poolId, meta);
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
        basePool.setRebate(600 ether); // harvestable rebate
        uint256 fee = triggerService.getFee();
        _fund(1 ether); // well above minProcessAmount + fee
        vault.scheduleTrigger(); // id 1, reserves one fee
        assertEq(vault.pendingTriggerId(), 1);

        triggerService.fire(address(vault), 1);

        // harvest happened (rebate forwarded into the dividend contract)
        assertEq(dividend.totalDeposited(), 600 ether);
        // buyback happened (LP minted)
        assertEq(basePool.depositCallCount(), 1);
        assertGt(vault.totalLpMinted(), 0);
        // next cycle rescheduled (id 2), and pendingBnb consumed by the buyback
        assertEq(vault.pendingTriggerId(), 2);
        assertEq(vault.pendingBnb(), 0);

        // replay protection: firing id 1 again must revert (it has been consumed)
        vm.expectRevert(abi.encodeWithSelector(MyxVault.UnknownTrigger.selector, uint256(1)));
        triggerService.fire(address(vault), 1);
    }

    function test_trigger_harvestBackstopRunsEvenBelowBuybackThreshold() public {
        uint256 fee = triggerService.getFee();
        // pendingBnb strictly between fee and (minProcessAmount + fee) so that after the
        // reschedule fee is deducted, the remainder is below minProcessAmount: buyback skipped.
        uint256 funded = fee + 0.05 ether; // 0.05 < minProcessAmount (0.1)
        _fund(funded);
        basePool.setRebate(123 ether);
        vault.scheduleTrigger(); // id 1, deducts one fee -> pendingBnb = 0.05 ether
        assertEq(vault.pendingBnb(), 0.05 ether);

        triggerService.fire(address(vault), 1);

        // harvest backstop ran
        assertEq(dividend.totalDeposited(), 123 ether);
        // buyback skipped (remainder below minProcessAmount)
        assertEq(basePool.depositCallCount(), 0);
        // rescheduled, and another fee consumed from the 0.05 remainder
        assertEq(vault.pendingTriggerId(), 2);
        assertEq(vault.pendingBnb(), 0.05 ether - fee);
    }

    function test_trigger_gasUnderCallbackCap() public {
        // Pool pre-registered (setUp) so no heavy deployPool runs inside the callback.
        // NOTE: real myx deployPool gas is UNMEASURED (myx is not on BSC); the first
        // triggered processRevenue per token may need an out-of-band ensurePoolDeployed().
        basePool.setRebate(50 ether);
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
        // mid-cycle. The in-flight trigger must still complete its current cycle (harvest + buyback)
        // but MUST NOT re-arm the loop, so switching away from TRIGGERED cleanly winds it down.
        basePool.setRebate(600 ether);
        _fund(1 ether);
        vault.scheduleTrigger(); // id 1
        assertEq(vault.pendingTriggerId(), 1);

        // operator/creator decides to abandon automation
        vm.prank(creator);
        vault.setMode(MyxVault.Mode.AUTO);

        triggerService.fire(address(vault), 1);

        // current cycle still settled rewards and ran the buyback...
        assertEq(dividend.totalDeposited(), 600 ether);
        assertEq(basePool.depositCallCount(), 1);
        assertGt(vault.totalLpMinted(), 0);
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
        p.marketId = marketId;
        p.poolManager = address(poolManager);
        p.basePool = address(basePool);
        p.maxSlippageBps = 300;
        p.minProcessAmount = 0.1 ether;
        p.triggerService = address(triggerService);
        p.triggerInterval = 1 hours;
    }
}

contract MyxVaultAutoDeployPoolTest is MyxVaultTestBase {
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

contract MyxVaultHarvestTest is MyxVaultTestBase {
    function setUp() public override {
        super.setUp();
        // v4: harvest reads pool.quoteToken as the reward token. Register the pool so
        // pool.quoteToken == usdt == dividend.dividendToken() — the direct-distribution invariant.
        PoolMetadata memory meta;
        meta.marketId = marketId;
        meta.poolId = MyxPoolId.derive(marketId, address(taxToken));
        meta.baseToken = address(taxToken);
        meta.quoteToken = address(usdt);
        meta.basePoolToken = address(lpToken);
        poolManager.setPool(meta.poolId, meta);
    }

    function test_harvest_claimsAndDistributesDirectly() public {
        basePool.setRebate(600 ether); // 600 USDT pending
        vault.harvest();
        // No swap: the claimed USDT goes straight into the dividend contract.
        assertEq(dividend.totalDeposited(), 600 ether);
        assertEq(vault.totalRewardsForwarded(), 600 ether);
        assertEq(usdt.balanceOf(address(vault)), 0);
    }

    function test_harvest_noRebate_noop() public {
        vault.harvest();
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

    function test_harvest_dividendTokenMismatch_reverts() public {
        // invariant break: the dividend contract's token no longer matches the pool quote.
        basePool.setRebate(600 ether);
        address other = makeAddr("other");
        dividend.setDividendToken(other);
        vm.expectRevert(
            abi.encodeWithSelector(MyxVault.DividendTokenMismatch.selector, address(usdt), other)
        );
        vault.harvest();
        assertEq(dividend.totalDeposited(), 0);
    }

    function test_harvest_zeroDividendContract_reverts() public {
        basePool.setRebate(600 ether);
        taxToken.setDividendContract(address(0));
        vm.expectRevert(MyxVault.ZeroDividendContract.selector);
        vault.harvest();
    }

    function test_harvest_forwardedEqualsClaimed() public {
        basePool.setRebate(123 ether);
        vault.harvest();
        assertEq(vault.totalRewardsForwarded(), dividend.totalDeposited());
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
    function setUp() public override {
        super.setUp();
        // Register the pool so userLpShare can discover basePoolToken == address(lpToken)
        PoolMetadata memory meta;
        meta.marketId = marketId;
        meta.poolId = MyxPoolId.derive(marketId, address(taxToken));
        meta.baseToken = address(taxToken);
        meta.basePoolToken = address(lpToken);
        poolManager.setPool(meta.poolId, meta);
    }

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
