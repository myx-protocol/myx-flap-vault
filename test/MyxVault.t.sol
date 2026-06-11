// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.26;

import {Test} from "forge-std/Test.sol";
import {MyxVault} from "../src/MyxVault.sol";
import {MarketId, PoolId, MyxPoolId} from "../src/myx/IMyxPool.sol";
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

        MyxVault impl = new MyxVault();
        bytes memory initData = abi.encodeCall(MyxVault.initialize, (_initParams(address(wbnb))));
        ERC1967Proxy proxy = new ERC1967Proxy(address(impl), initData);
        vault = MyxVault(payable(address(proxy)));
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
