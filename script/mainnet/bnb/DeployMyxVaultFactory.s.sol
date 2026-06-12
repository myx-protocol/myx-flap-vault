// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.26;

import {Script, console2} from "forge-std/Script.sol";
import {MyxVaultFactory} from "../../../src/MyxVaultFactory.sol";

/// @notice Deploys MyxVaultFactory on BNB mainnet (chainId 56).
///         MYX protocol addresses (poolManager, basePool, quoteToken) remain env-driven
///         because MYX has not yet been deployed on BSC mainnet; hardcoding them here
///         would embed unverified addresses that will change at launch.
///         Well-known mainnet constants (WBNB, PancakeV2 router, Chainlink feeds) are
///         inlined from Task-0-verified sources and are safe to hardcode.
contract DeployMyxVaultFactory is Script {
    // BNB mainnet — Task-0-verified constants
    address internal constant WBNB        = 0xbb4CdB9CBd36B01bD1cBaEBF2De08d9173bc095c;
    address internal constant PANCAKE_ROUTER = 0x10ED43C718714eb63d5aA57B78B54704E256024E;
    address internal constant BNB_USD_FEED   = 0x0567F2323251f0Aab15c8dFb1967E4e8A7D42aeE;
    address internal constant USDT_USD_FEED  = 0xB97Ad0E74fa7d920791E90258A6E2085088b4320;

    function run() external {
        require(block.chainid == 56, "wrong chain");
        vm.startBroadcast();
        address[] memory baseTokens = new address[](1);
        baseTokens[0] = WBNB;
        address[] memory feeds = new address[](1);
        feeds[0] = address(0);

        MyxVaultFactory factory = new MyxVaultFactory(
            MyxVaultFactory.GlobalConfig({
                poolManager: vm.envAddress("MYX_POOL_MANAGER"),
                basePool: vm.envAddress("MYX_BASE_POOL"),
                swapRouter: PANCAKE_ROUTER,
                wbnb: WBNB,
                quoteToken: vm.envAddress("MYX_QUOTE_TOKEN"),
                bnbUsdFeed: BNB_USD_FEED,
                usdtUsdFeed: USDT_USD_FEED,
                maxSlippageBps: 300,
                minProcessAmount: 0.1 ether,
                maxPriceStaleness: 3600
            }),
            baseTokens,
            feeds
        );
        console2.log("MyxVaultFactory:", address(factory));
        console2.log("Beacon:", address(factory.beacon()));
        vm.stopBroadcast();
    }
}
