// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.26;

import {Test} from "forge-std/Test.sol";
import {MyxVault} from "../src/MyxVault.sol";
import {MyxVaultFactory} from "../src/MyxVaultFactory.sol";

/// @notice Locks the deployability limits that `forge test` does not enforce on its own:
///         EIP-170 (24,576-byte runtime code) for every contract we deploy, and EIP-3860
///         (49,152-byte initcode, constructor args included) for the factory, whose constructor
///         embeds the whole MyxVault creation code. The BSC testnet deploy of 2026-09-03 failed
///         with "max initcode size exceeded" while the unit suite was fully green.
contract CodeSizeTest is Test {
    uint256 internal constant EIP170_RUNTIME_LIMIT = 24_576;
    uint256 internal constant EIP3860_INITCODE_LIMIT = 49_152;

    function _config() internal pure returns (MyxVaultFactory.GlobalConfig memory c) {
        c.poolManager = address(1);
        c.basePool = address(2);
        c.poolFactory = address(3);
        c.maxSlippageBps = 300;
        c.minInitialGas = 0.002 ether;
        c.maxGasRefillAmount = 0.05 ether;
    }

    function test_vaultRuntimeWithinEip170() public {
        uint256 size = address(new MyxVault()).code.length;
        assertLe(size, EIP170_RUNTIME_LIMIT, "MyxVault runtime exceeds EIP-170");
    }

    function test_factoryRuntimeWithinEip170() public {
        uint256 size = address(new MyxVaultFactory(_config())).code.length;
        assertLe(size, EIP170_RUNTIME_LIMIT, "MyxVaultFactory runtime exceeds EIP-170");
    }

    function test_factoryInitcodeWithinEip3860() public pure {
        // Deploy tx data = creation code + ABI-encoded constructor args (one static struct).
        uint256 initcode = type(MyxVaultFactory).creationCode.length + abi.encode(_config()).length;
        assertLe(initcode, EIP3860_INITCODE_LIMIT, "MyxVaultFactory initcode exceeds EIP-3860");
    }
}
