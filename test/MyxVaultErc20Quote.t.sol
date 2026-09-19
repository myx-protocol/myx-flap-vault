// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.26;

import {Test} from "forge-std/Test.sol";
import {MyxVault} from "../src/MyxVault.sol";
import {MarketId, PoolId, MyxPoolId, MyxMarketId, PoolMetadata} from "../src/myx/IMyxPool.sol";
import {ERC1967Proxy} from "@openzeppelin/proxy/ERC1967/ERC1967Proxy.sol";
import "./mocks/Mocks.sol";
import {IMultiDexRouter} from "../src/flap/IMultiDexRouter.sol";

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
        p.maxProcessAmount = type(uint256).max; // no batching in the legacy suites
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

    /// @dev Audit round 1, Finding 4: initialize re-validates the slippage bound (defense in depth).
    function test_initialize_slippageAboveCap_reverts() public {
        MyxVault.InitParams memory p = _initParams();
        p.maxSlippageBps = 1_001;
        MyxVault impl = new MyxVault();
        vm.expectRevert(bytes(unicode"Slippage above 10% / 滑點超過 10%"));
        new ERC1967Proxy(address(impl), abi.encodeCall(MyxVault.initialize, (p)));
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
        // Gas pool funded above threshold so the auto-schedule trigger in receive() can pay the
        // FlapTriggerService fee from the BNB gas pool without touching pendingQuote (Task 6).
        vm.deal(address(vault), GAS_REFILL);
    }

    function test_process_buysWithErc20QuoteAndFeedsLp() public {
        _sendTax(20 ether);
        vm.prank(address(vault));
        vault.process();
        assertEq(vault.pendingQuote(), 0);
        assertEq(rwa.balanceOf(address(vault)), 0, "all quote spent");
        assertEq(rwa.balanceOf(PORTAL), 20 ether, "portal pulled the ERC20 input");
        assertEq(basePool.lastDepositAmount(), 20_000 ether);
        assertEq(dividend.totalDeposited(), 20_000 ether, "LP fed to dividend");
    }

    function test_process_recognizesUnpingedRevenueFirst() public {
        rwa.mint(address(vault), 20 ether); // no ping
        vm.prank(address(vault));
        vault.process(); // must sync then run
        assertEq(basePool.lastDepositAmount(), 20_000 ether);
    }

    function test_process_belowMinimum_reverts() public {
        _sendTax(MIN_PROCESS - 1);
        vm.expectRevert(bytes(unicode"Pending below minimum / 待處理金額低於下限"));
        vm.prank(address(vault));
        vault.process();
    }

    function test_process_swapReverts_retainsQuote() public {
        _sendTax(20 ether);
        portal.setRate(0, 1);
        vm.expectRevert(bytes(unicode"Buyback quote is zero / 回購報價為零"));
        vm.prank(address(vault));
        vault.process();
        assertEq(vault.pendingQuote(), 20 ether);
        assertEq(rwa.balanceOf(address(vault)), 20 ether);
    }
}

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

