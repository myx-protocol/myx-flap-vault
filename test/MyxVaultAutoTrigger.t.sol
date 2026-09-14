// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.26;

import {Test} from "forge-std/Test.sol";
import {MyxVault} from "../src/MyxVault.sol";
import {MarketId, PoolId, MyxPoolId, MyxMarketId, PoolMetadata} from "../src/myx/IMyxPool.sol";
import {ERC1967Proxy} from "@openzeppelin/proxy/ERC1967/ERC1967Proxy.sol";
import "./mocks/Mocks.sol";

/// @dev Native-quote auto-trigger fixture. The myx pool is pre-registered (as the off-chain MYX
///      service does on mainnet) because scheduling is gated on pool existence;
///      MyxVaultPoolGateTest starts without a pool and covers the gate itself.
contract MyxVaultAutoTriggerFixture is Test {
    MyxVault vault;
    MockERC20 usdt;
    MockERC20 lpToken;
    MockBasePool basePool;
    MockPoolManager poolManager;
    MockPortal portal;
    MockDividendDistributor dividend;
    MockTaxToken taxToken;
    MockFlapTriggerService triggerService;

    address creator = makeAddr("creator");
    address constant PORTAL = 0xe2cE6ab80874Fa9Fa2aAE65D277Dd6B8e65C9De0;
    address constant TRIGGER_SERVICE = 0xcf4EE25035CF883895110f367F5BA8172416a7F9;
    MarketId marketId;

    function setUp() public {
        vm.chainId(56);
        usdt = new MockERC20("Tether", "USDT");
        marketId = MyxMarketId.derive(uint64(56), address(usdt));
        lpToken = new MockERC20("MYX LP", "MLP");
        basePool = new MockBasePool(lpToken, usdt);
        poolManager = new MockPoolManager();
        dividend = new MockDividendDistributor(address(lpToken));
        taxToken = new MockTaxToken(address(dividend));

        MockPortal portalImpl = new MockPortal();
        vm.etch(PORTAL, address(portalImpl).code);
        portal = MockPortal(PORTAL);
        portal.setRate(1000, 1); // 1 BNB -> 1000 tax tokens

        // deployPool (when a test exercises it) stamps lpToken as basePoolToken so _feedDividend
        // finds a live ERC20.
        poolManager.setLpTokenForDeploy(address(lpToken));
        dividend.setDividendToken(address(lpToken));

        // Etch the trigger-service mock at the hardcoded address; vm.etch zeroes storage.
        MockFlapTriggerService tsImpl = new MockFlapTriggerService();
        vm.etch(TRIGGER_SERVICE, address(tsImpl).code);
        triggerService = MockFlapTriggerService(TRIGGER_SERVICE);
        triggerService.setFee(0.001 ether);

        vault = _deployVault();
        if (_poolPreDeployed()) _registerPool();
    }

    /// @dev Suites that test the pool gate override this to start without a pool.
    function _poolPreDeployed() internal pure virtual returns (bool) {
        return true;
    }

    function _registerPool() internal {
        PoolMetadata memory meta;
        meta.marketId = marketId;
        meta.poolId = MyxPoolId.derive(marketId, address(taxToken));
        meta.baseToken = address(taxToken);
        meta.basePoolToken = address(lpToken);
        poolManager.setPool(meta.poolId, meta);
    }

    function _deployVault() internal returns (MyxVault) {
        MyxVault impl = new MyxVault();
        MyxVault.InitParams memory p;
        p.taxToken = address(taxToken);
        p.creator = creator;
        p.quoteToken = address(0);
        p.marketQuoteToken = address(usdt);
        p.poolManager = address(poolManager);
        p.basePool = address(basePool);
        p.maxSlippageBps = 300;
        p.minProcessAmount = 0.1 ether;
        p.maxProcessAmount = type(uint256).max;
        bytes memory initData = abi.encodeCall(MyxVault.initialize, (p));
        return MyxVault(payable(address(new ERC1967Proxy(address(impl), initData))));
    }

    function _fund(uint256 amount) internal {
        vm.deal(address(this), amount);
        (bool ok,) = address(vault).call{value: amount}("");
        assertTrue(ok);
    }

    receive() external payable {}
}

