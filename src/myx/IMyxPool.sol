// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

type MarketId is bytes32;
type PoolId is bytes32;

/// @dev Mirrors myx-contract-v2 PoolKey hashing: poolId = keccak256(abi.encode(marketId, baseToken)).
library MyxPoolId {
    function derive(MarketId marketId, address baseToken) internal pure returns (PoolId) {
        return PoolId.wrap(keccak256(abi.encode(marketId, baseToken)));
    }
}

/// @dev Subset of myx PoolMetadata — field order must match upstream struct exactly.
struct PoolMetadata {
    MarketId marketId;
    PoolId poolId;
    address baseToken;
    address quoteToken;
    uint8 riskTier;
    uint8 state; // PoolState enum upstream; only zero-check is used here
    bool compoundEnabled;
    address basePoolToken;
    address quotePoolToken;
    address poolVault;
    address tradingVault;
}

interface IMyxPoolManager {
    struct DeployPoolParams {
        MarketId marketId;
        address baseToken;
    }

    /// @notice Permissionless in myx (PoolManager.sol:152); requires market to exist.
    function deployPool(DeployPoolParams calldata params) external;

    function getPool(PoolId poolId) external view returns (PoolMetadata memory pool);
}

interface IMyxBasePool {
    function deposit(PoolId poolId, uint256 amountIn, uint256 minAmountOut, address user, address recipient)
        external
        returns (uint256 amountOut);

    function withdraw(PoolId poolId, uint256 amountIn, uint256 minAmountOut, address user, address recipient)
        external
        returns (uint256 amountOut, uint256 rebateOut);

    function claimUserRebate(PoolId poolId, address user, address recipient) external returns (uint256 rebateOut);

    function pendingUserRebates(PoolId poolId, address user, uint256 price)
        external
        view
        returns (uint256 rebates, uint256 genesisRebates);
}
