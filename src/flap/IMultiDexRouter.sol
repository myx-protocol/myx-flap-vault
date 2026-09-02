// SPDX-License-Identifier: MIT
pragma solidity ^0.8.13;

/// @title IMultiDexRouter
/// @notice Subset of Flap's MultiDexRouter (Sourcify-verified, BSC 0xDedF55b08a3f1c61576a4bd675825690e1eE99ec).
///         A permissionless multi-DEX wrapper with Uniswap-style V3 single-hop quote and swap.
///         Used by MyxVault only for the gas-refill leg (quote token -> wrapped native).
interface IMultiDexRouter {
    struct DEXInfo {
        bytes32 v2InitCodeHash;
        bytes32 v3InitCodeHash;
        address v2Factory;
        address v3Factory;
        address v3Deployer;
        address v4Vault;
        uint24[] v3SupportedFees;
        address smartRouter;
        address v3Quoter;
        address v2SwapRouter;
        address nonfungiblePositionManager;
    }

    struct ExactInputSingleParams {
        address tokenIn;
        address tokenOut;
        uint24 fee;
        address recipient;
        uint256 amountIn;
        uint256 amountOutMinimum;
        uint160 sqrtPriceLimitX96;
    }

    struct QuoteExactInputSingleParams {
        address tokenIn;
        address tokenOut;
        uint256 amountIn;
        uint24 fee;
        uint160 sqrtPriceLimitX96;
    }

    function getDEXInfo(uint8 dexId) external view returns (DEXInfo memory dexInfo);

    function computeV3PoolAddress(uint8 dexId, address tokenA, address tokenB, uint24 fee)
        external
        view
        returns (address pool);

    /// @dev Pulls `amountIn` of tokenIn from msg.sender (allowance required); pays tokenOut to recipient.
    function exactInputSingle(uint8 dexId, ExactInputSingleParams calldata params)
        external
        payable
        returns (uint256 amountOut);

    /// @dev NOT a view (Uniswap quoter pattern) — callers must use try/catch.
    function quoteExactInputSingle(uint8 dexId, QuoteExactInputSingleParams memory params)
        external
        returns (uint256 amountOut, uint160 sqrtPriceX96After, uint32 initializedTicksCrossed, uint256 gasEstimate);
}