/// @dev Auto-trigger: receive() schedules a delayed process() through FlapTriggerService.
contract MyxVaultAutoTriggerTest is MyxVaultAutoTriggerFixture {
    // ── scheduling in receive() ──────────────────────────────────────────────

    function test_receive_schedulesWhenAboveThreshold() public {
        uint256 fee = triggerService.getFee();
        _fund(1 ether);
        assertTrue(vault.hasPendingTrigger(), "trigger scheduled");
        assertEq(vault.pendingTriggerId(), 1);
        assertEq(vault.pendingQuote(), 1 ether - fee, "fee deducted from pending");
        assertEq(triggerService.requesterOf(1), address(vault));
        assertEq(triggerService.lastExecuteAfter(), uint64(block.timestamp + 60));
    }

    function test_receive_idempotentWhilePending() public {
        _fund(1 ether);
        _fund(1 ether); // second receipt while a trigger is in-flight
        assertEq(triggerService.lastRequestId(), 1, "must not schedule a second trigger");
        assertEq(vault.pendingTriggerId(), 1);
        assertEq(vault.pendingQuote(), 2 ether - triggerService.getFee(), "both receipts accrued, fee once");
    }

    function test_receive_belowThreshold_noSchedule() public {
        _fund(0.05 ether); // < minProcessAmount 0.1
        assertFalse(vault.hasPendingTrigger());
        assertEq(vault.pendingQuote(), 0.05 ether, "full tax retained, no fee");
    }

    function test_receive_belowMinPlusFee_noScheduleNoLoss() public {
        triggerService.setFee(0.2 ether); // minProcessAmount + fee = 0.3
        _fund(0.15 ether); // >= min 0.1 but < min + fee 0.3 -> can't schedule and still keep min
        assertFalse(vault.hasPendingTrigger());
        assertEq(vault.pendingQuote(), 0.15 ether, "no fee charged, no tax lost");
    }

    function test_receive_serviceReverts_doesNotRevertReceive() public {
        triggerService.setRequestReverts(true);
        _fund(1 ether); // must not revert
        assertFalse(vault.hasPendingTrigger());
        assertEq(vault.pendingQuote(), 1 ether, "full tax retained when scheduling fails");
    }

    /// @dev The schedule decision compares ACCUMULATED pendingQuote against (min + fee), NOT the
    ///      per-receipt msg.value. A small receipt must still schedule once the accrued balance
    ///      crosses the threshold.
    function test_receive_comparesAccumulatedPendingNotReceipt() public {
        triggerService.setFee(0.05 ether);
        // First receipt can't schedule (service down) — pendingQuote accumulates.
        triggerService.setRequestReverts(true);
        _fund(0.14 ether);
        assertFalse(vault.hasPendingTrigger());
        assertEq(vault.pendingQuote(), 0.14 ether);

        // Service recovers. A small receipt (0.02 <= fee 0.05) must STILL schedule because the
        // accumulated pendingQuote (0.16) >= minProcessAmount + fee (0.15).
        triggerService.setRequestReverts(false);
        _fund(0.02 ether);
        assertTrue(vault.hasPendingTrigger(), "schedule decided on accumulated pendingQuote");
        assertEq(vault.pendingQuote(), 0.16 ether - 0.05 ether, "fee deducted from accumulated pending");
    }

    /// @dev Audit v2 F1 is a false positive: `requestTrigger{value: fee}` sends the fee OUT of the
    ///      vault, so the actual BNB balance drops by exactly the same `fee` debited from pendingQuote.
    ///      The (balance == pendingQuote) invariant holds, and process() forwards amount == pendingQuote
    ///      == balance — it can never run out of BNB / be bricked.
    function test_invariant_vaultBalanceEqualsPendingQuote() public {
        _fund(1 ether);
        assertTrue(vault.hasPendingTrigger());
        assertEq(address(vault).balance, vault.pendingQuote(), "balance must equal pendingQuote after schedule");

        vm.warp(block.timestamp + 61);
        vm.prank(address(vault));
        vault.process(); // forwards amount == pendingQuote == balance; cannot revert on insufficient BNB
        assertEq(vault.pendingQuote(), 0);
        assertEq(address(vault).balance, 0, "balance and pendingQuote both drained after process");
    }

    // ── trigger() callback ───────────────────────────────────────────────────

    function test_trigger_executesProcessAndClears() public {
        _fund(1 ether);
        uint256 id = vault.pendingTriggerId();
        vm.warp(block.timestamp + 61);
        triggerService.fire(id);
        assertEq(vault.pendingQuote(), 0, "process consumed pendingQuote");
        assertFalse(vault.hasPendingTrigger(), "in-flight flag cleared");
        assertEq(vault.pendingTriggerId(), 0);
        assertGt(vault.totalLpMinted(), 0, "process minted LP");
    }

    function test_trigger_processReverts_stillClears() public {
        _fund(1 ether);
        uint256 id = vault.pendingTriggerId();
        vm.prank(address(vault));
        vault.process(); // drain pendingQuote via permissionless process first
        assertEq(vault.pendingQuote(), 0);
        vm.warp(block.timestamp + 61);
        triggerService.fire(id); // callback's process() reverts (0 < min) but must still clear state
        assertFalse(vault.hasPendingTrigger(), "cleared even when process reverts");
        assertEq(vault.pendingTriggerId(), 0);
    }

    function test_trigger_wrongSender_reverts() public {
        _fund(1 ether);
        uint256 id = vault.pendingTriggerId();
        vm.prank(makeAddr("attacker"));
        vm.expectRevert();
        vault.trigger(id);
    }

    function test_trigger_staleId_ignored() public {
        _fund(1 ether);
        vm.prank(TRIGGER_SERVICE);
        vault.trigger(999_999); // unknown id -> ignored, no revert, state intact
        assertTrue(vault.hasPendingTrigger(), "state unchanged on stale id");
        assertEq(vault.pendingTriggerId(), 1);
    }

    function test_trigger_gasWithinCallbackLimit() public {
        _fund(1 ether);
        uint256 id = vault.pendingTriggerId();
        vm.warp(block.timestamp + 61);
        uint256 maxGas = triggerService.getMaxCallbackGas();
        vm.prank(TRIGGER_SERVICE);
        uint256 g0 = gasleft();
        vault.trigger(id);
        uint256 used = g0 - gasleft();
        assertLt(used, maxGas, "steady-state callback must fit maxCallbackGas");
    }
}