/// @dev Refill leg. A callback is capped at 2M gas by the trigger service and the buyback alone
///      needs ~1.7M on mainnet, so whenever the refill actually spends gas (a swap ran, or the swap
///      reverted late) process() ends as a REFILL-ONLY batch and schedules the buyback as its own
///      follow-up callback. A refill that is skipped cheaply (no venue / no pool / zero quote) falls
///      through to the buyback in the same call. The follow-up skips the refill check once
///      (`skipRefillOnce`) so a thin pool can never loop refill-after-refill without buying back.
contract MyxVaultErc20RefillTest is MyxVaultErc20QuoteTestBase {
    event GasRefilled(uint256 quoteIn, uint256 nativeOut, uint24 fee);
    event GasRefillSkipped(uint256 pendingQuote);
    event RefillOnlyBatch(uint256 pendingQuote);

    function _fireFollowUp() internal {
        assertTrue(vault.hasPendingTrigger(), "follow-up must have been scheduled");
        uint256 id = vault.pendingTriggerId();
        vm.warp(block.timestamp + 61);
        triggerService.fire(id);
    }

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
    ///      Call 1 refills only and schedules the buyback; the follow-up callback buys back.
    function test_process_refillsGas_thenBuysBackOnFollowUp() public {
        _sendTax(100 ether);
        vm.expectEmit(false, false, false, false);
        emit GasRefilled(0, 0, 0);
        vm.prank(address(vault));
        vault.process();
        assertEq(router.lastFeeUsed(), 2500);
        uint256 quoteIn = router.lastAmountIn();
        assertApproxEqRel(quoteIn, 16.666 ether, 0.01e18, "linear estimate of quote needed");
        assertGe(address(vault).balance, GAS_THRESHOLD, "gas pool refilled to ~target");
        assertEq(basePool.depositCallCount(), 0, "refill-only batch: no buyback in this call");
        assertEq(vault.pendingQuote(), 100 ether - quoteIn, "batch retained for the follow-up");
        assertTrue(vault.skipRefillOnce(), "follow-up will skip the refill check");

        _fireFollowUp();
        assertEq(basePool.lastDepositAmount(), (100 ether - quoteIn) * 1000, "remainder bought back");
        assertEq(vault.pendingQuote(), 0);
        assertFalse(vault.skipRefillOnce());
        assertFalse(vault.hasPendingTrigger());
    }

    /// @dev The refill-only batch emits RefillOnlyBatch with the quote left for the follow-up.
    function test_process_refillOnlyBatch_emitsAndSchedules() public {
        _sendTax(100 ether);
        vm.expectEmit(false, false, false, false);
        emit RefillOnlyBatch(0);
        vm.prank(address(vault));
        vault.process();
        assertTrue(vault.hasPendingTrigger(), "buyback scheduled as its own callback");
        assertEq(triggerService.requesterOf(vault.pendingTriggerId()), address(vault));
    }

    /// @dev Thin pool: the capped refill cannot reach gasThreshold. The follow-up must still buy
    ///      back (skipRefillOnce) instead of refilling again; only the call after that re-checks.
    function test_process_afterRefillBatch_buysBackEvenBelowThreshold() public {
        triggerService.setFee(0.0001 ether);
        router.setRate(2500, 1, 100000); // 100 RWA -> 0.001 BNB, far below the 0.05 target
        _sendTax(100 ether);
        vm.prank(address(vault));
        vault.process();
        assertEq(router.lastAmountIn(), 20 ether, "capped at 20% of the batch");
        assertLt(address(vault).balance, GAS_THRESHOLD, "still below threshold after the capped refill");
        assertEq(basePool.depositCallCount(), 0);

        _fireFollowUp();
        assertEq(basePool.lastDepositAmount(), 80_000 ether, "buyback ran despite gas < threshold");
        assertEq(vault.pendingQuote(), 0);
        assertFalse(vault.skipRefillOnce(), "skip consumed");

        // Next batch re-enters the refill check as usual.
        _sendTax(100 ether);
        vm.prank(address(vault));
        vault.process();
        assertEq(router.lastAmountIn(), 20 ether, "refill attempted again on the next batch");
        assertTrue(vault.skipRefillOnce());
    }

    function test_process_noRefillWhenGasAboveThreshold() public {
        // Fund with headroom for the trigger fee _sendTax's ping auto-schedules from this same BNB
        // pool (Task 6): otherwise the fee debit alone would drop the balance below GAS_THRESHOLD
        // before process() ever runs, which is a different scenario than the one under test.
        vault.fundGas{value: GAS_THRESHOLD + triggerService.getFee()}();
        _sendTax(100 ether);
        vm.prank(address(vault));
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
        vm.prank(address(vault));
        vault.process();
        assertEq(router.lastFeeUsed(), 500);
    }

    function test_process_quoteRevertOnOneTier_isIgnored() public {
        router.setPool(500, true);
        router.setQuoteReverts(500, true);
        _sendTax(100 ether);
        vm.prank(address(vault));
        vault.process();
        assertEq(router.lastFeeUsed(), 2500);
    }

    /// @dev A cheap skip (no pool at all) does not cost a callback: the buyback runs in the same call.
    function test_process_noPool_skipsRefillAndStillBuysBack() public {
        router.setPool(2500, false);
        _sendTax(100 ether);
        vm.expectEmit(true, true, true, true);
        emit GasRefillSkipped(100 ether);
        vm.prank(address(vault));
        vault.process();
        assertEq(address(vault).balance, 0);
        assertEq(basePool.lastDepositAmount(), 100_000 ether);
        assertFalse(vault.skipRefillOnce());
    }

    /// @dev A tier whose pool contract exists but holds no liquidity is skipped BEFORE quoting: on
    ///      mainnet such a quote walks the whole tick bitmap and burns ~450k gas for nothing.
    function test_bestPool_skipsZeroLiquidityTier() public {
        router.setPool(500, true);
        router.setRate(500, 4, 1000); // would be the best rate if it were quoted
        router.setPoolLiquidity(500, 0);
        router.setQuoteBurnsGas(500, true); // any quote on it would be catastrophic
        _sendTax(100 ether);
        vm.expectCall(
            address(router),
            abi.encodeCall(
                IMultiDexRouter.quoteExactInputSingle,
                (
                    0,
                    IMultiDexRouter.QuoteExactInputSingleParams({
                        tokenIn: address(rwa), tokenOut: address(wbnb), amountIn: 100 ether, fee: 500, sqrtPriceLimitX96: 0
                    })
                )
            ),
            0
        );
        vm.prank(address(vault));
        vault.process();
        assertEq(router.lastFeeUsed(), 2500, "zero-liquidity tier never quoted, live tier used");
    }

    /// @dev Every quoter call is gas-capped, so a pathological pool cannot eat the callback budget.
    function test_quote_gasCapped_pathologicalTierIsBounded() public {
        router.setPool(500, true); // liquidity > 0, but the quoter burns everything it is given
        router.setQuoteBurnsGas(500, true);
        _sendTax(100 ether);
        vm.prank(address(vault));
        uint256 g0 = gasleft();
        vault.process();
        uint256 used = g0 - gasleft();
        assertEq(router.lastFeeUsed(), 2500, "fell through to the live tier");
        assertLt(used, vault.REFILL_QUOTE_GAS() + 1_000_000, "runaway quote bounded by REFILL_QUOTE_GAS");
    }

    /// @dev Uncapped linear sizing would spend all 10 RWA to reach the 0.05 BNB target (a thin
    ///      pool needing the whole batch to hit gasRefillAmount); MAX_REFILL_SHARE_BPS caps the
    ///      swap at 20% of the batch instead, leaving 8 RWA below minProcessAmount: the refill-only
    ///      batch ends with no follow-up (nothing to buy back yet) and the remainder waits whole
    ///      for the next tax receipt.
    function test_process_refillCappedAtShareOfPending_noFollowUpBelowMin() public {
        _sendTax(MIN_PROCESS); // 10 RWA; uncapped sizing would spend all of it on the refill
        vm.expectEmit(true, true, true, true);
        emit RefillOnlyBatch(8 ether);
        vm.prank(address(vault));
        vault.process();
        assertEq(router.lastAmountIn(), 2 ether, "capped at MAX_REFILL_SHARE_BPS (20%) of the batch");
        assertEq(address(vault).balance, 0.006 ether, "gas pool gets only the capped swap's output");
        assertEq(vault.pendingQuote(), 8 ether, "remainder retained, not reverted");
        assertEq(basePool.depositCallCount(), 0);
        assertFalse(vault.hasPendingTrigger(), "8 RWA < minProcessAmount: no follow-up to schedule");
    }

    /// @dev A thinned/sandwiched pool (100 RWA -> only 0.001 BNB, far short of the 0.05 target)
    ///      cannot make the vault sell more than MAX_REFILL_SHARE_BPS of the batch: the cap bounds
    ///      the swap to 20 RWA regardless of how bad the quote is; the remaining 80 RWA are bought
    ///      back by the follow-up callback.
    function test_process_thinPool_refillBoundedByCap() public {
        triggerService.setFee(0.0001 ether);
        router.setRate(2500, 1, 100000); // 100 RWA -> 0.001 BNB: far below the 0.05 target
        _sendTax(100 ether);
        vm.prank(address(vault));
        vault.process();
        assertEq(router.lastAmountIn(), 20 ether, "capped at 20% of the batch despite the thin pool");
        assertEq(vault.pendingQuote(), 80 ether, "remaining 80 RWA kept for the follow-up");
        _fireFollowUp();
        assertEq(vault.pendingQuote(), 0);
        assertEq(basePool.lastDepositAmount(), 80_000 ether, "remaining 80 RWA bought back");
    }

    /// @dev The refill swap reverting (e.g. an RWA transfer restriction toward the DEX pool) is a
    ///      LATE failure: the quotes were already paid for, so the call ends as a refill-only batch
    ///      (nothing bricked, batch intact by rule 010) and the next process() skips the refill
    ///      check and buys back the full batch.
    function test_process_swapReverts_isRefillOnlyBatch_thenBuysBack() public {
        _sendTax(100 ether);
        router.setSwapReverts(true);
        vm.expectEmit(true, true, true, true);
        emit GasRefillSkipped(100 ether);
        vm.prank(address(vault));
        vault.process();
        assertEq(address(vault).balance, 0, "no gas refilled");
        assertEq(vault.pendingQuote(), 100 ether, "rule 010: the reverted decrement rolled back, batch intact");
        assertEq(basePool.depositCallCount(), 0, "late failure: no buyback in the same call");
        assertTrue(vault.skipRefillOnce());
        assertFalse(vault.hasPendingTrigger(), "gas pool empty: follow-up could not be paid");

        // Next entry (manual or the next tax receipt's wake) buys back without retrying the refill.
        vm.prank(address(vault));
        vault.process();
        assertEq(vault.pendingQuote(), 0);
        assertEq(basePool.lastDepositAmount(), 100_000 ether, "full batch bought back, nothing lost");
        assertEq(router.lastAmountIn(), 0, "refill not retried on the skip call");
    }

    function test_executeGasRefill_onlySelf() public {
        vm.prank(makeAddr("attacker"));
        vm.expectRevert(bytes(unicode"Caller must be the vault itself / 僅限金庫自身調用"));
        vault.executeGasRefill(address(router), address(wbnb), 0, 2500, 1 ether, 0);
    }

    /// @dev WBNB.withdraw pays BNB into receive() while process() holds the guard; that wake must
    ///      not schedule. The only trigger after a refill batch is the one process() itself
    ///      schedules at the very end (the follow-up buyback).
    function test_process_refillDoesNotScheduleTriggerMidProcess() public {
        _sendTax(100 ether);
        vm.prank(address(vault));
        vault.process();
        assertTrue(vault.hasPendingTrigger(), "exactly the follow-up buyback is scheduled");
        assertEq(vault.pendingTriggerId(), 1, "a single request: the follow-up, not a mid-unwrap wake");
    }

    /// @dev Proves minOut is re-quoted at the actual (sized) quoteIn, not reused from the
    ///      full-amount outForAll quote. At maxSlippageBps = 0 there is zero tolerance for a
    ///      mismatch: the swap only survives because _refillGas calls _quoteOut(quoteIn) — which
    ///      the mock's linear rate makes exactly equal to the actual swap output — rather than
    ///      reusing outForAll (quoted at the full `available` amount, a different input size).
    function test_process_refillMinOutRequotedAtQuoteIn() public {
        _sendTax(100 ether);
        MyxVault.InitParams memory p = _initParams();
        p.maxSlippageBps = 0; // zero tolerance: minOut must exactly match the actual swap output
        MyxVault strict = _deployVault(p);
        rwa.mint(address(strict), 100 ether);
        vm.prank(address(strict));
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
        vm.prank(address(vault));
        vault.process();
        assertGt(other.lastAmountIn(), 0, "router resolved dynamically from SwapRegistry");
        assertEq(router.lastAmountIn(), 0);
    }

    /// @dev A revert anywhere in the taxProcessor -> swapRegistry -> router/weth -> Portal
    ///      quote-config chain must degrade to GasRefillSkipped, never brick process() for every
    ///      call while the gas pool is low. taxProcessor() = address(0) makes swapVenue()'s
    ///      ITaxProcessor(address(0)).swapRegistry() call revert (call to a code-less address).
    function test_process_venueUnresolvable_skipsRefill() public {
        taxToken.setTaxProcessor(address(0));
        _sendTax(100 ether);
        vm.expectEmit(true, true, true, true);
        emit GasRefillSkipped(100 ether);
        vm.prank(address(vault));
        vault.process();
        assertEq(address(vault).balance, 0);
        assertEq(basePool.lastDepositAmount(), 100_000 ether);
    }

    receive() external payable {}
}

