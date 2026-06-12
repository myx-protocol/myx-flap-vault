// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.26;

import {Test} from "forge-std/Test.sol";
import {MyxVaultFactory} from "../src/MyxVaultFactory.sol";
import {MyxVault} from "../src/MyxVault.sol";
import {MarketId} from "../src/myx/IMyxPool.sol";
import {IVaultFactoryValidationV2} from "../src/flap/IVaultFactory.sol";
import "./mocks/Mocks.sol";

contract MyxVaultFactoryTest is Test {
    MyxVaultFactory factory;
    MockWBNB wbnb;
    MockERC20 usdt;
    MockERC20 btcb;
    MockAggregatorV3 bnbFeed;
    MockAggregatorV3 usdtFeed;
    MockAggregatorV3 btcbFeed;
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
        btcb = new MockERC20("BTCB", "BTCB");
        bnbFeed = new MockAggregatorV3(600e8, 8);
        usdtFeed = new MockAggregatorV3(1e8, 8);
        btcbFeed = new MockAggregatorV3(60_000e8, 8);
        basePool = new MockBasePool(new MockERC20("LP", "LP"), usdt);
        poolManager = new MockPoolManager();
        router = new MockPancakeRouter();

        address[] memory baseTokens = new address[](2);
        baseTokens[0] = address(wbnb);
        baseTokens[1] = address(btcb);
        address[] memory feeds = new address[](2);
        feeds[0] = address(0); // WBNB path needs no feed
        feeds[1] = address(btcbFeed);

        factory = new MyxVaultFactory(
            MyxVaultFactory.GlobalConfig({
                poolManager: address(poolManager),
                basePool: address(basePool),
                swapRouter: address(router),
                wbnb: address(wbnb),
                quoteToken: address(usdt),
                bnbUsdFeed: address(bnbFeed),
                usdtUsdFeed: address(usdtFeed),
                maxSlippageBps: 300,
                minProcessAmount: 0.1 ether,
                maxPriceStaleness: 3600
            }),
            baseTokens,
            feeds
        );
    }

    function _vaultData(address base) internal view returns (bytes memory) {
        return abi.encode(base, marketId);
    }

    function test_newVault_onlyVaultPortal() public {
        vm.expectRevert();
        factory.newVault(makeAddr("tax"), address(0), makeAddr("creator"), _vaultData(address(wbnb)));
    }

    function test_newVault_deploysInitializedProxy() public {
        vm.prank(VAULT_PORTAL);
        address vaultAddr =
            factory.newVault(makeAddr("tax"), address(0), makeAddr("creator"), _vaultData(address(wbnb)));
        MyxVault v = MyxVault(payable(vaultAddr));
        assertEq(v.taxToken(), makeAddr("tax"));
        assertEq(v.baseToken(), address(wbnb));
        assertEq(v.creator(), makeAddr("creator"));
        vm.expectRevert();
        v.initialize(
            MyxVault.InitParams({
                taxToken: address(1), creator: address(1), baseToken: address(1),
                marketId: marketId, poolManager: address(1), basePool: address(1),
                swapRouter: address(1), wbnb: address(1), quoteToken: address(1),
                bnbUsdFeed: address(1), usdtUsdFeed: address(1), baseTokenUsdFeed: address(1),
                maxSlippageBps: 0, minProcessAmount: 0, maxPriceStaleness: 0
            })
        );
    }

    function test_newVault_rejectsUnsupportedBaseToken() public {
        vm.prank(VAULT_PORTAL);
        vm.expectRevert(MyxVaultFactory.UnsupportedBaseToken.selector);
        factory.newVault(makeAddr("tax"), address(0), makeAddr("creator"), _vaultData(makeAddr("junk")));
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
}
