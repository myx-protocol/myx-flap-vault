// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.26;

// VERIFIED (2026-06-15) byte-for-byte against the official Flap v2.3 verified source — VaultPortal
// impl 0x00b2BE45FF38613a0e2b05acb5FeB76473CE6183, proxy 0x027e3704fC5C16522e9393d04C60A3ac5c0d775f:
//   - NewTokenV6WithVaultParamsU8 — all 27 fields match exactly (enums as uint8, ABI-compatible);
//   - NewTokenV7WithVaultParamsU8 — all 21 fields + FeeConfigU8[4] match exactly (enums as uint8);
//   - MAGIC_DIVIDEND_COMPUTED, DIVIDEND_TOKEN_LAUNCH_VERSION_V6/V7, IVaultFactoryDividendV23 confirmed;
//   - factorySpecVersion override "v2.3" (base default is "v2.2"); base does NOT declare resolveDividendToken.
// Both V6 and V7 paths are fully implemented and byte-verified.

import {VaultFactoryBaseV2} from "./flap/VaultFactoryBaseV2.sol";
import {
    IVaultFactory,
    IVaultFactoryValidationV2,
    IVaultFactoryDividendV23,
    DIVIDEND_TOKEN_LAUNCH_VERSION_V6,
    DIVIDEND_TOKEN_LAUNCH_VERSION_V7
} from "./flap/IVaultFactory.sol";
import {IVaultPortalTypes} from "./flap/IVaultPortal.sol";
import {MAGIC_DIVIDEND_COMPUTED} from "./flap/IPortal.sol";
import {VaultDataSchema, FieldDescriptor, FactoryPolicy} from "./flap/IVaultSchemasV1.sol";
import {BeaconProxy} from "@openzeppelin/proxy/beacon/BeaconProxy.sol";
import {UpgradeableBeacon} from "@openzeppelin/proxy/beacon/UpgradeableBeacon.sol";
import {MyxVault} from "./MyxVault.sol";
import {MarketId, MyxMarketId, IMyxPoolFactory} from "./myx/IMyxPool.sol";

