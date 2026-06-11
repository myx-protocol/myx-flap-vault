// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.26;

import {Test} from "forge-std/Test.sol";
import {MyxVault} from "../src/MyxVault.sol";
import {MarketId, PoolId, MyxPoolId, IMyxBasePool, PoolMetadata} from "../src/myx/IMyxPool.sol";
import {ERC1967Proxy} from "@openzeppelin/proxy/ERC1967/ERC1967Proxy.sol";
import "./mocks/Mocks.sol";

contract MyxVaultTestBase is Test {
    MyxVault vault;
    MockWBNB wbnb;
    MockERC20 usdt;
    MockERC20 baseToken; // non-WBNB base for swap-path tests
    MockERC20 lpToken;
    MockBasePool basePool;
    MockPoolManager poolManager;
    MockPancakeRouter router;
    MockAggregatorV3 bnbUsdFeed;
    MockAggregatorV3 usdtUsdFeed;
    MockDividendDistributor dividend;
    MockTaxToken taxToken;

    address creator = makeAddr("creator");
    // Guardian address hardcoded in VaultBase for chainId 56; tests etch chainid 56 via vm.chainId.
    address constant GUARDIAN = 0x9e27098dcD8844bcc6287a557E0b4D09C86B8a4b;
    MarketId marketId = MarketId.wrap(bytes32(uint256(1)));

    function setUp() public virtual {
        vm.chainId(56);
        wbnb = new MockWBNB();
        usdt = new MockERC20("Tether", "USDT");
        baseToken = new MockERC20("Base", "BASE");
        lpToken = new MockERC20("MYX LP", "MLP");
        basePool = new MockBasePool(lpToken, usdt);
        poolManager = new MockPoolManager();
        router = new MockPancakeRouter();
        bnbUsdFeed = new MockAggregatorV3(600e8, 8);  // BNB = $600
        usdtUsdFeed = new MockAggregatorV3(1e8, 8);   // USDT = $1
        dividend = new MockDividendDistributor(address(wbnb));
        taxToken = new MockTaxToken(address(dividend));

        vault = _deployVault(_initParams(address(wbnb)));
    }

    function _deployVault(MyxVault.InitParams memory p) internal returns (MyxVault) {
        MyxVault impl = new MyxVault();
        bytes memory initData = abi.encodeCall(MyxVault.initialize, (p));
        ERC1967Proxy proxy = new ERC1967Proxy(address(impl), initData);
        return MyxVault(payable(address(proxy)));
    }

    function _initParams(address base) internal view returns (MyxVault.InitParams memory p) {
        p.taxToken = address(taxToken);
        p.creator = creator;
        p.baseToken = base;
        p.marketId = marketId;
        p.poolManager = address(poolManager);
        p.basePool = address(basePool);
        p.swapRouter = address(router);
        p.wbnb = address(wbnb);
        p.quoteToken = address(usdt);
        p.bnbUsdFeed = address(bnbUsdFeed);
        p.usdtUsdFeed = address(usdtUsdFeed);
        p.maxSlippageBps = 300;          // 3%
        p.minProcessAmount = 0.1 ether;  // BNB
        p.maxPriceStaleness = 3600; // 1 hour
    }
}

