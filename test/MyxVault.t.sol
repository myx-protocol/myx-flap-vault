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
        dividend = new MockDividendDistributor(address(wbnb));
        taxToken = new MockTaxToken(address(dividend));

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
        // v3: the pool is keyed by the tax token itself (buyback design)
        assertEq(PoolId.unwrap(vault.poolId()), PoolId.unwrap(MyxPoolId.derive(marketId, address(taxToken))));
    }

    function test_initialize_revertsOnSecondCall() public {
        vm.expectRevert();
        vault.initialize(_initParams());
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

    function test_defaultMode_isAuto() public view {
        assertTrue(vault.mode() == MyxVault.Mode.AUTO);
    }

    function test_auto_anyoneCanProcess() public {
        // default AUTO mode: processRevenue is permissionless
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
        vm.expectRevert(MyxVault.NotAuthorizedInManualMode.selector);
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
        vm.expectRevert(MyxVault.NotAuthorizedInManualMode.selector);
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
        vault.processRevenue(); // default AUTO, succeeds, pendingBnb -> 0

        // second call with pendingBnb == 0 must revert below-minimum
        uint256 minAmt = vault.minProcessAmount();
        vm.expectRevert(abi.encodeWithSelector(MyxVault.BelowMinimumProcessAmount.selector, 0, minAmt));
        vault.processRevenue();
    }
}

contract MyxVaultModeTest is MyxVaultTestBase {
    event ModeChanged(MyxVault.Mode newMode);

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
        assertEq(vault.totalRewardsForwarded(), dividend.totalDeposited());
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

    function test_harvest_dustRebate_retainedNotForwarded() public {
        // 500 wei USDT @ $1, BNB @ $600 → fairOut = 500*1e8/600e8 = 0 → skip, retain
        basePool.setRebate(500);
        vault.harvest();
        assertEq(dividend.totalDeposited(), 0);
        assertEq(usdt.balanceOf(address(vault)), 500); // dust stays for next harvest
    }

    function test_harvest_zeroDividendContract_reverts() public {
        basePool.setRebate(600 ether);
        taxToken.setDividendContract(address(0));
        vm.expectRevert(MyxVault.ZeroDividendContract.selector);
        vault.harvest();
    }

    function test_harvest_revertsOnStaleBnbFeed() public {
        basePool.setRebate(600 ether);
        bnbUsdFeed.setAnswer(0);
        vm.expectRevert(abi.encodeWithSelector(MyxVault.StalePrice.selector, address(bnbUsdFeed)));
        vault.harvest();
    }

    function test_harvest_revertsOnOutdatedUsdtFeed() public {
        // feed answer is positive but last update is older than maxPriceStaleness
        basePool.setRebate(600 ether);
        usdtUsdFeed.setUpdatedAt(1);
        vm.warp(100000);
        vm.expectRevert(abi.encodeWithSelector(MyxVault.StalePrice.selector, address(usdtUsdFeed)));
        vault.harvest();
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
