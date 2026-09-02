// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.26;

import {Test} from "forge-std/Test.sol";
import {VaultBaseV3} from "../src/flap/VaultBaseV3.sol";
import {IPortalQuoteConfigU8} from "../src/flap/IPortalQuoteConfigU8.sol";
import {ISwapRegistry} from "../src/flap/ISwapRegistry.sol";
import {IMultiDexRouter} from "../src/flap/IMultiDexRouter.sol";
import {IPortalTypes} from "../src/flap/IPortal.sol";
import {VaultUISchema} from "../src/flap/IVaultSchemasV1.sol";

contract V3Harness is VaultBaseV3 {
    function vaultQuoteToken() public pure override returns (address) {
        return address(0);
    }

    function description() public pure override returns (string memory) {
        return "h";
    }

    function vaultUISchema() public pure override returns (VaultUISchema memory s) {}
}

/// @dev Locks the interface surface the vault relies on. Selectors are the on-chain ones
///      (verified against BSC mainnet MultiDexRouter 0xDedF55b0... and Portal v5.22.0 sources).
contract FlapInterfacesTest is Test {
    function test_vaultBaseV3_defaultSpecVersion() public {
        V3Harness h = new V3Harness();
        assertEq(h.vaultSpecVersion(), "v3");
        assertEq(h.vaultQuoteToken(), address(0));
    }

    function test_selectors_matchOnChain() public pure {
        assertEq(IPortalQuoteConfigU8.getQuoteTokenConfiguration.selector, bytes4(keccak256("getQuoteTokenConfiguration(address)")));
        assertEq(ISwapRegistry.multiDexRouter.selector, bytes4(0x952b8901));
        assertEq(ISwapRegistry.weth.selector, bytes4(0x3fc8cef3));
        assertEq(IMultiDexRouter.getDEXInfo.selector, bytes4(0x9b5f292e));
        assertEq(IMultiDexRouter.computeV3PoolAddress.selector, bytes4(0x2b63e1e4));
        assertEq(IMultiDexRouter.exactInputSingle.selector, bytes4(0x46a7da76));
        assertEq(IMultiDexRouter.quoteExactInputSingle.selector, bytes4(0x80e11b74));
    }

    function test_swapViaRoute_enumValueIs7() public pure {
        assertEq(uint8(IPortalTypes.NativeToQuoteSwapType.SWAP_VIA_ROUTE), 7);
    }
}
