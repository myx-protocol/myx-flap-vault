// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.26;

import {Test} from "forge-std/Test.sol";
import {MyxVault} from "../src/MyxVault.sol";
import {VaultBase} from "../src/flap/VaultBase.sol";
import {FlapDeployed} from "../src/FlapDeployed.sol";
import {VaultUISchema} from "../src/flap/IVaultSchemasV1.sol";
import {VaultBaseV2} from "../src/flap/VaultBaseV2.sol";

/// @dev Exposes VaultBase's internal per-chain address resolvers for direct assertion.
contract VaultBaseHarness is VaultBaseV2 {
    function exposedGetPortal() external view returns (address) {
        return _getPortal();
    }

    function exposedGetGuardian() external view returns (address) {
        return _getGuardian();
    }

    function description() public pure override returns (string memory) {
        return "harness";
    }

    function vaultUISchema() public pure override returns (VaultUISchema memory schema) {}
}

/// @dev Exposes MyxVault's internal trigger-service resolver. The resolver is a pure chainid
///      branch, so the harness is used uninitialized on purpose.
contract MyxVaultHarness is MyxVault {
    function exposedGetTriggerService() external view returns (address) {
        return _getTriggerService();
    }
}

/// @notice Locks the hardcoded per-chain Flap addresses. These values are consensus-critical:
///         a wrong entry routes tax revenue to a foreign contract rather than reverting, because
///         Flap reuses CREATE2 addresses across chains and unrelated contracts occupy those slots
///         on other chains. Every address below is cross-checked against Flap's published
///         deployment table and the upstream flap-sh/FlapVaultExample VaultBase.
contract ChainAddressResolutionTest is Test {
    // BNB Chain (chainId 56).
    address constant BSC_PORTAL = 0xe2cE6ab80874Fa9Fa2aAE65D277Dd6B8e65C9De0;
    address constant BSC_GUARDIAN = 0x9e27098dcD8844bcc6287a557E0b4D09C86B8a4b;
    address constant BSC_TRIGGER_SERVICE = 0xcf4EE25035CF883895110f367F5BA8172416a7F9;
    address constant BSC_VAULT_PORTAL = 0x90497450f2a706f1951b5bdda52B4E5d16f34C06;

    // BNB Testnet (chainId 97).
    address constant BSC_TESTNET_PORTAL = 0x5bEacaF7ABCbB3aB280e80D007FD31fcE26510e9;
    address constant BSC_TESTNET_GUARDIAN = 0x76Fa8C526f8Bc27ba6958B76DeEf92a0dbE46950;
    address constant BSC_TESTNET_TRIGGER_SERVICE = 0x560E9830926C9e0EB98a59c6b9902383Fc0D9Eb2;
    address constant BSC_TESTNET_VAULT_PORTAL = 0x027e3704fC5C16522e9393d04C60A3ac5c0d775f;

    // Robinhood Chain Mainnet (chainId 4663).
    uint256 constant ROBINHOOD_CHAIN_ID = 4663;
    address constant ROBINHOOD_PORTAL = 0x26605f322f7fF986f381bB9A6e3f5DAb0bEaEb09;
    address constant ROBINHOOD_GUARDIAN = 0x0000b48720d3B4ED6BC5031768B07F2b59270000;
    address constant ROBINHOOD_TRIGGER_SERVICE = 0xD3421B1b616a72bB88993A0cf75709BB8D532cc1;
    address constant ROBINHOOD_VAULT_PORTAL = 0xe9F7AB7DE8FB8756acbB6a1cd13316a43308197B;

    /// @dev Robinhood Chain Testnet. Flap has deployed a trigger service here, but upstream
    ///      VaultBase ships no Portal or Guardian for it, so the chain stays unsupported.
    uint256 constant ROBINHOOD_TESTNET_CHAIN_ID = 46630;

    VaultBaseHarness base;
    MyxVaultHarness vault;

    function setUp() public {
        base = new VaultBaseHarness();
        vault = new MyxVaultHarness();
    }

    function test_getPortal_robinhoodMainnet() public {
        vm.chainId(ROBINHOOD_CHAIN_ID);
        assertEq(base.exposedGetPortal(), ROBINHOOD_PORTAL);
    }

    function test_getGuardian_robinhoodMainnet() public {
        vm.chainId(ROBINHOOD_CHAIN_ID);
        assertEq(base.exposedGetGuardian(), ROBINHOOD_GUARDIAN);
    }

    function test_getTriggerService_robinhoodMainnet() public {
        vm.chainId(ROBINHOOD_CHAIN_ID);
        assertEq(vault.exposedGetTriggerService(), ROBINHOOD_TRIGGER_SERVICE);
    }

    function test_vaultPortal_robinhoodMainnet() public {
        vm.chainId(ROBINHOOD_CHAIN_ID);
        assertEq(FlapDeployed.vaultPortal(), ROBINHOOD_VAULT_PORTAL);
    }

    function test_getPortal_bscUnchanged() public {
        vm.chainId(56);
        assertEq(base.exposedGetPortal(), BSC_PORTAL);
        vm.chainId(97);
        assertEq(base.exposedGetPortal(), BSC_TESTNET_PORTAL);
    }

    function test_getGuardian_bscUnchanged() public {
        vm.chainId(56);
        assertEq(base.exposedGetGuardian(), BSC_GUARDIAN);
        vm.chainId(97);
        assertEq(base.exposedGetGuardian(), BSC_TESTNET_GUARDIAN);
    }

    function test_getTriggerService_bscUnchanged() public {
        vm.chainId(56);
        assertEq(vault.exposedGetTriggerService(), BSC_TRIGGER_SERVICE);
        vm.chainId(97);
        assertEq(vault.exposedGetTriggerService(), BSC_TESTNET_TRIGGER_SERVICE);
    }

    function test_vaultPortal_bscUnchanged() public {
        vm.chainId(56);
        assertEq(FlapDeployed.vaultPortal(), BSC_VAULT_PORTAL);
        vm.chainId(97);
        assertEq(FlapDeployed.vaultPortal(), BSC_TESTNET_VAULT_PORTAL);
    }

    /// @dev Robinhood testnet must keep reverting: a trigger service alone cannot carry a vault,
    ///      and half-support would be worse than an explicit unsupported chain.
    function test_robinhoodTestnetUnsupported() public {
        vm.chainId(ROBINHOOD_TESTNET_CHAIN_ID);
        vm.expectRevert(abi.encodeWithSelector(VaultBase.UnsupportedChain.selector, ROBINHOOD_TESTNET_CHAIN_ID));
        base.exposedGetPortal();
        vm.expectRevert(abi.encodeWithSelector(VaultBase.UnsupportedChain.selector, ROBINHOOD_TESTNET_CHAIN_ID));
        base.exposedGetGuardian();
        vm.expectRevert(unicode"Trigger service not configured / 觸發服務未配置");
        vault.exposedGetTriggerService();
    }

    /// @dev No silent fallback to another chain's addresses: an unknown chain must revert.
    function test_unknownChainReverts() public {
        vm.chainId(1);
        vm.expectRevert(abi.encodeWithSelector(VaultBase.UnsupportedChain.selector, uint256(1)));
        base.exposedGetPortal();
        vm.expectRevert(unicode"Trigger service not configured / 觸發服務未配置");
        vault.exposedGetTriggerService();
        vm.expectRevert("FlapDeployed: unsupported chain");
        FlapDeployed.vaultPortal();
    }
}
