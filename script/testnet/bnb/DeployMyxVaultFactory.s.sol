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
                maxSlippageBps: 300,
                minProcessAmount: 0.01 ether,
                // The Flap TriggerService testnet address is unknown; supply it via env.
                triggerService: vm.envAddress("FLAP_TRIGGER_SERVICE"),
                triggerInterval: uint64(vm.envOr("TRIGGER_INTERVAL", uint256(1 hours)))
            })
        );
        console2.log("MyxVaultFactory:", address(factory));
        console2.log("Beacon:", address(factory.beacon()));
        vm.stopBroadcast();
    }
}
