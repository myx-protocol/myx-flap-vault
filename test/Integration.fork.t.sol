// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.26;

import {IERC20} from "@openzeppelin/token/ERC20/IERC20.sol";

import {FlapBSCFixture} from "./FlapBSCFixture.sol";
import {IVaultPortal, IVaultPortalTypes} from "../src/flap/IVaultPortal.sol";

import {MyxVault} from "../src/MyxVault.sol";
import {MyxVaultFactory} from "../src/MyxVaultFactory.sol";
import {MarketId, PoolId, MyxPoolId, PoolMetadata} from "../src/myx/IMyxPool.sol";

import {MockERC20, MockBasePool, MockPoolManager} from "./mocks/Mocks.sol";

/// @title MyxVaultForkTest
/// @notice BSC mainnet fork end-to-end proof: launches a REAL Flap V3 tax token through the
///         REAL VaultPortal pointed at OUR MyxVaultFactory, trades to generate tax, dispatches
///         the real TaxProcessor under a 1M gas cap, and asserts the vault received BNB via
///         receive() (the live proof of Flap Rule 005 compliance) and minted LP on processRevenue().
///
/// @dev Only the MYX-side infrastructure (PoolManager / BasePool / USDT / LP token) is mocked.
///      WBNB, PancakeRouter and the Chainlink feeds are wired to their REAL BSC addresses so the
///      factory config mirrors a production deployment. With WBNB as the base token the
///      processRevenue() path is wrap-only (no router/feed hop), so the LP-mint assertion is
///      deterministic against the mock pool while the tax-dispatch leg exercises live Flap code.
contract MyxVaultForkTest is FlapBSCFixture {
    // ── Real BSC mainnet addresses (docs/phase0-findings.md) ──────────────────
    address internal constant WBNB = 0xbb4CdB9CBd36B01bD1cBaEBF2De08d9173bc095c;
    address internal constant PANCAKE_ROUTER = 0x10ED43C718714eb63d5aA57B78B54704E256024E;
    address internal constant BNB_USD_FEED = 0x0567F2323251f0Aab15c8dFb1967E4e8A7D42aeE;
    address internal constant USDT_USD_FEED = 0xB97Ad0E74fa7d920791E90258A6E2085088b4320;

    // MYX market identifier for the WBNB pool used in this test.
    MarketId internal marketId = MarketId.wrap(bytes32(uint256(1)));

    // ── Our deployments on the fork ───────────────────────────────────────────
    MyxVaultFactory internal factory;
    MockPoolManager internal poolManager;
    MockBasePool internal basePool;
    MockERC20 internal usdt;
    MockERC20 internal lpToken;

    function setUp() public {
        _forkBSCMainnet();

        // Deploy the mocked MYX infrastructure. The real BasePool pulls base token on deposit;
        // the mock mints LP 1:1 and tracks call counts for assertions.
        usdt = new MockERC20("Tether", "USDT");
        lpToken = new MockERC20("MYX LP", "MLP");
        basePool = new MockBasePool(lpToken, usdt);
        poolManager = new MockPoolManager();

        // Deploy OUR factory: WBNB-only whitelist (feeds[0] == address(0), wrap-only path),
        // MYX side pointed at the mocks, WBNB/router/feeds pointed at REAL BSC addresses.
        address[] memory baseTokens = new address[](1);
        baseTokens[0] = WBNB;
        address[] memory feeds = new address[](1);
        feeds[0] = address(0); // WBNB needs no feed (wrap-only)

        factory = new MyxVaultFactory(
            MyxVaultFactory.GlobalConfig({
                poolManager: address(poolManager),
                basePool: address(basePool),
                swapRouter: PANCAKE_ROUTER,
                wbnb: WBNB,
                quoteToken: address(usdt),
                bnbUsdFeed: BNB_USD_FEED,
                usdtUsdFeed: USDT_USD_FEED,
                maxSlippageBps: 300,
                minProcessAmount: 0.001 ether, // small so a modest trade clears it
                maxPriceStaleness: 86_400 // wide tolerance: fork block may lag live feed updates
            }),
            baseTokens,
            feeds
        );

        // Pre-register the WBNB pool in the mock so _ensurePoolExists() finds basePoolToken set
        // and skips deployPool (the mock would also auto-deploy, but pre-registration is deterministic).
        PoolMetadata memory meta;
        meta.marketId = marketId;
        meta.poolId = MyxPoolId.derive(marketId, WBNB);
        meta.baseToken = WBNB;
        meta.basePoolToken = address(lpToken);
        poolManager.setPool(meta.poolId, meta);

        vm.label(WBNB, "WBNB");
        vm.label(PANCAKE_ROUTER, "PancakeRouter");
        vm.label(address(factory), "MyxVaultFactory");
    }

    function test_endToEnd_launchTradeDispatchProcess() public {
        // 1. Launch a REAL Flap V3 tax token through the REAL VaultPortal, passing OUR factory.
        //    The VaultPortal will call factory.newVault(...) — the factory's _getVaultPortal()
        //    resolves to this same VaultPortal on chainId 56, so the access check passes.
        bytes memory vaultData = abi.encode(WBNB, marketId);
        bytes32 salt = _findVanitySalt(VanityType.VANITY_7777, TOKEN_IMPL_TAXED_V3, PORTAL);

        IVaultPortalTypes.NewTokenV6WithVaultParams memory params =
            _buildV3TaxTokenParams("Myx Vault Token", "MVT", salt, address(factory), vaultData);

        address token = vaultPortal.newTokenV6WithVault{value: params.quoteAmt}(params);
        assertTrue(token != address(0), "launch returned zero token");

        // Resolve the vault the VaultPortal created via our factory.
        IVaultPortalTypes.VaultInfo memory info = vaultPortal.getVault(token);
        MyxVault vault = MyxVault(payable(info.vault));
        assertTrue(address(vault) != address(0), "vault not resolved");
        assertEq(vault.taxToken(), token, "vault taxToken mismatch");
        assertEq(vault.baseToken(), WBNB, "vault baseToken mismatch");

        // 2. Trade to generate tax: buy on the bonding curve, then sell half back.
        vm.deal(address(this), 10 ether);
        _buyOnBC(token, 1 ether);

        uint256 sellAmount = IERC20(token).balanceOf(address(this)) / 2;
        assertGt(sellAmount, 0, "no tokens received from buy");
        vm.startPrank(address(this));
        _sell(token, sellAmount);
        vm.stopPrank();

        // 3. Dispatch tax via the REAL TaxProcessor under the 1M gas cap. This fans BNB out to the
        //    vault's receive() — the live proof of Flap Rule 005 compliance.
        _dispatchTax(token);

        // 4. The vault must have been credited through receive() (accounting only, no revert).
        assertGt(vault.pendingBnb(), 0, "dispatch must credit vault via receive()");

        // 5. processRevenue(): wrap BNB → WBNB and deposit into the mock base pool, minting LP.
        vault.processRevenue();
        assertEq(vault.pendingBnb(), 0, "pendingBnb must zero after processRevenue");
        assertGt(basePool.depositCallCount(), 0, "base pool deposit not invoked");
        assertGt(lpToken.balanceOf(address(vault)), 0, "no LP minted into vault");
    }

    /// @dev Accept BNB so the EOA-style test contract can fund itself / receive trade proceeds.
    receive() external payable {}
}
