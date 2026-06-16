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
    MockERC20 usdt;
    MockERC20 lpToken;
    MockBasePool basePool;
    MockPoolManager poolManager;
    MockPortal portal;
    MockDividendDistributor dividend;
    MockTaxToken taxToken;

    address creator = makeAddr("creator");
    // Guardian address hardcoded in VaultBase for chainId 56; tests etch chainid 56 via vm.chainId.
    address constant GUARDIAN = 0x9e27098dcD8844bcc6287a557E0b4D09C86B8a4b;
    // Portal address hardcoded in VaultBase for chainId 56; MockPortal code is etched there.
    address constant PORTAL = 0xe2cE6ab80874Fa9Fa2aAE65D277Dd6B8e65C9De0;
    // The vault derives marketId on-chain from (block.chainid, marketQuoteToken). Tests run on
    // chainId 56 with usdt as the launch quote token; assigned in setUp() after usdt is constructed.
    MarketId marketId;

    function setUp() public virtual {
        vm.chainId(56);
        usdt = new MockERC20("Tether", "USDT");
        marketId = MyxMarketId.derive(uint64(56), address(usdt));
        lpToken = new MockERC20("MYX LP", "MLP");
        basePool = new MockBasePool(lpToken, usdt);
        poolManager = new MockPoolManager();
        // v6: the DIVIDEND ASSET is the myx base-pool LP (mBase), set at launch via
        // resolveDividendToken. Construct the dividend with dividendToken() == the LP token so the
        // vault's _feedDividend pulls exactly the LP the mock pool mints (dividendToken == LP invariant).
        dividend = new MockDividendDistributor(address(lpToken));
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
        p.marketQuoteToken = address(usdt);
        p.poolManager = address(poolManager);
        p.basePool = address(basePool);
        p.maxSlippageBps = 300; // 3%
        p.minProcessAmount = 0.1 ether; // BNB
    }

    function _fund(uint256 amount) internal {
        vm.deal(address(this), amount);
        (bool ok,) = address(vault).call{value: amount}("");
        assertTrue(ok);
    }
}