/// @dev Batched buyback: a single process() consumes at most maxProcessAmount of pendingQuote and,
///      when a remainder >= minProcessAmount is left, schedules its own follow-up trigger. Bounds the
///      per-call sandwich exposure after any accumulation (e.g. a failed first callback).
contract MyxVaultBatchedProcessTest is MyxVaultAutoTriggerTest {
    event ProcessBatched(uint256 processed, uint256 remaining);

    function _deployCappedVault(uint256 cap) internal returns (MyxVault) {
        MyxVault impl = new MyxVault();
        MyxVault.InitParams memory p;
        p.taxToken = address(taxToken);
        p.creator = creator;
        p.quoteToken = address(0);
        p.marketQuoteToken = address(usdt);
        p.poolManager = address(poolManager);
        p.basePool = address(basePool);
        p.maxSlippageBps = 300;
        p.minProcessAmount = 0.1 ether;
        p.maxProcessAmount = cap;
        return MyxVault(payable(address(new ERC1967Proxy(address(impl), abi.encodeCall(MyxVault.initialize, (p))))));
    }

    function test_initialize_maxProcessBelowMin_reverts() public {
        MyxVault impl = new MyxVault();
        MyxVault.InitParams memory p;
        p.taxToken = address(taxToken);
        p.creator = creator;
        p.marketQuoteToken = address(usdt);
        p.poolManager = address(poolManager);
        p.basePool = address(basePool);
        p.minProcessAmount = 0.1 ether;
        p.maxProcessAmount = 0.1 ether - 1;
        vm.expectRevert(bytes(unicode"Max process amount below minimum / 單批處理上限低於最低處理金額"));
        new ERC1967Proxy(address(impl), abi.encodeCall(MyxVault.initialize, (p)));
    }

    function test_process_capsAtMaxAndSchedulesFollowUp() public {
        vault = _deployCappedVault(1 ether);
        uint256 fee = triggerService.getFee();
        _fund(3 ether); // schedules #1, pendingQuote = 3 - fee
        uint256 id = vault.pendingTriggerId();
        vm.warp(block.timestamp + 61);

        vm.expectEmit(true, true, true, true);
        emit ProcessBatched(1 ether, 3 ether - fee - 1 ether);
        triggerService.fire(id); // batch 1: consumes 1 ether, remainder 2 - fee -> follow-up #2 (fee again)
        assertEq(vault.pendingQuote(), 3 ether - 2 * fee - 1 ether, "remainder kept, follow-up fee paid");
        assertTrue(vault.hasPendingTrigger(), "follow-up scheduled by process()");
        assertEq(vault.pendingTriggerId(), id + 1);
        assertEq(address(vault).balance, vault.pendingQuote(), "native invariant holds across batches");

        vm.warp(block.timestamp + 61);
        triggerService.fire(id + 1); // batch 2: another 1 ether, remainder 1 - 3 fee -> follow-up #3
        assertTrue(vault.hasPendingTrigger());
        vm.warp(block.timestamp + 61);
        triggerService.fire(id + 2); // batch 3: below cap, consumes everything, no follow-up
        assertEq(vault.pendingQuote(), 0);
        assertFalse(vault.hasPendingTrigger(), "nothing left to schedule");
        assertEq(vault.totalLpMinted(), (3 ether - 3 * fee) * 1000, "all three batches bought back");
    }

    function test_process_manualCall_alsoCapsAndSchedules() public {
        vault = _deployCappedVault(1 ether);
        triggerService.setRequestReverts(true); // receive() cannot schedule
        _fund(2.5 ether);
        assertFalse(vault.hasPendingTrigger());
        triggerService.setRequestReverts(false);
        vm.prank(makeAddr("keeper"));
        vault.requestProcess(); // manual entry: schedules the service callback, does not swap
        uint256 id = vault.pendingTriggerId();
        vm.warp(block.timestamp + 61);
        triggerService.fire(id);
        assertEq(vault.pendingQuote(), 1.5 ether - 2 * triggerService.getFee(), "request fee + follow-up fee");
        assertTrue(vault.hasPendingTrigger(), "callback's process() schedules the remainder");
    }

    function test_process_noFollowUpWhenRemainderBelowMin() public {
        vault = _deployCappedVault(1 ether);
        triggerService.setRequestReverts(true);
        _fund(1.05 ether); // remainder 0.05 < min 0.1
        triggerService.setRequestReverts(false);
        vm.prank(address(vault));
        vault.process();
        assertEq(vault.pendingQuote(), 0.05 ether, "dust remainder retained for the next batch");
        assertFalse(vault.hasPendingTrigger(), "no follow-up below minProcessAmount");
    }

    function test_process_uncapped_behavesAsBefore() public {
        _fund(3 ether); // default vault: maxProcessAmount = max
        uint256 id = vault.pendingTriggerId();
        vm.warp(block.timestamp + 61);
        triggerService.fire(id);
        assertEq(vault.pendingQuote(), 0);
        assertFalse(vault.hasPendingTrigger());
    }
}

