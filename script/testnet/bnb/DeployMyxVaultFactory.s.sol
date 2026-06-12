// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.26;

import {Script, console2} from "forge-std/Script.sol";
import {MyxVaultFactory} from "../../../src/MyxVaultFactory.sol";

/// @notice Deploys MyxVaultFactory on BNB testnet (chainId 97).
///         All MYX/DEX/feed addresses come from env to avoid hardcoding unverified ones.
contract DeployMyxVaultFactory is Script {
    function run() external {
        require(block.chainid == 97, "wrong chain");
        vm.startBroadcast();
        MyxVaultFactory factory = new MyxVaultFactory(
            MyxVaultFactory.GlobalConfig({
                poolManager: vm.envAddress("MYX_POOL_MANAGER"),
                basePool: vm.envAddress("MYX_BASE_POOL"),
                swapRouter: vm.envAddress("PANCAKE_ROUTER"),
                wbnb: vm.envAddress("WBNB"),
                quoteToken: vm.envAddress("MYX_QUOTE_TOKEN"),
                bnbUsdFeed: vm.envAddress("BNB_USD_FEED"),
                usdtUsdFeed: vm.envAddress("USDT_USD_FEED"),
                maxSlippageBps: 300,
                minProcessAmount: 0.01 ether,
                maxPriceStaleness: 3600
            })
        );
        console2.log("MyxVaultFactory:", address(factory));
        console2.log("Beacon:", address(factory.beacon()));
        vm.stopBroadcast();
    }
}