contract MyxVaultInitTest is MyxVaultTestBase {
    function test_initialize_storesConfig() public view {
        assertEq(vault.taxToken(), address(taxToken));
        assertEq(vault.marketQuoteToken(), address(usdt));
        MarketId expectedMarketId = MyxMarketId.derive(uint64(56), address(usdt));
        assertEq(MarketId.unwrap(vault.marketId()), MarketId.unwrap(expectedMarketId));
        assertEq(
            PoolId.unwrap(vault.poolId()), PoolId.unwrap(MyxPoolId.derive(expectedMarketId, address(taxToken)))
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
            PoolId.unwrap(vault.poolId()), PoolId.unwrap(MyxPoolId.derive(expectedMarketId, address(taxToken)))
        );
    }

    function test_initialize_revertsOnSecondCall() public {
        vm.expectRevert();
        vault.initialize(_initParams());
    }

    function test_initialize_storesTrimmedConfig() public view {
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

    function test_revokeGuardianRole_reverts() public {
        bytes32 role = vault.EMERGENCY_ROLE();
        vm.prank(GUARDIAN); // even the admin itself cannot revoke the guardian
        vm.expectRevert(MyxVault.CannotRevokeGuardianRole.selector);
        vault.revokeRole(role, GUARDIAN);
    }

    function test_revokeGuardianAdminRole_reverts() public {
        bytes32 role = vault.DEFAULT_ADMIN_ROLE();
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

/// @dev v6 core flow: process() is PERMISSIONLESS. It buys back the tax token with pending BNB via
///      the Portal, deposits it as myx base-pool liquidity (LP minted to the vault), then feeds the
///      WHOLE LP balance into the token's native Dividend contract (dividendToken == the LP).
contract MyxVaultProcessTest is MyxVaultTestBase {
    event RevenueProcessed(uint256 bnbAmount, uint256 baseAmount, uint256 lpMinted);
    event DividendFed(uint256 lpFed);

    function setUp() public override {
        super.setUp();
        // register the tax-token pool as already existing
        PoolMetadata memory meta;
        meta.marketId = marketId;
        meta.poolId = MyxPoolId.derive(marketId, address(taxToken));
        meta.baseToken = address(taxToken);
        meta.quoteToken = address(usdt);
        meta.basePoolToken = address(lpToken);
        poolManager.setPool(meta.poolId, meta);
        // 1 BNB buys 1000 tax tokens on the mock Portal
        portal.setRate(1000, 1);
    }

    function test_process_buysAddsLiquidityFeedsDividend() public {
        _fund(1 ether);
        // a random caller can run it — permissionless
        vm.prank(makeAddr("keeper"));
        vault.process();
        assertEq(vault.pendingBnb(), 0);
        assertEq(basePool.depositCallCount(), 1);
        assertEq(basePool.lastDepositAmount(), 1000 ether);
        assertEq(basePool.lastDepositRecipient(), address(vault)); // LP minted to the vault first
        assertEq(vault.totalLpMinted(), 1000 ether);
        // v6: the minted LP is then fed into the dividend, so the vault retains none.
        assertEq(lpToken.balanceOf(address(vault)), 0, "LP fed to the dividend");
        assertEq(dividend.totalDeposited(), 1000 ether);
        assertEq(vault.totalRewardsForwarded(), 1000 ether);
    }

    function test_process_anyoneCanCall() public {
        _fund(1 ether);
        vm.prank(makeAddr("stranger"));
        vault.process(); // no role gate — must not revert
        assertEq(basePool.depositCallCount(), 1);
    }

    function test_process_emitsRevenueProcessedAndDividendFed() public {
        _fund(1 ether);
        vm.expectEmit(true, true, true, true, address(vault));
        emit RevenueProcessed(1 ether, 1000 ether, 1000 ether);
        vm.expectEmit(true, true, true, true, address(vault));
        emit DividendFed(1000 ether);
        vault.process();
    }

    function test_process_belowMinimum_reverts() public {
        _fund(0.05 ether); // below 0.1 ether minProcessAmount
        vm.expectRevert(
            abi.encodeWithSelector(MyxVault.BelowMinimumProcessAmount.selector, 0.05 ether, 0.1 ether)
        );
        vault.process();
    }

    function test_process_belowMinimumAfterSuccess_reverts() public {
        _fund(1 ether);
        vault.process(); // succeeds, pendingBnb -> 0
        uint256 minAmt = vault.minProcessAmount();
        vm.expectRevert(abi.encodeWithSelector(MyxVault.BelowMinimumProcessAmount.selector, 0, minAmt));
        vault.process();
    }

    function test_process_dexPhaseTax_accountsBalanceDelta() public {
        portal.setTaxBps(400); // 4% DEX-phase transfer tax: gross 1000, net 960
        _fund(1 ether);
        vault.process();
        // deposit must use the balance delta (net), never the Portal's gross output
        assertEq(basePool.lastDepositAmount(), 960 ether);
        assertEq(dividend.totalDeposited(), 960 ether);
        assertEq(lpToken.balanceOf(address(vault)), 0);
    }

    function test_process_zeroQuote_reverts() public {
        portal.setRate(0, 1); // Portal quotes zero output
        _fund(1 ether);
        vm.expectRevert(MyxVault.ZeroQuote.selector);
        vault.process();
        assertEq(vault.pendingBnb(), 1 ether); // retained for retry
    }

    function test_process_swapReverts_retainsBnb() public {
        _fund(1 ether);
        vm.mockCallRevert(PORTAL, abi.encodeWithSelector(IPortalTradeV2.swapExactInput.selector), "PORTAL_FAIL");
        vm.expectRevert("PORTAL_FAIL");
        vault.process();
        // state rolled back: BNB safely retained for retry
        assertEq(vault.pendingBnb(), 1 ether);
        assertEq(address(vault).balance, 1 ether);
    }

    function test_process_failedDepositLeavesBnbPending() public {
        _fund(1 ether);
        vm.mockCallRevert(address(basePool), abi.encodeWithSelector(IMyxBasePool.deposit.selector), "POOL_PAUSED");
        vm.expectRevert();
        vault.process();
        // state rolled back: BNB safely retained for retry
        assertEq(vault.pendingBnb(), 1 ether);
        assertEq(address(vault).balance, 1 ether);
    }
}

contract MyxVaultDeployPoolTest is MyxVaultTestBase {
    function setUp() public override {
        super.setUp();
        // when process auto-deploys the pool, the deployed basePoolToken must be the real LP
        // so _feedDividend can feed it (dividend asset == LP). Wire deployPool to stamp the lpToken.
        poolManager.setLpTokenForDeploy(address(lpToken));
        portal.setRate(1000, 1);
    }

    function test_process_deploysPoolWhenMissing() public {
        // no setPool() — pool does not exist yet
        _fund(1 ether);
        vault.process();
        assertEq(poolManager.deployPoolCallCount(), 1);
        assertEq(basePool.depositCallCount(), 1);
        assertEq(dividend.totalDeposited(), 1000 ether);
    }

    function test_process_skipsDeployWhenPoolExists() public {
        PoolMetadata memory meta;
        meta.baseToken = address(taxToken);
        meta.basePoolToken = address(lpToken);
        poolManager.setPool(MyxPoolId.derive(marketId, address(taxToken)), meta);
        _fund(1 ether);
        vault.process();
        assertEq(poolManager.deployPoolCallCount(), 0);
    }

    function test_process_marketMissing_revertsAndRetainsBnb() public {
        poolManager.setMarketExists(false);
        _fund(1 ether);
        vm.expectRevert("MockPoolManager: market missing");
        vault.process();
        assertEq(vault.pendingBnb(), 1 ether); // safely retained for retry after governance creates market
    }

    function test_ensurePoolDeployed_permissionless() public {
        vm.prank(makeAddr("stranger"));
        vault.ensurePoolDeployed();
        assertEq(poolManager.deployPoolCallCount(), 1);
    }

    function test_ensurePoolDeployed_skipsWhenExists() public {
        PoolMetadata memory meta;
        meta.baseToken = address(taxToken);
        meta.basePoolToken = address(lpToken);
        poolManager.setPool(MyxPoolId.derive(marketId, address(taxToken)), meta);
        vault.ensurePoolDeployed();
        assertEq(poolManager.deployPoolCallCount(), 0);
    }
}

/// @dev v6: the DIVIDEND ASSET is the myx base-pool LP (mBase) itself. process() buys back the
///      token, deposits it into myx (LP minted to the vault), then feeds the WHOLE LP balance into
///      the token's native Flap Dividend contract (whose dividendToken == the LP). Deferral-safe.
contract MyxVaultFeedDividendTest is MyxVaultTestBase {
    event DividendDeferred(uint256 lpAmount);
    event DividendFed(uint256 lpFed);

    function setUp() public override {
        super.setUp();
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

    function test_process_feedsLpToDividend() public {
        _fund(1 ether);
        vault.process();
        assertEq(vault.totalLpMinted(), 1000 ether);
        assertEq(dividend.totalDeposited(), 1000 ether, "dividend must receive the minted LP");
        assertEq(lpToken.balanceOf(address(vault)), 0, "vault LP flushed to the dividend");
        assertEq(vault.totalRewardsForwarded(), 1000 ether);
    }

    function test_feedDividend_defersOnZeroShares() public {
        _fund(1 ether);
        dividend.setDepositSucceeds(false); // simulate totalShares == 0: deposit() returns false
        vm.expectEmit(true, true, true, true, address(vault));
        emit DividendDeferred(1000 ether);
        vault.process();
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

    function test_feedDividend_defersWhenDepositReverts() public {
        _fund(1 ether);
        dividend.setDepositReverts(true); // external Dividend.deposit THROWS, not just returns false
        vm.expectEmit(true, true, true, true, address(vault));
        emit DividendDeferred(1000 ether);
        vault.process(); // must NOT revert: the buyback + LP mint must persist, feed degrades to deferral
        assertEq(dividend.totalDeposited(), 0);
        assertEq(lpToken.balanceOf(address(vault)), 1000 ether, "LP deferred in vault on deposit revert");
        assertEq(vault.totalRewardsForwarded(), 0);
        assertEq(vault.totalLpMinted(), 1000 ether, "buyback + LP mint must persist despite feed revert");

        // recovery: once deposit stops reverting, a permissionless retry flushes the deferred LP
        dividend.setDepositReverts(false);
        vm.prank(makeAddr("stranger"));
        vault.feedDividend();
        assertEq(dividend.totalDeposited(), 1000 ether);
        assertEq(lpToken.balanceOf(address(vault)), 0, "deferred LP flushed on retry");
        assertEq(vault.totalRewardsForwarded(), 1000 ether);
    }

    function test_feedDividend_defersOnNoDividendContract() public {
        _fund(1 ether);
        taxToken.setDividendContract(address(0)); // dividend not wired yet
        vm.expectEmit(true, true, true, true, address(vault));
        emit DividendDeferred(1000 ether);
        vault.process();
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
        _fund(1 ether);
        vault.process();
        assertEq(lpToken.balanceOf(address(vault)), 0);
        vm.prank(makeAddr("stranger"));
        vault.feedDividend(); // must not revert
    }

    function test_feedDividend_flushesDeferredPlusNew() public {
        // First cycle defers (shares zero); a later process() with shares available must feed
        // the WHOLE balance: the deferred LP plus the freshly minted LP.
        _fund(1 ether);
        dividend.setDepositSucceeds(false);
        vault.process(); // 1000 LP deferred
        assertEq(lpToken.balanceOf(address(vault)), 1000 ether);

        dividend.setDepositSucceeds(true);
        _fund(1 ether);
        vault.process(); // mints +1000 LP, feeds the whole 2000
        assertEq(dividend.totalDeposited(), 2000 ether, "whole balance (deferred + new) fed");
        assertEq(lpToken.balanceOf(address(vault)), 0);
        assertEq(vault.totalRewardsForwarded(), 2000 ether);
    }
}

/// @dev v6 claim proxy: holders claim their mBase LP either directly on the
///      dividend contract or via the vault's claimReward() convenience, which proxies to
///      withdrawDividendsFor(msg.sender). pendingReward proxies withdrawableDividends.
contract MyxVaultClaimTest is MyxVaultTestBase {
    function setUp() public override {
        super.setUp();
        dividend.setDividendToken(address(lpToken)); // v6: dividend asset IS the LP
    }

    function test_claimReward_proxies() public {
        address alice = makeAddr("alice");
        // dividend holds LP and owes alice 7 LP; claimReward pays it out via withdrawDividendsFor.
        lpToken.mint(address(dividend), 7 ether);
        dividend.setPending(alice, 7 ether);
        vm.prank(alice);
        vault.claimReward();
        assertEq(lpToken.balanceOf(alice), 7 ether, "alice received her LP via the proxy");
        assertEq(dividend.withdrawableDividends(alice), 0, "pending cleared");
    }

    function test_claimReward_revertsWhenNoDividendContract() public {
        taxToken.setDividendContract(address(0));
        vm.prank(makeAddr("alice"));
        vm.expectRevert(MyxVault.ZeroDividendContract.selector);
        vault.claimReward();
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

    function test_emergencySweepBnb_strangerReverts() public {
        vm.deal(address(vault), 1 ether);
        vm.prank(makeAddr("stranger"));
        vm.expectRevert();
        vault.emergencySweepBnb(makeAddr("stranger"));
    }

    /// @dev v6 deferred-LP escape: LP retained in the vault (dividend permanently unwired / shares
    ///      stuck at zero) must be rescuable even if the myx pool's withdraw path is unusable.
    ///      emergencyRescueToken drains the full LP balance generically, no basePool.withdraw needed.
    function test_emergencyRescueToken_rescuesDeferredLp() public {
        lpToken.mint(address(vault), 42 ether); // simulate deferred LP stuck in the vault
        address rescue = makeAddr("rescue");
        vm.prank(GUARDIAN);
        vault.emergencyRescueToken(address(lpToken), rescue);
        assertEq(lpToken.balanceOf(rescue), 42 ether, "deferred LP rescued in full");
        assertEq(lpToken.balanceOf(address(vault)), 0, "vault drained");
    }

    function test_emergencyRescueToken_rescuesResidualTaxToken() public {
        // residual tax token left by a failed buyback leg must also be recoverable
        MockTaxToken stuck = MockTaxToken(address(taxToken));
        stuck.mint(address(vault), 5 ether);
        address rescue = makeAddr("rescue");
        vm.prank(creator); // creator also holds EMERGENCY_ROLE
        vault.emergencyRescueToken(address(stuck), rescue);
        assertEq(stuck.balanceOf(rescue), 5 ether);
    }

    function test_emergencyRescueToken_strangerReverts() public {
        lpToken.mint(address(vault), 1 ether);
        vm.prank(makeAddr("stranger"));
        vm.expectRevert(); // AccessControl revert
        vault.emergencyRescueToken(address(lpToken), makeAddr("stranger"));
    }

    function test_emergencyRescueToken_zeroAddressReverts() public {
        vm.prank(GUARDIAN);
        vm.expectRevert("Zero address");
        vault.emergencyRescueToken(address(lpToken), address(0));
        vm.prank(GUARDIAN);
        vm.expectRevert("Zero address");
        vault.emergencyRescueToken(address(0), makeAddr("rescue"));
    }
}

contract MyxVaultViewsTest is MyxVaultTestBase {
    function setUp() public override {
        super.setUp();
        dividend.setDividendToken(address(lpToken));
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

    function test_vaultUISchema_exposesProcessClaimAndFeed() public view {
        VaultMethodSchema[] memory methods = vault.vaultUISchema().methods;
        bool hasProcess;
        bool hasClaim;
        bool hasFeed;
        bool hasPending;
        for (uint256 i = 0; i < methods.length; i++) {
            bytes32 n = keccak256(bytes(methods[i].name));
            if (n == keccak256("process")) hasProcess = true;
            if (n == keccak256("claimReward")) hasClaim = true;
            if (n == keccak256("feedDividend")) hasFeed = true;
            if (n == keccak256("pendingReward")) hasPending = true;
        }
        assertTrue(hasProcess, "schema must expose process");
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