contract MyxVaultErc20EmergencyAndViewsTest is MyxVaultErc20QuoteTestBase {
    function test_emergencySweepNative_clearsGasPoolOnly() public {
        vault.fundGas{value: 0.5 ether}();
        // _sendTax's ping auto-schedules a trigger (Task 6/7), which debits the fee from this same
        // BNB gas pool — see test_process_noRefillWhenGasAboveThreshold for the same caveat.
        _sendTax(20 ether);
        address rescue = makeAddr("rescue");
        vm.prank(GUARDIAN);
        vault.emergencySweepNative(rescue);
        assertEq(rescue.balance, 0.5 ether - triggerService.getFee());
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

    /// @dev symbol() and decimals() are OPTIONAL in EIP-20; a quote token may omit or revert on
    ///      them. description() is display-only, so it falls back to "?" / 18 decimals instead of
    ///      reverting and taking the whole UI read with it.
    function test_description_quoteMetadataReverts_usesDefaults() public {
        MockERC20NoMetadata odd = new MockERC20NoMetadata("Odd Quote", "ODD");
        portal.setQuoteConfig(address(odd), true, 0);
        MyxVault.InitParams memory p = _initParams();
        p.quoteToken = address(odd);
        MyxVault v = _deployVault(p);
        odd.mint(address(v), 1.5 ether);
        v.sync();
        assertEq(
            v.description(),
            unicode"MYX liquidity vault / MYX 流動性金庫: 0 LP minted / LP 已鑄造, 0 LP distributed / LP 已分發, pending ? / 待處理 ?: 1.5, gas pool / Gas 池: 0 BNB."
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

/// @dev The gas-refill leg ends in WBNB.withdraw(), and the real WETH9/WBNB pays out with
///      transfer() — a 2300 gas stipend for the vault's receive(). This fixture swaps the plain
///      MockERC20 quote for MockProxiedERC20, whose balanceOf costs what a live RWA token's costs,
///      so the stipend budget is measured honestly instead of against a warm mapping read.
contract MyxVaultErc20StipendTest is MyxVaultErc20QuoteTestBase {
    MockProxiedERC20 internal proxiedRwa;

    function setUp() public override {
        super.setUp();
        proxiedRwa = new MockProxiedERC20("NVDA bStock", "NVDAB");
        portal.setQuoteConfig(address(proxiedRwa), true, 0);
        MyxVault.InitParams memory p = _initParams();
        p.quoteToken = address(proxiedRwa);
        vault = _deployVault(p);
    }

    /// @notice The unwrap must not revert because the vault's receive() overran the stipend the
    ///         real WBNB forwards. receive() has to recognise its own unwrap and return early.
    function test_process_refillUnwrapSurvivesWbnbTransferStipend() public {
        proxiedRwa.mint(address(vault), 100 ether);
        vault.sync();
        vault.ensurePoolDeployed(); // latch poolReady as a real launch would before any callback
        assertEq(address(vault).balance, 0, "gas pool starts empty, below the threshold");

        vm.prank(address(vault));

        vault.process();

        assertGe(address(vault).balance, GAS_THRESHOLD, "refill topped the gas pool up");
        assertEq(vault.pendingQuote(), 100 ether - router.lastAmountIn(), "batch kept for the follow-up");
        uint256 id = vault.pendingTriggerId();
        vm.warp(block.timestamp + 61);
        triggerService.fire(id);
        assertEq(vault.pendingQuote(), 0, "remainder bought back by the follow-up");
        assertGt(basePool.lastDepositAmount(), 0, "buyback deposited");
    }
}

/// @dev Batched buyback on an ERC20 quote: the follow-up trigger fee comes from the gas pool.
contract MyxVaultErc20BatchedProcessTest is MyxVaultErc20QuoteTestBase {
    function setUp() public override {
        super.setUp();
        PoolMetadata memory meta;
        meta.marketId = marketId;
        meta.poolId = MyxPoolId.derive(marketId, address(taxToken));
        meta.baseToken = address(taxToken);
        meta.basePoolToken = address(lpToken);
        poolManager.setPool(meta.poolId, meta);
        MyxVault.InitParams memory p = _initParams();
        p.maxProcessAmount = 30 ether; // 30 RWA per batch
        vault = _deployVault(p);
    }

    /// @dev Audit round 1, Finding 9: the refill cap is 20% of the batch actually processed
    ///      (min(pendingQuote, maxProcessAmount)), not 20% of the whole backlog. 100 RWA backlog,
    ///      30 RWA batch: linear sizing wants 16.7 RWA for the 0.05 BNB target, cap = 6 RWA.
    function test_process_refillCappedAtShareOfBatch_notBacklog() public {
        _sendTax(100 ether); // no gas -> no schedule; gas pool empty -> refill runs
        vm.prank(address(vault));
        vault.process();
        assertEq(router.lastAmountIn(), 6 ether, "20% of the 30 RWA batch, not of the 100 RWA backlog");
        assertEq(vault.pendingQuote(), 94 ether, "refill-only batch: nothing bought back yet");
        uint256 id = vault.pendingTriggerId();
        vm.warp(block.timestamp + 61);
        triggerService.fire(id);
        assertEq(vault.pendingQuote(), 100 ether - 6 ether - 30 ether, "follow-up bought back one batch");
        assertEq(basePool.lastDepositAmount(), 30_000 ether);
    }

    function test_process_capsAtMax_followUpPaidFromGasPool() public {
        vault.fundGas{value: GAS_REFILL}();
        _sendTax(100 ether); // schedules #1 from the gas pool
        uint256 fee = triggerService.getFee();
        uint256 id = vault.pendingTriggerId();
        vm.warp(block.timestamp + 61);
        triggerService.fire(id);
        assertEq(vault.pendingQuote(), 70 ether, "one 30 RWA batch consumed, quote baseline untouched by fees");
        assertEq(basePool.lastDepositAmount(), 30_000 ether);
        assertTrue(vault.hasPendingTrigger(), "follow-up scheduled");
        assertEq(vault.gasBalance(), GAS_REFILL - 2 * fee, "two fees paid from the gas pool");
    }

    function test_process_capsAtMax_noGas_keepsRemainderWithoutFollowUp() public {
        // Empty gas pool and no quote/WBNB pool, so the refill leg skips and the follow-up cannot pay
        // its fee: the remainder must simply wait for the next wake or a manual process().
        router.setPool(2500, false);
        _sendTax(100 ether); // cannot schedule: no BNB
        assertFalse(vault.hasPendingTrigger());
        vm.prank(address(vault));
        vault.process();
        assertEq(vault.pendingQuote(), 70 ether, "one batch bought back, remainder retained");
        assertEq(basePool.lastDepositAmount(), 30_000 ether);
        assertEq(address(vault).balance, 0, "refill skipped, nothing to pay a fee with");
        assertFalse(vault.hasPendingTrigger(), "no BNB for the follow-up fee; manual process() picks it up");
    }

    receive() external payable {}
}

contract MyxVaultErc20RequestProcessTest is MyxVaultErc20QuoteTestBase {
    function setUp() public override {
        super.setUp();
        PoolMetadata memory meta;
        meta.marketId = marketId;
        meta.poolId = MyxPoolId.derive(marketId, address(taxToken));
        meta.baseToken = address(taxToken);
        meta.basePoolToken = address(lpToken);
        poolManager.setPool(meta.poolId, meta);
    }

    function test_requestProcess_erc20_fundsFeeWithValue() public {
        _sendTax(20 ether); // no gas -> not auto-scheduled
        assertFalse(vault.hasPendingTrigger());
        uint256 fee = triggerService.getFee();
        vm.deal(address(this), 1 ether);
        vault.requestProcess{value: fee + GAS_REFILL}(); // caller funds the fee (+ pool headroom)
        assertTrue(vault.hasPendingTrigger());
        assertEq(vault.gasBalance(), GAS_REFILL, "fee spent from the just-funded gas pool");
        assertEq(vault.pendingQuote(), 20 ether, "ERC20 revenue untouched");
        uint256 id = vault.pendingTriggerId();
        vm.warp(block.timestamp + 61);
        triggerService.fire(id);
        assertEq(vault.pendingQuote(), 0);
        assertEq(basePool.lastDepositAmount(), 20_000 ether);
    }

    function test_requestProcess_erc20_noGas_reverts() public {
        _sendTax(20 ether);
        vm.expectRevert(bytes(unicode"Gas pool below trigger fee / Gas 池低於觸發手續費"));
        vault.requestProcess();
    }

    receive() external payable {}
}

/// @dev Pool gate on the ERC20 wake path: a funded gas pool is not enough — the myx pool must exist.
contract MyxVaultErc20PoolGateTest is MyxVaultErc20QuoteTestBase {
    function _poolPreDeployed() internal pure override returns (bool) {
        return false;
    }

    function test_ping_poolMissing_withGas_noSchedule() public {
        vault.fundGas{value: 0.01 ether}();
        _sendTax(20 ether);
        assertEq(vault.pendingQuote(), 20 ether, "revenue still recognized");
        assertFalse(vault.poolReady());
        assertFalse(vault.hasPendingTrigger());
        assertEq(vault.gasBalance(), 0.01 ether, "no fee spent");
    }

    function test_ping_poolDeployedLater_schedulesOnNextWake() public {
        vault.fundGas{value: 0.01 ether}();
        _sendTax(20 ether);
        _registerPool();
        assertTrue(_ping());
        assertTrue(vault.poolReady());
        assertTrue(vault.hasPendingTrigger());
    }

    function test_requestProcess_erc20_poolMissing_reverts() public {
        _sendTax(20 ether);
        vm.deal(address(this), 1 ether);
        vm.expectRevert(bytes(unicode"Pool not deployed / 池尚未部署"));
        vault.requestProcess{value: 0.01 ether}();
    }

    function test_ensurePoolDeployed_erc20_schedulesBacklogFromGasPool() public {
        vault.fundGas{value: 0.01 ether}();
        _sendTax(20 ether);
        vault.ensurePoolDeployed();
        assertEq(poolManager.deployPoolCallCount(), 1);
        assertTrue(vault.hasPendingTrigger());
        assertEq(vault.pendingQuote(), 20 ether, "fee paid from the gas pool, not revenue");
        assertEq(vault.gasBalance(), 0.01 ether - triggerService.getFee());
    }

    function test_ping_gasUnder100k_withProbe() public {
        _registerPool();
        vault.fundGas{value: 0.01 ether}();
        rwa.mint(address(vault), 20 ether);
        uint256 g0 = gasleft();
        (bool ok,) = address(vault).call{value: 0, gas: 100_000}("");
        uint256 used = g0 - gasleft();
        assertTrue(ok);
        assertTrue(vault.poolReady(), "probe + latch + schedule ran inside the ping");
        assertLt(used, 100_000);
    }

    receive() external payable {}
}
