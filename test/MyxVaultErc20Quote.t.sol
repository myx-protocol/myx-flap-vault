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
        // Fund with headroom for the trigger fee _sendTax's ping auto-schedules from this same BNB
        // pool (Task 6): otherwise the fee debit alone would drop the balance below GAS_THRESHOLD
        // before process() ever runs, which is a different scenario than the one under test.
        vault.fundGas{value: GAS_THRESHOLD + triggerService.getFee()}();
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

    /// @dev Uncapped linear sizing would spend all 10 RWA to reach the 0.05 BNB target (a thin
    ///      pool needing the whole batch to hit gasRefillAmount); MAX_REFILL_SHARE_BPS caps the
    ///      swap at 20% of pendingQuote instead, leaving 8 RWA below minProcessAmount so the
    ///      buyback is skipped (not reverted) and retried whole on the next process().
    function test_process_refillCappedAtShareOfPending_buybackSkipped() public {
        _sendTax(MIN_PROCESS); // 10 RWA; uncapped sizing would spend all of it on the refill
        vm.expectEmit(true, true, true, true);
        emit BuybackSkipped(8 ether);
        vault.process();
        assertEq(router.lastAmountIn(), 2 ether, "capped at MAX_REFILL_SHARE_BPS (20%) of pendingQuote");
        assertEq(address(vault).balance, 0.006 ether, "gas pool gets only the capped swap's output");
        assertEq(vault.pendingQuote(), 8 ether, "remainder retained, not reverted");
        assertEq(basePool.depositCallCount(), 0, "buyback skipped, no revert");
    }

    /// @dev A thinned/sandwiched pool (100 RWA -> only 0.001 BNB, far short of the 0.05 target)
    ///      cannot make the vault sell more than MAX_REFILL_SHARE_BPS of pendingQuote: the cap
    ///      bounds the swap to 20 RWA regardless of how bad the quote is, and the buyback still
    ///      runs on the remaining 80 RWA in the same call.
    function test_process_thinPool_refillBoundedByCap() public {
        router.setRate(2500, 1, 100000); // 100 RWA -> 0.001 BNB: far below the 0.05 target
        _sendTax(100 ether);
        vault.process();
        assertEq(router.lastAmountIn(), 20 ether, "capped at 20% of pendingQuote despite the thin pool");
        assertEq(vault.pendingQuote(), 0);
        assertEq(basePool.lastDepositAmount(), 80_000 ether, "remaining 80 RWA bought back");
    }

    function test_process_refillDoesNotScheduleTriggerMidProcess() public {
        _sendTax(100 ether);
        vault.process(); // WBNB.withdraw pays BNB into receive() while process() holds the guard
        assertFalse(vault.hasPendingTrigger(), "no trigger scheduled from inside process()");
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

    /// @dev A revert anywhere in the taxProcessor -> swapRegistry -> router/weth -> Portal
    ///      quote-config chain must degrade to GasRefillSkipped, never brick process() for every
    ///      call while the gas pool is low. taxProcessor() = address(0) makes swapVenue()'s
    ///      ITaxProcessor(address(0)).swapRegistry() call revert (call to a code-less address).
    function test_process_venueUnresolvable_skipsRefill() public {
        taxToken.setTaxProcessor(address(0));
        _sendTax(100 ether);
        vm.expectEmit(true, true, true, true);
        emit GasRefillSkipped(100 ether);
        vault.process();
        assertEq(address(vault).balance, 0);
        assertEq(basePool.lastDepositAmount(), 100_000 ether);
    }

    receive() external payable {}
}