/// @dev process() is executed only through the FlapTriggerService callback (MEV-protected
///      submission per Flap). The manual entry point is requestProcess(): it schedules the
///      callback and never swaps in the caller's transaction.
contract MyxVaultTriggerOnlyProcessTest is MyxVaultAutoTriggerTest {
    function test_process_directCall_reverts() public {
        _fund(1 ether);
        vm.prank(makeAddr("keeper"));
        vm.expectRevert(bytes(unicode"Caller must be the vault itself / 僅限金庫自身調用"));
        vault.process();
        assertEq(vault.pendingQuote(), 1 ether - triggerService.getFee(), "nothing swapped");
    }

    function test_requestProcess_native_schedulesAndPaysFromRevenue() public {
        triggerService.setRequestReverts(true);
        _fund(1 ether); // receive() could not schedule
        triggerService.setRequestReverts(false);
        assertFalse(vault.hasPendingTrigger());
        vm.prank(makeAddr("keeper"));
        vault.requestProcess();
        assertTrue(vault.hasPendingTrigger());
        assertEq(vault.pendingQuote(), 1 ether - triggerService.getFee(), "fee debited from revenue");
        assertEq(address(vault).balance, vault.pendingQuote(), "native invariant");
        uint256 id = vault.pendingTriggerId();
        vm.warp(block.timestamp + 61);
        triggerService.fire(id);
        assertEq(vault.pendingQuote(), 0, "callback executed the buyback");
    }

    function test_requestProcess_whilePending_reverts() public {
        _fund(1 ether); // auto-scheduled
        assertTrue(vault.hasPendingTrigger());
        vm.expectRevert(bytes(unicode"Trigger already pending / 已有待執行的觸發"));
        vault.requestProcess();
    }

    function test_requestProcess_native_rejectsValue() public {
        vm.deal(address(this), 1 ether);
        vm.expectRevert(bytes(unicode"Gas pool only for ERC20 quote / 僅 ERC20 報價幣金庫可充值 Gas"));
        vault.requestProcess{value: 0.01 ether}();
    }

    function test_requestProcess_belowMinimum_reverts() public {
        triggerService.setRequestReverts(true);
        _fund(0.05 ether);
        triggerService.setRequestReverts(false);
        vm.expectRevert(bytes(unicode"Pending below minimum plus fee / 待處理低於下限加手續費"));
        vault.requestProcess();
    }
}

