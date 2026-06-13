// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.26;

import {Test} from "forge-std/Test.sol";
import {MyxVaultFactory} from "../src/MyxVaultFactory.sol";
import {MyxVault} from "../src/MyxVault.sol";
import {MarketId, PoolId, MyxPoolId, MyxMarketId} from "../src/myx/IMyxPool.sol";
import {IVaultFactoryValidationV2} from "../src/flap/IVaultFactory.sol";
import "./mocks/Mocks.sol";

contract MyxVaultFactoryTest is Test {
    MyxVaultFactory factory;
    MockWBNB wbnb;
    MockERC20 usdt;
    MockAggregatorV3 bnbFeed;
    MockAggregatorV3 usdtFeed;
    MockBasePool basePool;
    MockPoolManager poolManager;
    MockPancakeRouter router;
    MockTriggerService triggerService;

    address constant VAULT_PORTAL = 0x90497450f2a706f1951b5bdda52B4E5d16f34C06; // BSC mainnet
    address constant GUARDIAN = 0x9e27098dcD8844bcc6287a557E0b4D09C86B8a4b;
    // v4-5: the launch param is the market quote token; the vault derives marketId on-chain.
    // Assigned in setUp() once usdt exists; tests run on chainId 56.
    MarketId marketId;

    function setUp() public {
        vm.chainId(56);
        wbnb = new MockWBNB();
        usdt = new MockERC20("Tether", "USDT");
        marketId = MyxMarketId.derive(uint64(56), address(usdt));
        bnbFeed = new MockAggregatorV3(600e8, 8);
        usdtFeed = new MockAggregatorV3(1e8, 8);
        basePool = new MockBasePool(new MockERC20("LP", "LP"), usdt);
        poolManager = new MockPoolManager();
        router = new MockPancakeRouter();
        triggerService = new MockTriggerService();

        factory = new MyxVaultFactory(_baseConfig());
    }

    function _baseConfig() internal view returns (MyxVaultFactory.GlobalConfig memory) {
        return MyxVaultFactory.GlobalConfig({
            poolManager: address(poolManager),
            basePool: address(basePool),
            maxSlippageBps: 300,
            minProcessAmount: 0.1 ether,
            triggerService: address(triggerService),
            triggerInterval: 1 hours
        });
    }

    function _vaultData() internal view returns (bytes memory) {
        // v4-5: vaultData carries the market quote token (= the token's dividendToken); the vault
        // derives marketId = keccak256(chainId, quoteToken) and the pool key from it on-chain.
        return abi.encode(address(usdt));
    }

    function test_newVault_onlyVaultPortal() public {
        vm.expectRevert();
        factory.newVault(makeAddr("tax"), address(0), makeAddr("creator"), _vaultData());
    }

    function test_newVault_deploysInitializedProxy() public {
        vm.prank(VAULT_PORTAL);
        address vaultAddr =
            factory.newVault(makeAddr("tax"), address(0), makeAddr("creator"), _vaultData());
        MyxVault v = MyxVault(payable(vaultAddr));
        assertEq(v.taxToken(), makeAddr("tax"));
        // v4-5: marketId is derived from the quote token (usdt) and chainid; poolId keys off the tax token.
        assertEq(v.marketQuoteToken(), address(usdt));
        assertEq(PoolId.unwrap(v.poolId()), PoolId.unwrap(MyxPoolId.derive(marketId, makeAddr("tax"))));
        assertEq(v.creator(), makeAddr("creator"));
        vm.expectRevert();
        v.initialize(
            MyxVault.InitParams({
                taxToken: address(1), creator: address(1),
                marketQuoteToken: address(usdt), poolManager: address(1), basePool: address(1),
                maxSlippageBps: 0, minProcessAmount: 0,
                triggerService: address(1), triggerInterval: 0
            })
        );
    }

    event VaultCreated(
        address indexed vault, address indexed taxToken, address indexed creator, address marketQuoteToken
    );

    function test_newVault_emitsVaultCreated() public {
        address taxToken = makeAddr("tax");
        address creator = makeAddr("creator");
        vm.prank(VAULT_PORTAL);
        // v4-5: VaultCreated's last param is the market quote token from vaultData (= usdt).
        // vault/taxToken/creator are indexed; assert only the non-indexed marketQuoteToken data.
        vm.expectEmit(false, true, true, false);
        emit VaultCreated(address(0), taxToken, creator, address(usdt));
        address vaultAddr = factory.newVault(taxToken, address(0), creator, _vaultData());
        assertTrue(vaultAddr != address(0));
        assertEq(MyxVault(payable(vaultAddr)).taxToken(), taxToken);
        assertEq(MyxVault(payable(vaultAddr)).marketQuoteToken(), address(usdt));
    }

    function test_newVault_revertsOnZeroQuoteToken() public {
        // A launcher passing abi.encode(address(0)) as vaultData must be rejected by the vault's
        // initializer (ZeroMarketQuoteToken), bubbling up through the factory's BeaconProxy deploy.
        vm.prank(VAULT_PORTAL);
        vm.expectRevert(MyxVault.ZeroMarketQuoteToken.selector);
        factory.newVault(makeAddr("tax"), address(0), makeAddr("creator"), abi.encode(address(0)));
    }

    function test_isQuoteTokenSupported_onlyBnb() public view {
        assertTrue(factory.isQuoteTokenSupported(address(0)));
        assertFalse(factory.isQuoteTokenSupported(address(usdt)));
    }

    function test_validateBeforeLaunch_rejectsErc20Quote() public view {
        IVaultFactoryValidationV2.LaunchValidationDataV1 memory data;
        data.quoteToken = address(usdt);
        (bool ok, string memory reason) = factory.onBeforeLaunch(abi.encode(data));
        assertFalse(ok);
        assertGt(bytes(reason).length, 0);
    }

    function test_validateBeforeLaunch_acceptsBnbQuote() public view {
        IVaultFactoryValidationV2.LaunchValidationDataV1 memory data;
        data.quoteToken = address(0);
        // dividendToken must be a real ERC20 (native BNB / self-dividend are rejected); use USDT.
        data.dividendToken = address(usdt);
        (bool ok,) = factory.onBeforeLaunch(abi.encode(data));
        assertTrue(ok);
    }

    function test_validateBeforeLaunch_rejectsNativeDividend() public view {
        IVaultFactoryValidationV2.LaunchValidationDataV1 memory data;
        data.quoteToken = address(0); // valid BNB quote
        data.dividendToken = address(0); // native BNB dividend — unsupported
        (bool ok, string memory reason) = factory.onBeforeLaunch(abi.encode(data));
        assertFalse(ok);
        assertGt(bytes(reason).length, 0);
    }

    function test_validateBeforeLaunch_rejectsSelfDividend() public view {
        IVaultFactoryValidationV2.LaunchValidationDataV1 memory data;
        data.quoteToken = address(0); // valid BNB quote
        data.dividendToken = 0xfEEDFEEDfeEDFEedFEEdFEEDFeEdfEEdFeEdFEEd; // self-dividend magic
        (bool ok, string memory reason) = factory.onBeforeLaunch(abi.encode(data));
        assertFalse(ok);
        assertGt(bytes(reason).length, 0);
    }

    function test_validateBeforeLaunch_acceptsErc20Dividend() public view {
        IVaultFactoryValidationV2.LaunchValidationDataV1 memory data;
        data.quoteToken = address(0); // valid BNB quote
        data.dividendToken = address(usdt); // real ERC20 dividend
        (bool ok, string memory reason) = factory.onBeforeLaunch(abi.encode(data));
        assertTrue(ok);
        assertEq(bytes(reason).length, 0);
    }

    function test_upgradeOnlyGuardian() public {
        address newImpl = address(new MyxVault());
        vm.expectRevert();
        factory.upgradeVaultImplementation(newImpl);
        vm.prank(GUARDIAN);
        factory.upgradeVaultImplementation(newImpl);
        assertEq(factory.beacon().implementation(), newImpl);
    }

    function test_factorySpecVersion() public view {
        assertEq(factory.factorySpecVersion(), "v2.2");
    }

    function test_lockVaultUpgrades_blocksFurtherUpgrades() public {
        address newImpl = address(new MyxVault());
        vm.prank(GUARDIAN);
        factory.lockVaultUpgrades();
        vm.prank(GUARDIAN);
        vm.expectRevert(MyxVaultFactory.UpgradesLocked.selector);
        factory.upgradeVaultImplementation(newImpl);
    }

}
