// SPDX-License-Identifier: MIT
pragma solidity ^0.8.13;

/// @title ISwapRegistry
/// @notice Subset of Flap's SwapRegistry (TaxProcessor.swapRegistry()). Verified on BSC mainnet
///         (proxy 0x644A8f560138418bAD4EdEFC7c17878a3c2fBEB6): exposes the MultiDexRouter instance
///         Flap uses for quote conversions and the canonical wrapped-native token.
interface ISwapRegistry {
    function multiDexRouter() external view returns (address);
    function weth() external view returns (address);
}
