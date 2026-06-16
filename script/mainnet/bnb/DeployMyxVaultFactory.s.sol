// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.26;

import {Script, console2} from "forge-std/Script.sol";
import {MyxVaultFactory} from "../../../src/MyxVaultFactory.sol";

/// @notice Deploys MyxVaultFactory on BNB mainnet (chainId 56).
///         MYX protocol addresses (poolManager, basePool) remain env-driven because MYX has
///         not yet been deployed on BSC mainnet; hardcoding them here would embed unverified
///         addresses that will change at launch. v4 removed the DEX router, WBNB, quote token
///         and Chainlink feed config: harvest distributes the pool quote token directly as the
///         dividend token (no swap, no feeds), so those mainnet constants are no longer needed.
contract DeployMyxVaultFactory is Script {
    function run() external {
        require(block.chainid == 56, "wrong chain");
        vm.startBroadcast();
        MyxVaultFactory factory = new MyxVaultFactory(
            MyxVaultFactory.GlobalConfig({
                poolManager: vm.envAddress("MYX_POOL_MANAGER"),
                basePool: vm.envAddress("MYX_BASE_POOL"),
                // myx PoolFactory: authoritative basePoolToken (mBase LP) predictor used by the
                // v2.3 resolveDividendToken callback. Env-driven (MYX not yet live on BSC mainnet).
                poolFactory: vm.envAddress("MYX_POOL_FACTORY"),
                maxSlippageBps: 300,
                minProcessAmount: 1
            })
        );
        console2.log("MyxVaultFactory:", address(factory));
        console2.log("Beacon:", address(factory.beacon()));
        vm.stopBroadcast();
    }
}
