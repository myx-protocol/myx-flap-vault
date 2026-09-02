// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.26;

import {Script, console2} from "forge-std/Script.sol";
import {MyxVaultFactory} from "../../../src/MyxVaultFactory.sol";

/// @notice Deploys MyxVaultFactory on BNB testnet (chainId 97).
///         MYX addresses come from env to avoid hardcoding unverified ones.
///         Vault is Flap spec V3 (`VaultBaseV3`): the launch quote may be native BNB or any
///         ERC20/RWA quote token enabled on the Flap Portal (`vaultQuoteToken()`). Per-vault
///         `minProcessAmount` is no longer part of `GlobalConfig` — it is creator-supplied per
///         launch via `vaultData` (`abi.encode(address marketQuoteToken, uint256 minProcessAmount,
///         uint256 gasThreshold, uint256 gasRefillAmount)`). `minInitialGas` below is the
///         factory-wide floor on the BNB a creator must prepay via `factory.prepayGas()` before
///         launching an ERC20-quote vault; the factory forwards the full prepaid balance into the
///         new vault's gas pool at `newVault`.
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
                // ERC20-quote launches must prepay at least 10 FlapTriggerService fees (0.0002 BNB each).
                minInitialGas: 0.002 ether,
                // Caps the BNB a vault may divert from one batch into its gas pool: a creator's
                // gasRefillAmount may not exceed this. 0.05 BNB is ~250 trigger fees.
                maxGasRefillAmount: 0.05 ether
            })
        );
        console2.log("MyxVaultFactory:", address(factory));
        console2.log("Beacon:", address(factory.beacon()));
        vm.stopBroadcast();
    }
}
