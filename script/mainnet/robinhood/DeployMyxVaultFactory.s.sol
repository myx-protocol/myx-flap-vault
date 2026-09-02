// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.26;

import {Script, console2} from "forge-std/Script.sol";
import {MyxVaultFactory} from "../../../src/MyxVaultFactory.sol";

/// @notice Deploys MyxVaultFactory on Robinhood Chain mainnet (chainId 4663).
///         MYX protocol addresses stay env-driven, matching the BNB scripts.
/// @dev Two deliberate differences from the BNB mainnet script:
///      1. ERC20/RWA quote launches are not supported on Robinhood Chain in this release — native
///         ETH only — so `minInitialGas` is 0: no creator prepay is required or accepted here.
///         Per-vault `minProcessAmount` is no longer part of `GlobalConfig`; it is creator-supplied
///         per launch via `vaultData` (`abi.encode(address marketQuoteToken, uint256
///         minProcessAmount, uint256 gasThreshold, uint256 gasRefillAmount)`). For native launches
///         on this chain, recommend 0.004 ETH: the native currency here is ETH and the
///         FlapTriggerService fee is 0.0004 ETH (vs 0.0002 BNB on BSC), and scheduleProcess()
///         requires pendingQuote >= minProcessAmount + fee — with a 1 wei floor the fee would
///         consume essentially the entire scheduled batch. 0.004 ETH keeps the fee at roughly 10%
///         of a batch. Flap documents that Robinhood fees are expected to become dynamic, so
///         re-check getFee() against this recommendation before each deployment.
///      2. Robinhood Chain testnet (46630) has no script: Flap ships a trigger service there
///         but no Portal or Guardian, so a vault cannot initialize on that chain.
///
///      Deploy checklist (Robinhood Chain, 4663):
///      - EIP-1153: confirm the chain executes TLOAD/TSTORE (ArbOS >= 32 / Cancun) BEFORE deploying.
///        MyxVault.receive() reads a transient-storage flag as its first statement, so without those
///        opcodes every receive() call reverts: no tax is recognised on arrival and no process() is
///        auto-scheduled (sync()/process() still work when called manually). Verify against the live
///        chain, not the docs, e.g. by deploying a probe contract that TSTOREs and TLOADs one slot.
///      - getFee(): re-check FlapTriggerService.getFee() against the minProcessAmount recommendation
///        above; Flap documents that Robinhood fees are expected to become dynamic.
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
                minInitialGas: 0,
                // Native-quote launches only on this chain: no vault may refill a gas pool, so the
                // ceiling on gasRefillAmount is 0.
                maxGasRefillAmount: 0
            })
        );
        console2.log("MyxVaultFactory:", address(factory));
        console2.log("Beacon:", address(factory.beacon()));
        vm.stopBroadcast();
    }
}