/// @dev Pool gate: no trigger is requested until the myx pool exists. The vault probes the pool
///      only while the `poolReady` latch is unset; once set (by observation or by
///      ensurePoolDeployed) it never probes again.
contract MyxVaultPoolGateTest is MyxVaultAutoTriggerFixture {
    event PoolReady(PoolId poolId);

    function _poolPreDeployed() internal pure override returns (bool) {
        return false;
    }

    /// @dev Makes any pool-manager read revert. Armed only around wake paths (receive /
    ///      requestProcess / ensurePoolDeployed): process() itself legitimately reads the pool
    ///      metadata for the LP address when feeding the dividend.
    function _forbidPoolProbe() internal {
        vm.mockCallRevert(
            address(poolManager), abi.encodeWithSelector(MockPoolManager.getPool.selector), "pool probed after latch"
        );
    }

    function _allowPoolReads() internal {
        vm.clearMockedCalls();
    }

    function test_receive_poolMissing_noScheduleNoFee() public {
        _fund(1 ether);
        assertFalse(vault.poolReady());
        assertFalse(vault.hasPendingTrigger(), "no trigger before the pool exists");
        assertEq(vault.pendingQuote(), 1 ether, "no fee taken");
        assertEq(poolManager.deployPoolCallCount(), 0, "the vault never deploys on a wake");
    }

    function test_receive_poolDeployedLater_latchesAndSchedules() public {
        _fund(1 ether);
        _registerPool();
        vm.expectEmit(true, true, true, true);
        emit PoolReady(MyxPoolId.derive(marketId, address(taxToken)));
        _fund(1 wei);
        assertTrue(vault.poolReady());
        assertTrue(vault.hasPendingTrigger(), "first wake after deployment schedules");
        assertEq(vault.pendingQuote(), 1 ether + 1 wei - triggerService.getFee());
    }

    function test_receive_afterLatch_neverProbesAgain() public {
        _registerPool();
        _fund(1 ether);
        assertTrue(vault.poolReady());
        uint256 id = vault.pendingTriggerId();
        vm.warp(block.timestamp + 61);
        vm.prank(TRIGGER_SERVICE);
        vault.trigger(id);
        assertEq(vault.pendingQuote(), 0);
        assertEq(poolManager.deployPoolCallCount(), 0, "callback never deploys once latched");
        _forbidPoolProbe();
        _fund(1 ether);
        assertTrue(vault.hasPendingTrigger(), "re-scheduled without probing the pool");
    }

    function test_receive_latchSurvivesFailedSchedule() public {
        _registerPool();
        triggerService.setRequestReverts(true);
        _fund(1 ether);
        assertTrue(vault.poolReady(), "latch persists even though scheduling failed");
        assertFalse(vault.hasPendingTrigger());
        triggerService.setRequestReverts(false);
        _forbidPoolProbe();
        _fund(1 wei);
        assertTrue(vault.hasPendingTrigger());
    }

    function test_ensurePoolDeployed_deploysLatchesAndSchedulesBacklog() public {
        _fund(1 ether);
        assertFalse(vault.hasPendingTrigger());
        vm.expectEmit(true, true, true, true);
        emit PoolReady(MyxPoolId.derive(marketId, address(taxToken)));
        vm.prank(makeAddr("myx-service"));
        vault.ensurePoolDeployed();
        assertEq(poolManager.deployPoolCallCount(), 1);
        assertTrue(vault.poolReady());
        assertTrue(vault.hasPendingTrigger(), "backlog above minimum is scheduled right away");
        assertEq(vault.pendingQuote(), 1 ether - triggerService.getFee());
    }

    function test_ensurePoolDeployed_noBacklog_latchesWithoutSchedule() public {
        vault.ensurePoolDeployed();
        assertTrue(vault.poolReady());
        assertFalse(vault.hasPendingTrigger());
        _fund(1 ether);
        assertTrue(vault.hasPendingTrigger(), "switch is open: the next tax receipt schedules");
    }

    function test_ensurePoolDeployed_backlogBelowMinimum_noSchedule() public {
        _fund(0.05 ether);
        vault.ensurePoolDeployed();
        assertTrue(vault.poolReady());
        assertFalse(vault.hasPendingTrigger());
        assertEq(vault.pendingQuote(), 0.05 ether);
    }

    function test_ensurePoolDeployed_secondCall_noReprobeNoRedeploy() public {
        vault.ensurePoolDeployed();
        _forbidPoolProbe();
        vault.ensurePoolDeployed();
        assertEq(poolManager.deployPoolCallCount(), 1);
    }

    function test_ensurePoolDeployed_poolAlreadyExists_latchesOnly() public {
        _registerPool();
        vault.ensurePoolDeployed();
        assertEq(poolManager.deployPoolCallCount(), 0);
        assertTrue(vault.poolReady());
    }

    function test_requestProcess_poolMissing_reverts() public {
        _fund(1 ether);
        vm.expectRevert(bytes(unicode"Pool not deployed / 池尚未部署"));
        vault.requestProcess();
        assertFalse(vault.poolReady());
    }

    function test_requestProcess_poolDeployed_latchesAndSchedules() public {
        _fund(1 ether);
        _registerPool();
        vault.requestProcess();
        assertTrue(vault.poolReady());
        assertTrue(vault.hasPendingTrigger());
    }

    function test_scheduleProcess_requiresLatch() public {
        _fund(1 ether);
        _registerPool(); // pool exists, but scheduleProcess itself never probes: the latch decides
        vm.prank(address(vault));
        vm.expectRevert(bytes(unicode"Pool not deployed / 池尚未部署"));
        vault.scheduleProcess();
    }

    function test_process_batchFollowUp_afterLatch_noReprobe() public {
        _registerPool();
        MyxVault impl = new MyxVault();
        MyxVault.InitParams memory p;
        p.taxToken = address(taxToken);
        p.creator = creator;
        p.marketQuoteToken = address(usdt);
        p.poolManager = address(poolManager);
        p.basePool = address(basePool);
        p.maxSlippageBps = 300;
        p.minProcessAmount = 0.1 ether;
        p.maxProcessAmount = 0.5 ether;
        vault = MyxVault(payable(address(new ERC1967Proxy(address(impl), abi.encodeCall(MyxVault.initialize, (p))))));
        _fund(1 ether);
        uint256 id = vault.pendingTriggerId();
        vm.warp(block.timestamp + 61);
        vm.prank(TRIGGER_SERVICE);
        vault.trigger(id);
        assertTrue(vault.hasPendingTrigger(), "follow-up batch scheduled");
        assertEq(poolManager.deployPoolCallCount(), 0, "batches never re-check or deploy the pool");
    }
}
