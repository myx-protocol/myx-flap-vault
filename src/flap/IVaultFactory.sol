// SPDX-License-Identifier: MIT

pragma solidity ^0.8.13;

import {IPortalTypes} from "./IPortal.sol";

// ─── Flap v2.3 Dividend-Token Resolution ────────────────────────────────────

/// @dev launchVersion sentinel for NewTokenV6WithVaultParams (TOKEN_TAXED_V3).
uint8 constant DIVIDEND_TOKEN_LAUNCH_VERSION_V6 = 6;

/// @dev launchVersion sentinel for NewTokenV7WithVaultParams (TOKEN_V3_PERMIT / flexible fee).
uint8 constant DIVIDEND_TOKEN_LAUNCH_VERSION_V7 = 7;

/// @title IVaultFactoryDividendV23
/// @notice Optional callback interface introduced in Flap factory spec v2.3.
/// @dev    VaultPortal invokes this via STATICCALL when a token's dividendToken is the
///         MAGIC_DIVIDEND_COMPUTED sentinel (see IPortal.sol). The factory must be `view`
///         so that VaultPortal can call it safely without state side-effects.
///
///         Flow:
///           1. Launcher sets params.dividendToken = MAGIC_DIVIDEND_COMPUTED.
///           2. VaultPortal predicts the tax-token address (CREATE2).
///           3. VaultPortal STATICCALL → factory.resolveDividendToken(predictedToken, launchVersion, launchParams).
///           4. Factory decodes launchParams and returns the real dividend token address.
///           5. VaultPortal uses that address as the token's dividendToken.
///
///         launchVersion values:
///           DIVIDEND_TOKEN_LAUNCH_VERSION_V6 (6) → launchParams = abi.encode(NewTokenV6WithVaultParams)
///           DIVIDEND_TOKEN_LAUNCH_VERSION_V7 (7) → launchParams = abi.encode(NewTokenV7WithVaultParams) [pending]
interface IVaultFactoryDividendV23 {
    /// @notice Resolve the real dividend token given the predicted tax-token address and launch params.
    /// @param predictedToken  CREATE2-predicted address of the tax token (not yet deployed).
    /// @param launchVersion   Version discriminator: 6 = V6, 7 = V7 (see constants above).
    /// @param launchParams    ABI-encoded launch params struct (version-specific).
    /// @return dividendToken  The real dividend token address to use for this launch.
    function resolveDividendToken(address predictedToken, uint8 launchVersion, bytes calldata launchParams)
        external
        view
        returns (address dividendToken);
}

/// @title IVaultFactory
/// @notice Interface that all vault factory contracts must implement
/// @dev Each vault type must have a corresponding factory contract that implements this interface
interface IVaultFactory {
    /* ========== ERRORS ========== */

    /// @notice Thrown when caller is not the vault portal
    error OnlyVaultPortal();

    /// @notice Thrown when zero address is provided
    error ZeroAddress();

    /* ========== FUNCTIONS ========== */
    /// @notice Creates a new vault instance for a tax token
    /// @dev IMPORTANT: The taxToken does not exist yet when this method is called.
    ///      The VaultPortal predicts the token address and passes it here.
    ///      The actual token will be created AFTER the vault is created.
    /// @param taxToken The predicted address of the tax token (not yet deployed)
    /// @param quoteToken The quote token address (e.g., address(0) for native BNB)
    /// @param creator The original msg.sender to VaultPortal who initiated token creation
    /// @param vaultData Custom encoded data specific to this vault type
    /// @return vault The address of the newly created vault
    function newVault(address taxToken, address quoteToken, address creator, bytes calldata vaultData)
        external
        returns (address vault);

    /// @notice Checks if a quote token is supported by this vault factory
    /// @param quoteToken The quote token address to check
    /// @return supported True if the quote token is supported, false otherwise
    function isQuoteTokenSupported(address quoteToken) external view returns (bool supported);
}

/// @title IVaultFactoryValidationV2
/// @notice Optional validation extension introduced by factory spec v2.2.
/// @dev    Kept in the same file as `IVaultFactory` for discoverability, but intentionally
///         separated as its own interface because `onBeforeLaunch(...)` is not a mandatory
///         requirement for legacy vault factories.
interface IVaultFactoryValidationV2 {
    /// @notice Stable validation payload used by VaultPortal when talking to v2.2+ factories.
    /// @dev    This payload intentionally contains normalized launch semantics instead of
    ///         wrapper-specific structs such as `NewTokenV6WithVaultParams` or `NewTokenV7WithVaultParams`.
    struct LaunchValidationDataV1 {
        IPortalTypes.TokenVersion tokenVersion;
        address quoteToken;
        uint16 buyTaxRate;
        uint16 sellTaxRate;
        uint16 vaultBps;
        uint16 deflationBps;
        uint16 dividendBps;
        uint16 lpBps;
        address dividendToken;
        uint256 minimumShareBalance;
    }

    /// @notice Generic pre-launch validation hook.
    /// @param validationData ABI-encoded normalized launch payload.
    /// @return success True when the launch satisfies this factory's product constraints.
    /// @return reason Human-readable explanation when `success` is false.
    function onBeforeLaunch(bytes calldata validationData) external view returns (bool success, string memory reason);
}

