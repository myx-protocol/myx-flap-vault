// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.26;

import {Script, console2} from "forge-std/Script.sol";
import {MyxVaultFactory} from "../../../src/MyxVaultFactory.sol";

/// @notice Deploys MyxVaultFactory on Robinhood Chain mainnet (chainId 4663).
///         MYX protocol addresses stay env-driven, matching the BNB scripts.
/// @dev Two deliberate differences from the BNB mainnet script:
///      1. minProcessAmount is NOT 1 wei. The native currency here is ETH and the
///         FlapTriggerService fee is 0.0004 ETH (vs 0.0002 BNB on BSC), and scheduleProcess()
///         requires pendingBnb >= minProcessAmount + fee. With a 1 wei floor the fee would
///         consume essentially the entire scheduled batch. 0.004 ETH keeps the fee at roughly
///         10% of a batch. Flap documents that Robinhood fees are expected to become dynamic,
///         so re-check getFee() against this floor before each deployment.
///      2. Robinhood Chain testnet (46630) has no script: Flap ships a trigger service there
///         but no Portal or Guardian, so a vault cannot initialize on that chain.
contract DeployMyxVaultFactory is Script {
    function run() external {
        require(block.chainid == 4663, "wrong chain");
        vm.startBroadcast();
        MyxVaultFactory factory = new MyxVaultFactory(
            MyxVaultFactory.GlobalConfig({
                poolManager: vm.envAddress("MYX_POOL_MANAGER"),
                basePool: vm.envAddress("MYX_BASE_POOL"),
                // myx PoolFactory: authoritative basePoolToken (mBase LP) predictor used by the
                // v2.3 resolveDividendToken callback.
                poolFactory: vm.envAddress("MYX_POOL_FACTORY"),
                maxSlippageBps: 300,
                minProcessAmount: 0.0005 ether
            })
        );
        console2.log("MyxVaultFactory:", address(factory));
        console2.log("Beacon:", address(factory.beacon()));
        vm.stopBroadcast();
    }
}
