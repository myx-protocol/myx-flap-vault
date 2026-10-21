// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.26;

import {Script, console2} from "forge-std/Script.sol";
import {UpgradeableBeacon} from "@openzeppelin/proxy/beacon/UpgradeableBeacon.sol";
import {MyxVault} from "../../../src/MyxVault.sol";
import {MyxVaultFactory} from "../../../src/MyxVaultFactory.sol";

/// @notice Deploys a new MyxVault implementation for the live BNB mainnet factory and prints the
///         Guardian transaction that points the vault beacon at it. The deployer key only deploys
///         the implementation; the beacon switch is Guardian-only (`upgradeVaultImplementation`)
///         and is executed by Flap.
///
///         Release: refill-only batches (PR #4, merge 7d3ea76). Storage is append-only: the single
///         new field `skipRefillOnce` occupies the previously unused byte 22 of slot 213, which is
///         zero on every live vault, so no migration or re-initialization is needed.
///
///         MUST be run with the existing UI-schema library linked, otherwise forge would deploy and
///         link a fresh copy:
///
///           forge script script/mainnet/bnb/UpgradeMyxVaultImplementation.s.sol \
///             --rpc-url https://bsc-dataseed.bnbchain.org --private-key $PRIVATE_KEY \
///             --libraries src/lib/MyxVaultUISchema.sol:MyxVaultUISchema:0x10Fd858F44eEd0DF1dCA64fB0BE78cB54971CA77 \
///             --broadcast --verify
///
///         Drop `--broadcast --verify` for a dry run.
contract UpgradeMyxVaultImplementation is Script {
    MyxVaultFactory internal constant FACTORY = MyxVaultFactory(0xeaEEa9c17a5376497C44fE2a5F9c63FE3B23bf87);
    address internal constant UI_SCHEMA_LIB = 0x10Fd858F44eEd0DF1dCA64fB0BE78cB54971CA77;
    address internal constant GUARDIAN = 0x9e27098dcD8844bcc6287a557E0b4D09C86B8a4b;

    function run() external returns (address impl) {
        require(block.chainid == 56, "wrong chain");
        require(!FACTORY.upgradesLocked(), "factory upgrades are locked");
        UpgradeableBeacon beacon = FACTORY.beacon();
        require(beacon.owner() == address(FACTORY), "beacon not owned by the factory");
        require(UI_SCHEMA_LIB.code.length > 0, "UI schema library missing on chain");
        address current = beacon.implementation();

        vm.startBroadcast();
        impl = address(new MyxVault());
        vm.stopBroadcast();

        // Post-deploy checks: this release's code, linked to the existing library (a wrong or missing
        // link makes vaultUISchema() revert or embeds a different address).
        MyxVault v = MyxVault(payable(impl));
        require(v.REFILL_QUOTE_GAS() == 300_000, "unexpected implementation code");
        require(v.vaultUISchema().methods.length > 0, "UI schema library not callable");
        require(_contains(impl.code, UI_SCHEMA_LIB), "implementation not linked to the live UI schema library");
        require(impl != current, "implementation unchanged");

        bytes memory data = abi.encodeCall(MyxVaultFactory.upgradeVaultImplementation, (impl));
        console2.log("Current implementation:", current);
        console2.log("New MyxVault implementation:", impl);
        console2.log("");
        console2.log("Guardian transaction (BNB mainnet, chainId 56):");
        console2.log("  from :", GUARDIAN);
        console2.log("  to   :", address(FACTORY));
        console2.log("  value: 0");
        console2.log("  call : upgradeVaultImplementation(address)");
        console2.log("  data :");
        console2.logBytes(data);
    }

    function _contains(bytes memory code, address needle) internal pure returns (bool) {
        bytes20 n = bytes20(needle);
        if (code.length < 20) return false;
        for (uint256 i = 0; i <= code.length - 20; i++) {
            bool hit = true;
            for (uint256 j = 0; j < 20; j++) {
                if (code[i + j] != n[j]) {
                    hit = false;
                    break;
                }
            }
            if (hit) return true;
        }
        return false;
    }
}
