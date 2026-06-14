// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.26;

import {VaultFactoryBaseV2} from "./flap/VaultFactoryBaseV2.sol";
import {IVaultFactory, IVaultFactoryValidationV2} from "./flap/IVaultFactory.sol";
import {VaultDataSchema, FieldDescriptor} from "./flap/IVaultSchemasV1.sol";
import {BeaconProxy} from "@openzeppelin/proxy/beacon/BeaconProxy.sol";
import {UpgradeableBeacon} from "@openzeppelin/proxy/beacon/UpgradeableBeacon.sol";
import {MyxVault} from "./MyxVault.sol";
import {MarketId, MyxMarketId, IMyxPoolFactory} from "./myx/IMyxPool.sol";

/// @title MyxVaultFactory
/// @notice Deploys MyxVault beacon proxies for the Flap VaultPortal. The factory itself is
///         non-upgradeable; vault implementation upgrades are Guardian-only via the beacon.
contract MyxVaultFactory is VaultFactoryBaseV2 {
    struct GlobalConfig {
        address poolManager;
        address basePool;
        address poolFactory; // myx PoolFactory: authoritative basePoolToken (LP / mBase) predictor
        uint16 maxSlippageBps;
        uint256 minProcessAmount;
    }

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

        // vaultData is the market quote token (= the token's dividendToken). The vault derives the
        // myx marketId from it on-chain (keccak256(chainId, quoteToken)); zero is rejected there.
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
    /// @dev v2.3: opts into the Flap `computeDividendToken` resolution flow. The launcher sets the
    ///      token's dividendToken to the MAGIC_DIVIDEND_COMPUTED sentinel; VaultPortal predicts the
    ///      tax token address and calls computeDividendToken(...) to resolve the real dividend token.
    function factorySpecVersion() public pure override returns (string memory) {
        return "v2.3";
    }

    /// @notice Flap Spec v2.3 callback. The token launches with dividendToken = MAGIC_DIVIDEND_COMPUTED;
    ///         VaultPortal predicts the tax token address and calls this to resolve the real dividend token.
    ///         We return the myx base-pool LP (mBase) address for (USDT-market, predictedToken), so LP
    ///         rebates flow to holders as the dividend asset.
    /// @dev    hint MUST carry the launch quoteToken and the tax token's symbol. ASSUMED ENCODING (confirm
    ///         against Flap v2.3 when released): abi.encode(address quoteToken, string symbol). The symbol
    ///         MUST equal the deployed tax token's on-chain symbol() byte-for-byte, else the predicted LP
    ///         address diverges from the real one (fund-critical — enforced upstream by Flap). Address math
    ///         is delegated to the myx PoolFactory's authoritative predictBasePoolToken — never recomputed here.
    function computeDividendToken(address predictedToken, bytes calldata hint) external view returns (address) {
        (address quoteToken, string memory symbol) = abi.decode(hint, (address, string));
        MarketId marketId = MyxMarketId.derive(uint64(block.chainid), quoteToken);
        return IMyxPoolFactory(config.poolFactory).predictBasePoolToken(marketId, predictedToken, symbol);
    }

    /// @notice Pre-launch validation hook (Flap VaultPortal calls this before token creation).
    /// @dev    v2.3: the token's dividendToken is the MAGIC_DIVIDEND_COMPUTED sentinel at validation time
    ///         (not a real ERC20) — it is resolved post-launch via computeDividendToken(...). We therefore
    ///         no longer inspect dividendToken here; only the BNB-quote constraint is enforced.
    function _validateBeforeLaunch(IVaultFactoryValidationV2.LaunchValidationDataV1 memory data)
        internal
        view
        override
        returns (bool success, string memory reason)
    {
        if (data.quoteToken != address(0)) {
            return (false, "MyxVaultFactory: only native BNB quote is supported");
        }
        return (true, "");
    }

    function vaultDataSchema() public pure override returns (VaultDataSchema memory schema) {
        schema.description =
            "MyxVault parameter: the myx MARKET quote token (e.g. USDT or USDC) used only to derive the "
            "myx market and base pool on-chain (marketId = keccak256(chainId, quoteToken)). The dividend "
            "ASSET is NOT this quote token: tax revenue is bought back into the token and deposited into "
            "that myx base pool, and the resulting myx LP (mBase) is itself the reward fed to holders. The "
            "token's dividendToken is set to the MAGIC_DIVIDEND_COMPUTED sentinel at launch and resolved to "
            "that mBase LP via computeDividendToken(...). Pass the ERC20 market quote token the myx pool uses.";
        schema.fields = new FieldDescriptor[](1);
        schema.fields[0] = FieldDescriptor(
            "quoteToken",
            "address",
            "myx market quote token (e.g. USDT or USDC). Used only to derive marketId = keccak256(chainId, "
            "quoteToken) and the base pool. The dividend asset is the resulting myx LP (mBase), resolved via "
            "computeDividendToken; it is NOT this quote token.",
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