contract MyxVaultInitTest is MyxVaultTestBase {
    function test_initialize_storesConfig() public view {
        assertEq(vault.taxToken(), address(taxToken));
        assertEq(vault.baseToken(), address(wbnb));
        assertEq(PoolId.unwrap(vault.poolId()), PoolId.unwrap(MyxPoolId.derive(marketId, address(wbnb))));
    }

    function test_initialize_revertsOnSecondCall() public {
        vm.expectRevert();
        vault.initialize(_initParams(address(wbnb)));
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

    function test_revokeGuardianRole_reverts() public {
        bytes32 role = vault.EMERGENCY_ROLE();
        vm.prank(GUARDIAN); // even the admin itself cannot revoke the guardian
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

contract MyxVaultProcessWbnbTest is MyxVaultTestBase {
    function setUp() public override {
        super.setUp();
        // register the WBNB pool as already existing
        PoolMetadata memory meta;
        meta.marketId = marketId;
        meta.poolId = MyxPoolId.derive(marketId, address(wbnb));
        meta.baseToken = address(wbnb);
        meta.basePoolToken = address(lpToken);
        poolManager.setPool(meta.poolId, meta);
    }

    function _fund(uint256 amount) internal {
        vm.deal(address(this), amount);
        (bool ok,) = address(vault).call{value: amount}("");
        assertTrue(ok);
    }

    function test_processRevenue_wrapsAndDeposits() public {
        _fund(1 ether);
        vault.processRevenue();
        assertEq(vault.pendingBnb(), 0);
        assertEq(basePool.depositCallCount(), 1);
        assertEq(basePool.lastDepositAmount(), 1 ether);
        assertEq(basePool.lastDepositRecipient(), address(vault)); // LP held by vault
        assertEq(lpToken.balanceOf(address(vault)), 1 ether);
        assertEq(vault.totalLpMinted(), 1 ether);
    }

    function test_processRevenue_revertsBelowMinimum() public {
        _fund(0.05 ether); // below 0.1 ether minProcessAmount
        vm.expectRevert(
            abi.encodeWithSelector(MyxVault.BelowMinimumProcessAmount.selector, 0.05 ether, 0.1 ether)
        );
        vault.processRevenue();
    }

    function test_processRevenue_failedDepositLeavesBnbPending() public {
        _fund(1 ether);
        vm.mockCallRevert(
            address(basePool),
            abi.encodeWithSelector(IMyxBasePool.deposit.selector),
            "POOL_PAUSED"
        );
        vm.expectRevert();
        vault.processRevenue();
        // state rolled back: BNB safely retained for retry
        assertEq(vault.pendingBnb(), 1 ether);
        assertEq(address(vault).balance, 1 ether);
    }

    function test_processRevenue_callableByAnyone() public {
        _fund(1 ether);
        vm.prank(makeAddr("randomCaller"));
        vault.processRevenue();
        assertEq(basePool.depositCallCount(), 1);
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
        vault.processRevenue();
        assertEq(poolManager.deployPoolCallCount(), 1);
        assertEq(basePool.depositCallCount(), 1);
    }

    function test_processRevenue_skipsDeployWhenPoolExists() public {
        PoolMetadata memory meta;
        meta.baseToken = address(wbnb);
        meta.basePoolToken = address(lpToken);
        poolManager.setPool(MyxPoolId.derive(marketId, address(wbnb)), meta);
        _fund(1 ether);
        vault.processRevenue();
        assertEq(poolManager.deployPoolCallCount(), 0);
    }

    function test_processRevenue_marketMissing_revertsAndRetainsBnb() public {
        poolManager.setMarketExists(false);
        _fund(1 ether);
        vm.expectRevert("MockPoolManager: market missing");
        vault.processRevenue();
        assertEq(vault.pendingBnb(), 1 ether); // safely retained for retry after governance creates market
    }
}

contract MyxVaultHarvestTest is MyxVaultTestBase {
    function setUp() public override {
        super.setUp();
        // USDT → WBNB at fair rate: 600 USDT = 1 WBNB → num=1, den=600
        router.setRate(1, 600);
    }

    function test_harvest_claimsSwapsAndForwards() public {
        basePool.setRebate(600 ether); // 600 USDT pending
        vault.harvest();
        // 600 USDT → 1 WBNB → forwarded to dividend
        assertEq(dividend.totalDeposited(), 1 ether);
        assertEq(vault.totalRewardsForwarded(), 1 ether);
        assertEq(usdt.balanceOf(address(vault)), 0);
    }

    function test_harvest_noRebate_noop() public {
        vault.harvest();
        assertEq(dividend.totalDeposited(), 0);
    }

    function test_harvest_badSwapRate_revertsAndRetainsUsdt() public {
        basePool.setRebate(600 ether);
        router.setRate(1, 1200); // router pays half of fair → below 3% bound
        vm.expectRevert("MockRouter: INSUFFICIENT_OUTPUT_AMOUNT");
        vault.harvest();
        // claim happened inside the reverted tx, so nothing left the vault overall
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
}

contract MyxVaultProcessSwapTest is MyxVaultTestBase {
    MockAggregatorV3 baseFeed;
    MyxVault swapVault;

    function setUp() public override {
        super.setUp();
        baseFeed = new MockAggregatorV3(60_000e8, 8); // base = $60k (BTC-like)
        MyxVault.InitParams memory p = _initParams(address(baseToken));
        p.baseTokenUsdFeed = address(baseFeed);
        swapVault = _deployVault(p);
        // mock router rate: 1 WBNB ($600) = 0.01 base ($60k) → num=1, den=100
        router.setRate(1, 100);
    }

    function _fund(uint256 amount) internal {
        vm.deal(address(this), amount);
        (bool ok,) = address(swapVault).call{value: amount}("");
        assertTrue(ok);
    }

    function test_processRevenue_swapsToBaseThenDeposits() public {
        _fund(1 ether);
        swapVault.processRevenue();
        // 1 BNB → 0.01 base at fair rate; deposited into pool
        assertEq(basePool.lastDepositAmount(), 0.01 ether);
        assertEq(swapVault.pendingBnb(), 0);
    }

    function test_processRevenue_revertsWhenSwapWorseThanSlippageBound() public {
        // fair = 0.01 base/BNB; bound = 0.0097 (3%); router pays only 0.005 → must revert
        router.setRate(1, 200);
        _fund(1 ether);
        vm.expectRevert("MockRouter: INSUFFICIENT_OUTPUT_AMOUNT");
        swapVault.processRevenue();
        assertEq(swapVault.pendingBnb(), 1 ether); // retained for retry
    }

    function test_processRevenue_revertsOnStaleFeed() public {
        baseFeed.setAnswer(0);
        _fund(1 ether);
        vm.expectRevert(abi.encodeWithSelector(MyxVault.StalePrice.selector, address(baseFeed)));
        swapVault.processRevenue();
    }

    function test_processRevenue_revertsOnStaleBnbFeed() public {
        bnbUsdFeed.setAnswer(0);
        _fund(1 ether);
        vm.expectRevert(abi.encodeWithSelector(MyxVault.StalePrice.selector, address(bnbUsdFeed)));
        swapVault.processRevenue();
    }

    function test_processRevenue_revertsOnOutdatedBaseFeed() public {
        // base feed answer is positive but last update is older than maxPriceStaleness
        baseFeed.setUpdatedAt(1); // far in the past relative to fork/test timestamp
        vm.warp(100000);
        _fund(1 ether);
        vm.expectRevert(abi.encodeWithSelector(MyxVault.StalePrice.selector, address(baseFeed)));
        swapVault.processRevenue();
    }
}
