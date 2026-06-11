// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

/// @notice Interface to the Flap tax token's native Dividend contract.
/// @dev ABI VERIFIED on-chain by Task 0 (docs/phase0-findings.md):
///      - deposit(uint256) is approve+pull WBNB, permissionless, RETURNS false ON FAILURE
///        (does not revert) — callers MUST check the return value.
///      - withdrawableDividends(address) is the per-holder claimable view.
///      - Holders claim via withdrawDividends() directly on the Dividend contract.
interface IDividendDistributor {
    function deposit(uint256 amount) external returns (bool success);
    function withdrawableDividends(address user) external view returns (uint256);
}
