// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.26;

import {Script, console2} from "forge-std/Script.sol";
import {MyxVaultFactory} from "../../../src/MyxVaultFactory.sol";

/// @notice Deploys MyxVaultFactory on BNB testnet (chainId 97).
///         MYX addresses come from env to avoid hardcoding unverified ones. v4 removed the
///         DEX router, WBNB, quote token and Chainlink feed config: harvest distributes the
///         pool quote token directly as the dividend token (no swap, no feeds).
contract DeployMyxVaultFactory is Script {
    function run() external {
        require(block.chainid == 97, "wrong chain");
        vm.startBroadcast();
        MyxVaultFactory factory = new MyxVaultFactory(
            MyxVaultFactory.GlobalConfig({
                poolManager: vm.envAddress("MYX_POOL_MANAGER"),
                basePool: vm.envAddress("MYX_BASE_POOL"),
                // myx PoolFactory: authoritative basePoolToken (mBase LP) predictor used by the
                // v2.3 resolveDividendToken callback. Env-driven to avoid hardcoding unverified ones.
                poolFactory: vm.envAddress("MYX_POOL_FACTORY"),
                maxSlippageBps: 500,
                minProcessAmount: 1
            })
        );
        console2.log("MyxVaultFactory:", address(factory));
        console2.log("Beacon:", address(factory.beacon()));
        vm.stopBroadcast();
    }
}
