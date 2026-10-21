// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.26;

/// @notice The one Uniswap/PancakeSwap V3 pool view the vault needs: in-range liquidity. A tier
///         whose pool contract exists but reports zero liquidity is not quotable in practice (the
///         quoter walks the whole tick bitmap and burns ~450k gas before failing on BSC).
interface IV3PoolLiquidity {
    function liquidity() external view returns (uint128);
}
