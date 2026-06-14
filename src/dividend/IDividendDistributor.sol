// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

/// @notice Interface to the Flap tax token's native Dividend contract.
/// @dev ABI VERIFIED on-chain by Task 0 (docs/phase0-findings.md):
///      - deposit(uint256) is approve+pull of the contract's configured dividendToken,
///        permissionless, RETURNS false ON FAILURE (does not revert, e.g. totalShares == 0)
///        — callers MUST check the return value.
///      - withdrawableDividends(address) is the per-holder claimable view.
///      - withdrawDividendsFor(address) claims a holder's dividend ON THEIR BEHALF, paying the
///        dividendToken to that holder (the Lista proxy target — lets the vault expose a
///        claimReward() convenience without holding the reward itself).
///      - dividendToken() is the token deposit() pulls and distributes (parameterized, not
///        hardcoded WBNB). v6 sets dividendToken == the myx base-pool LP (mBase) at launch via
///        computeDividendToken, so deposit() distributes the LP the vault produced DIRECTLY —
///        the reward asset IS the LP, no USDT, no swap.
///      - Holders may also claim via withdrawDividends() directly on the Dividend contract.
interface IDividendDistributor {
    function deposit(uint256 amount) external returns (bool success);
    function withdrawableDividends(address user) external view returns (uint256);
    function withdrawDividendsFor(address user) external;
    function dividendToken() external view returns (address);
}