/// @title MyxVaultFactory
/// @notice Deploys MyxVault beacon proxies for the Flap VaultPortal. The factory itself is
///         non-upgradeable; vault implementation upgrades are Guardian-only via the beacon.
contract MyxVaultFactory is VaultFactoryBaseV2, IVaultFactoryDividendV23 {
    struct GlobalConfig {
        address poolManager;
        address basePool;
        address poolFactory; // myx PoolFactory: authoritative basePoolToken (LP / mBase) predictor
        uint16 maxSlippageBps;
        uint256 minProcessAmount;
    }

    /// @notice FeeType.DIVIDEND == 2; identifies the dividend fee slot in V7 feeConfigs.
    uint8 internal constant FEE_TYPE_DIVIDEND = 2;

    error UnsupportedQuoteToken();
    error OnlyGuardian();
    error UpgradesLocked();

    event VaultCreated(
        address indexed vault, address indexed taxToken, address indexed creator, address marketQuoteToken
    );
    event VaultImplementationUpgraded(address newImplementation);
    event VaultUpgradesLocked();

    UpgradeableBeacon public immutable beacon;
    GlobalConfig public config;
    bool public upgradesLocked;

    constructor(GlobalConfig memory _config) {
        config = _config;
        beacon = new UpgradeableBeacon(address(new MyxVault()));
    }

    modifier onlyGuardian() {
        if (msg.sender != _getGuardian()) revert OnlyGuardian();
        _;
    }

    /// @inheritdoc IVaultFactory
    function newVault(address taxToken, address quoteToken, address creator, bytes calldata vaultData)
        external
        override
        returns (address vault)
    {
        if (msg.sender != _getVaultPortal()) revert OnlyVaultPortal();
        if (quoteToken != address(0)) revert UnsupportedQuoteToken();

        // vaultData carries the myx MARKET quote token (the token's dividendToken). The vault derives
        // the myx marketId from it on-chain (keccak256(chainId, quoteToken)); zero is rejected there.
        address marketQuoteToken = abi.decode(vaultData, (address));

        GlobalConfig memory c = config;
        vault = address(
            new BeaconProxy(
                address(beacon),
                abi.encodeCall(
                    MyxVault.initialize,
                    (
                        MyxVault.InitParams({
                            taxToken: taxToken,
                            creator: creator,
                            marketQuoteToken: marketQuoteToken,
                            poolManager: c.poolManager,
                            basePool: c.basePool,
                            maxSlippageBps: c.maxSlippageBps,
                            minProcessAmount: c.minProcessAmount
                        })
                    )
                )
            )
        );
        emit VaultCreated(vault, taxToken, creator, marketQuoteToken);
    }

    function isQuoteTokenSupported(address quoteToken) external pure override returns (bool) {
        return quoteToken == address(0); // native BNB only
    }

    /// @inheritdoc VaultFactoryBaseV2
    /// @dev v2.3: opts into Flap's resolveDividendToken flow. The token launches with
    ///      dividendToken = MAGIC_DIVIDEND_COMPUTED; VaultPortal predicts the tax token address
    ///      and calls resolveDividendToken to resolve the real dividend token.
    function factorySpecVersion() public pure override returns (string memory) {
        return "v2.3";
    }

    /// @inheritdoc IVaultFactoryDividendV23
    /// @notice Flap Spec v2.3 STATICCALL callback. Resolves MAGIC_DIVIDEND_COMPUTED to the myx
    ///         base-pool LP (mBase) so LP rebates flow to holders as the dividend asset.
    /// @dev    MUST-VERIFY: V6/V7 struct field order was rebuilt from the contract ABI (enums as
    ///         uint8, ABI-compatible). The symbol MUST equal the deployed tax token's on-chain
    ///         symbol() byte-for-byte, or the predicted LP address diverges — fund-critical.
    ///         LP prediction is delegated to myx PoolFactory.predictBasePoolToken — never recomputed here.
    function resolveDividendToken(address predictedToken, uint8 launchVersion, bytes calldata launchParams)
        external
        view
        override
        returns (address dividendToken)
    {
        if (launchVersion == DIVIDEND_TOKEN_LAUNCH_VERSION_V6) {
            IVaultPortalTypes.NewTokenV6WithVaultParamsU8 memory params =
                abi.decode(launchParams, (IVaultPortalTypes.NewTokenV6WithVaultParamsU8));
            require(params.dividendToken == MAGIC_DIVIDEND_COMPUTED, "expected V6 magic dividend");
            // The myx MARKET quote token travels in vaultData — NOT params.quoteToken (Flap bonding
            // quote = native BNB). MUST match newVault's marketQuoteToken source so the predicted LP
            // and the vault's actual myx pool share the same market — fund-critical.
            address marketQuote = abi.decode(params.vaultData, (address));
            MarketId marketId = MyxMarketId.derive(uint64(block.chainid), marketQuote);
            return IMyxPoolFactory(config.poolFactory).predictBasePoolToken(
                marketId, predictedToken, params.symbol
            );
        } else if (launchVersion == DIVIDEND_TOKEN_LAUNCH_VERSION_V7) {
            IVaultPortalTypes.NewTokenV7WithVaultParamsU8 memory params =
                abi.decode(launchParams, (IVaultPortalTypes.NewTokenV7WithVaultParamsU8));
            // V7 has no top-level dividendToken; the DIVIDEND fee slot (feeType == 2) carries it.
            bool found = false;
            for (uint256 i = 0; i < 4; i++) {
                if (params.feeConfigs[i].feeType == FEE_TYPE_DIVIDEND) {
                    require(
                        params.feeConfigs[i].dividendToken == MAGIC_DIVIDEND_COMPUTED,
                        "expected V7 magic dividend"
                    );
                    found = true;
                    break;
                }
            }
            require(found, "no V7 dividend feeConfig");
            // Same source as V6 and newVault: myx MARKET quote in vaultData, NOT params.quoteToken.
            address marketQuote = abi.decode(params.vaultData, (address));
            MarketId marketId = MyxMarketId.derive(uint64(block.chainid), marketQuote);
            return IMyxPoolFactory(config.poolFactory).predictBasePoolToken(
                marketId, predictedToken, params.symbol
            );
        } else {
            revert("unsupported launchVersion");
        }
    }

    /// @notice Pre-launch validation hook — ON-CHAIN enforcement (unlike tokenCreationPolicies,
    ///         which is UI-only). Rejects any launch that would brick process():
    ///         1. quoteToken must be native BNB (address(0))
    ///         2. dividendBps must be 0: Flap's native dividend dispatch would try to swap the BNB
    ///            tax share into the dividendToken (myx LP), but mBase is only mintable via myx
    ///            deposit — never swappable from BNB. The vault feeds LP itself from mktBps revenue.
    ///         3. dividendToken must be MAGIC_DIVIDEND_COMPUTED, resolved to mBase via resolveDividendToken.
    ///         Enforcement order: dividendBps before dividendToken because the Flap UI auto-fills
    ///         dividendToken when dividendBps == 0 — catching the mis-bps case first gives a clearer error.
    function _validateBeforeLaunch(IVaultFactoryValidationV2.LaunchValidationDataV1 memory data)
        internal
        view
        override
        returns (bool success, string memory reason)
    {
        if (data.quoteToken != address(0)) {
            return (false, unicode"Quote token must be native BNB / 報價幣必須為原生 BNB");
        }
        if (data.dividendBps != 0) {
            return (false, unicode"Dividend BPS must be 0 / 分紅 BPS 必須為 0");
        }
        if (data.dividendToken != MAGIC_DIVIDEND_COMPUTED) {
            return (false, unicode"Dividend token must be MAGIC_DIVIDEND_COMPUTED / 分紅幣必須設為 MAGIC_DIVIDEND_COMPUTED");
        }
        return (true, "");
    }

    /// @notice UI-discovery counterpart to _validateBeforeLaunch — INFORMATIONAL ONLY.
    ///         Lets the Flap UI surface/auto-fill required params.
    function tokenCreationPolicies() public pure override returns (FactoryPolicy[] memory policies) {
        policies = new FactoryPolicy[](3);
        policies[0] = FactoryPolicy({
            target: "dividendToken",
            operator: "eq",
            value: abi.encode(MAGIC_DIVIDEND_COMPUTED),
            description: unicode"Dividend token must be MAGIC_DIVIDEND_COMPUTED (resolved on-chain to myx LP). / 分紅幣必須設為 MAGIC_DIVIDEND_COMPUTED（由合約解析為 myx LP）。"
        });
        policies[1] = FactoryPolicy({
            target: "quoteToken",
            operator: "eq",
            value: abi.encode(address(0)),
            description: unicode"Quote token must be native BNB (address(0)). / 報價幣必須為原生 BNB（address(0)）。"
        });
        policies[2] = FactoryPolicy({
            target: "dividendBps",
            operator: "eq",
            value: abi.encode(uint256(0)),
            description: unicode"Dividend BPS must be 0; the vault feeds the myx LP directly. / 分紅 BPS 必須為 0；Vault 直接注入 myx LP。"
        });
    }

    function vaultDataSchema() public pure override returns (VaultDataSchema memory schema) {
        // vaultData carries the myx MARKET quote token (e.g. USDT/USDC): used only to derive the
        // myx marketId (keccak256(chainId, quoteToken)) and base pool on-chain. The dividend ASSET
        // is the myx LP (mBase) produced by depositing the bought-back tax token — not this token.
        // dividendToken is set to MAGIC_DIVIDEND_COMPUTED and resolved to mBase via resolveDividendToken.
        schema.description =
            unicode"myx market quote token (e.g. USDT/USDC) used to derive the myx pool. The reward is the resulting myx LP, not this token. / myx 市場報價幣（如 USDT/USDC），用於推導 myx 池。獎勵為產出的 myx LP，而非此幣。";
        schema.fields = new FieldDescriptor[](1);
        schema.fields[0] = FieldDescriptor(
            "quoteToken",
            "address",
            unicode"myx market quote token (e.g. USDT/USDC). Identifies the myx market; the reward is the myx LP. / myx 市場報價幣（如 USDT/USDC），用於識別 myx 市場；獎勵為 myx LP。",
            0
        );
        schema.isArray = false;
    }

    function upgradeVaultImplementation(address newImplementation) external onlyGuardian {
        if (upgradesLocked) revert UpgradesLocked();
        beacon.upgradeTo(newImplementation);
        emit VaultImplementationUpgraded(newImplementation);
    }

    function lockVaultUpgrades() external onlyGuardian {
        upgradesLocked = true;
        emit VaultUpgradesLocked();
    }
}
