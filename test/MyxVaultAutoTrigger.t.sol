// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.26;

import {Test} from "forge-std/Test.sol";
import {MyxVault} from "../src/MyxVault.sol";
import {MarketId, PoolId, MyxPoolId, MyxMarketId, PoolMetadata} from "../src/myx/IMyxPool.sol";
import {ERC1967Proxy} from "@openzeppelin/proxy/ERC1967/ERC1967Proxy.sol";
import "./mocks/Mocks.sol";

/// @dev Auto-trigger: receive() schedules a delayed process() through FlapTriggerService.
///      The callback's process() exercises the first-call deployPool path (worst-case gas).
contract MyxVaultAutoTriggerTest is Test {
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

        // No pool pre-registration: the callback's process() auto-deploys the pool (worst-case gas).
        // The mock stamps lpToken as basePoolToken so _feedDividend finds a live ERC20.
        poolManager.setLpTokenForDeploy(address(lpToken));
        dividend.setDividendToken(address(lpToken));

        // Etch the trigger-service mock at the hardcoded address; vm.etch zeroes storage.
        MockFlapTriggerService tsImpl = new MockFlapTriggerService();
        vm.etch(TRIGGER_SERVICE, address(tsImpl).code);
        triggerService = MockFlapTriggerService(TRIGGER_SERVICE);
        triggerService.setFee(0.001 ether);

        vault = _deployVault();
    }

    function _deployVault() internal returns (MyxVault) {
        MyxVault impl = new MyxVault();
        MyxVault.InitParams memory p;
        p.taxToken = address(taxToken);
        p.creator = creator;
        p.marketQuoteToken = address(usdt);
        p.poolManager = address(poolManager);
        p.basePool = address(basePool);
        p.maxSlippageBps = 300;
        p.minProcessAmount = 0.1 ether;
        bytes memory initData = abi.encodeCall(MyxVault.initialize, (p));
        return MyxVault(payable(address(new ERC1967Proxy(address(impl), initData))));
    }

    function _fund(uint256 amount) internal {
        vm.deal(address(this), amount);
        (bool ok,) = address(vault).call{value: amount}("");
        assertTrue(ok);
    }

    // ── scheduling in receive() ──────────────────────────────────────────────

    function test_receive_schedulesWhenAboveThreshold() public {
        uint256 fee = triggerService.getFee();
        _fund(1 ether);
        assertTrue(vault.hasPendingTrigger(), "trigger scheduled");
        assertEq(vault.pendingTriggerId(), 1);
        assertEq(vault.pendingBnb(), 1 ether - fee, "fee deducted from pending");
        assertEq(triggerService.requesterOf(1), address(vault));
        assertEq(triggerService.lastExecuteAfter(), uint64(block.timestamp + 60));
    }

    function test_receive_idempotentWhilePending() public {
        _fund(1 ether);
        _fund(1 ether); // second receipt while a trigger is in-flight
        assertEq(triggerService.lastRequestId(), 1, "must not schedule a second trigger");
        assertEq(vault.pendingTriggerId(), 1);
        assertEq(vault.pendingBnb(), 2 ether - triggerService.getFee(), "both receipts accrued, fee once");
    }

    function test_receive_belowThreshold_noSchedule() public {
        _fund(0.05 ether); // < minProcessAmount 0.1
        assertFalse(vault.hasPendingTrigger());
        assertEq(vault.pendingBnb(), 0.05 ether, "full tax retained, no fee");
    }

    function test_receive_belowMinPlusFee_noScheduleNoLoss() public {
        triggerService.setFee(0.2 ether); // minProcessAmount + fee = 0.3
        _fund(0.15 ether); // >= min 0.1 but < min + fee 0.3 -> can't schedule and still keep min
        assertFalse(vault.hasPendingTrigger());
        assertEq(vault.pendingBnb(), 0.15 ether, "no fee charged, no tax lost");
    }

    function test_receive_serviceReverts_doesNotRevertReceive() public {
        triggerService.setRequestReverts(true);
        _fund(1 ether); // must not revert
        assertFalse(vault.hasPendingTrigger());
        assertEq(vault.pendingBnb(), 1 ether, "full tax retained when scheduling fails");
    }

    /// @dev The schedule decision compares ACCUMULATED pendingBnb against (min + fee), NOT the
    ///      per-receipt msg.value. A small receipt must still schedule once the accrued balance
    ///      crosses the threshold.
    function test_receive_comparesAccumulatedPendingNotReceipt() public {
        triggerService.setFee(0.05 ether);
        // First receipt can't schedule (service down) — pendingBnb accumulates.
        triggerService.setRequestReverts(true);
        _fund(0.14 ether);
        assertFalse(vault.hasPendingTrigger());
        assertEq(vault.pendingBnb(), 0.14 ether);

        // Service recovers. A small receipt (0.02 <= fee 0.05) must STILL schedule because the
        // accumulated pendingBnb (0.16) >= minProcessAmount + fee (0.15).
        triggerService.setRequestReverts(false);
        _fund(0.02 ether);
        assertTrue(vault.hasPendingTrigger(), "schedule decided on accumulated pendingBnb");
        assertEq(vault.pendingBnb(), 0.16 ether - 0.05 ether, "fee deducted from accumulated pending");
    }

    /// @dev Audit v2 F1 is a false positive: `requestTrigger{value: fee}` sends the fee OUT of the
    ///      vault, so the actual BNB balance drops by exactly the same `fee` debited from pendingBnb.
    ///      The (balance == pendingBnb) invariant holds, and process() forwards amount == pendingBnb
    ///      == balance — it can never run out of BNB / be bricked.
    function test_invariant_vaultBalanceEqualsPendingBnb() public {
        _fund(1 ether);
        assertTrue(vault.hasPendingTrigger());
        assertEq(address(vault).balance, vault.pendingBnb(), "balance must equal pendingBnb after schedule");

        vm.warp(block.timestamp + 61);
        vm.prank(makeAddr("keeper"));
        vault.process(); // forwards amount == pendingBnb == balance; cannot revert on insufficient BNB
        assertEq(vault.pendingBnb(), 0);
        assertEq(address(vault).balance, 0, "balance and pendingBnb both drained after process");
    }

    // ── trigger() callback ───────────────────────────────────────────────────

    function test_trigger_executesProcessAndClears() public {
        _fund(1 ether);
        uint256 id = vault.pendingTriggerId();
        vm.warp(block.timestamp + 61);
        triggerService.fire(id);
        assertEq(vault.pendingBnb(), 0, "process consumed pendingBnb");
        assertFalse(vault.hasPendingTrigger(), "in-flight flag cleared");
        assertEq(vault.pendingTriggerId(), 0);
        assertGt(vault.totalLpMinted(), 0, "process minted LP");
    }

    function test_trigger_processReverts_stillClears() public {
        _fund(1 ether);
        uint256 id = vault.pendingTriggerId();
        vault.process(); // drain pendingBnb via permissionless process first
        assertEq(vault.pendingBnb(), 0);
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
        assertLt(used, maxGas, "callback incl. first deployPool must fit maxCallbackGas");
    }

    receive() external payable {}
}
