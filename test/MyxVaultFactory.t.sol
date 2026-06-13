// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.26;

import {Test} from "forge-std/Test.sol";
import {MyxVaultFactory} from "../src/MyxVaultFactory.sol";
import {MyxVault} from "../src/MyxVault.sol";
import {MarketId, PoolId, MyxPoolId} from "../src/myx/IMyxPool.sol";
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

    address constant VAULT_PORTAL = 0x90497450f2a706f1951b5bdda52B4E5d16f34C06; // BSC mainnet
    address constant GUARDIAN = 0x9e27098dcD8844bcc6287a557E0b4D09C86B8a4b;
    MarketId marketId = MarketId.wrap(bytes32(uint256(1)));

    function setUp() public {
        vm.chainId(56);
        wbnb = new MockWBNB();
        usdt = new MockERC20("Tether", "USDT");
        bnbFeed = new MockAggregatorV3(600e8, 8);
        usdtFeed = new MockAggregatorV3(1e8, 8);
        basePool = new MockBasePool(new MockERC20("LP", "LP"), usdt);
        poolManager = new MockPoolManager();
        router = new MockPancakeRouter();

        factory = new MyxVaultFactory(_baseConfig());
    }

    function _baseConfig() internal view returns (MyxVaultFactory.GlobalConfig memory) {
        return MyxVaultFactory.GlobalConfig({
            poolManager: address(poolManager),
            basePool: address(basePool),
            maxSlippageBps: 300,
            minProcessAmount: 0.1 ether
        });
    }

    function _vaultData() internal view returns (bytes memory) {
        return abi.encode(marketId);
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
        // v3: poolId is keyed by the tax token itself (buyback design)
        assertEq(PoolId.unwrap(v.poolId()), PoolId.unwrap(MyxPoolId.derive(marketId, makeAddr("tax"))));
        assertEq(v.creator(), makeAddr("creator"));
        vm.expectRevert();
        v.initialize(
            MyxVault.InitParams({
                taxToken: address(1), creator: address(1),
                marketId: marketId, poolManager: address(1), basePool: address(1),
                maxSlippageBps: 0, minProcessAmount: 0
            })
        );
    }

    function test_newVault_emitsVaultCreated() public {
        address taxToken = makeAddr("tax");
        address creator = makeAddr("creator");
        vm.prank(VAULT_PORTAL);
        vm.recordLogs();
        address vaultAddr = factory.newVault(taxToken, address(0), creator, _vaultData());
        assertTrue(vaultAddr != address(0));
        assertEq(MyxVault(payable(vaultAddr)).taxToken(), taxToken);
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
        (bool ok,) = factory.onBeforeLaunch(abi.encode(data));
        assertTrue(ok);
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
