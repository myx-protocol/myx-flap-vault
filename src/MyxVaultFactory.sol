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
import {IPortalQuoteConfigU8} from "./flap/IPortalQuoteConfigU8.sol";
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
        /// @dev ERC20-quote launches must have at least this much BNB prepaid (wei). Enforced in newVault.
        uint256 minInitialGas;
    }

    /// @notice Creator-supplied per-vault configuration carried in `vaultData`.
    struct VaultData {
        address marketQuoteToken; // myx MARKET quote (USDT/USDC); identifies the myx market
        uint256 minProcessAmount; // quote base units
        uint256 gasThreshold; // wei; ERC20 quote only
        uint256 gasRefillAmount; // wei; ERC20 quote only, > gasThreshold
    }

    function decodeVaultData(bytes calldata vaultData) public pure returns (VaultData memory d) {
        (d.marketQuoteToken, d.minProcessAmount, d.gasThreshold, d.gasRefillAmount) =
            abi.decode(vaultData, (address, uint256, uint256, uint256));
    }

    /// @dev Flap Portal per chain. Mirrors VaultBase._getPortal(); unknown chains revert.
    function _getPortal() internal view returns (address) {
        uint256 chainId = block.chainid;
        if (chainId == 56) return 0xe2cE6ab80874Fa9Fa2aAE65D277Dd6B8e65C9De0;
        if (chainId == 97) return 0x5bEacaF7ABCbB3aB280e80D007FD31fcE26510e9;
        if (chainId == 4663) return 0x26605f322f7fF986f381bB9A6e3f5DAb0bEaEb09;
        revert UnsupportedChain(chainId);
    }

    /// @notice BNB prepaid per creator, forwarded into their vault's gas pool at ERC20-quote launch.
    ///         Extra msg.value on the launch transaction itself is swallowed by the Flap Portal, so the
    ///         initial gas pool must be funded through this separate call before launching.
    mapping(address => uint256) public prepaidGas;

    event GasPrepaid(address indexed account, uint256 amount, uint256 total);
    event PrepaidGasWithdrawn(address indexed account, uint256 amount);
    event VaultGasFunded(address indexed vault, address indexed creator, uint256 amount);

    function prepayGas() external payable {
        require(msg.value > 0, unicode"Zero prepayment / 預付金額為零");
        prepaidGas[msg.sender] += msg.value;
        emit GasPrepaid(msg.sender, msg.value, prepaidGas[msg.sender]);
    }

    function withdrawPrepaidGas() external {
        uint256 amount = prepaidGas[msg.sender];
        require(amount > 0, unicode"Nothing prepaid / 無預付款");
        prepaidGas[msg.sender] = 0;
        (bool ok,) = msg.sender.call{value: amount}("");
        require(ok, unicode"Refund failed / 退款失敗");
        emit PrepaidGasWithdrawn(msg.sender, amount);
    }

    /// @notice FeeType.DIVIDEND == 2; identifies the dividend fee slot in V7 feeConfigs.
    uint8 internal constant FEE_TYPE_DIVIDEND = 2;

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
        require(msg.sender == _getGuardian(), unicode"Caller must be the guardian / 僅限守護者調用");
        _;
    }

    /// @inheritdoc IVaultFactory
    function newVault(address taxToken, address quoteToken, address creator, bytes calldata vaultData)
        external
        override
        returns (address vault)
    {
        require(msg.sender == _getVaultPortal(), unicode"Caller must be the vault portal / 僅限 VaultPortal 調用");
        VaultData memory d = decodeVaultData(vaultData);
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
                            quoteToken: quoteToken,
                            marketQuoteToken: d.marketQuoteToken,
                            poolManager: c.poolManager,
                            basePool: c.basePool,
                            maxSlippageBps: c.maxSlippageBps,
                            minProcessAmount: d.minProcessAmount,
                            gasThreshold: d.gasThreshold,
                            gasRefillAmount: d.gasRefillAmount
                        })
                    )
                )
            )
        );
        if (quoteToken != address(0)) {
            uint256 prepaid = prepaidGas[creator];
            require(prepaid >= c.minInitialGas, unicode"Prepaid gas below minimum / 預付 Gas 低於最低要求");
            if (prepaid > 0) {
                prepaidGas[creator] = 0;
                MyxVault(payable(vault)).fundGas{value: prepaid}();
                emit VaultGasFunded(vault, creator, prepaid);
            }
        }
        emit VaultCreated(vault, taxToken, creator, d.marketQuoteToken);
    }

    /// @inheritdoc IVaultFactory
    /// @dev Native always. ERC20 only where the vault's refill leg is wired (BSC mainnet/testnet) and
    ///      the Portal has the quote enabled. Robinhood stays native-only in this release.
    function isQuoteTokenSupported(address quoteToken) external view override returns (bool) {
        if (quoteToken == address(0)) return true;
        uint256 chainId = block.chainid;
        if (chainId != 56 && chainId != 97) return false;
        return IPortalQuoteConfigU8(_getPortal()).getQuoteTokenConfiguration(quoteToken).enabled == 1;
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
            require(params.dividendToken == MAGIC_DIVIDEND_COMPUTED, unicode"Expected V6 MAGIC dividend token / 預期 V6 MAGIC 分紅幣");
            // The myx MARKET quote token travels in vaultData — NOT params.quoteToken (Flap bonding
            // quote = native ETH). MUST match newVault's marketQuoteToken source so the predicted LP
            // and the vault's actual myx pool share the same market — fund-critical.
            (address marketQuote,,,) = abi.decode(params.vaultData, (address, uint256, uint256, uint256));
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
                        unicode"Expected V7 MAGIC dividend token / 預期 V7 MAGIC 分紅幣"
                    );
                    found = true;
                    break;
                }
            }
            require(found, unicode"No V7 dividend feeConfig / 無 V7 分紅費用配置");
            // Same source as V6 and newVault: myx MARKET quote in vaultData, NOT params.quoteToken.
            (address marketQuote,,,) = abi.decode(params.vaultData, (address, uint256, uint256, uint256));
            MarketId marketId = MyxMarketId.derive(uint64(block.chainid), marketQuote);
            return IMyxPoolFactory(config.poolFactory).predictBasePoolToken(
                marketId, predictedToken, params.symbol
            );
        } else {
            revert(unicode"Unsupported launch version / 不支援的發行版本");
        }
    }

    /// @notice Pre-launch validation hook — ON-CHAIN enforcement (unlike tokenCreationPolicies,
    ///         which is UI-only). Rejects any launch that would brick process():
    ///         1. dividendBps must be 0: Flap's native dividend dispatch would try to swap the tax
    ///            share into the dividendToken (myx LP), but mBase is only mintable via myx
    ///            deposit — never swappable from the quote token. The vault feeds LP itself from
    ///            mktBps revenue.
    ///         2. dividendToken must be MAGIC_DIVIDEND_COMPUTED, resolved to mBase via resolveDividendToken.
    ///         Enforcement order: dividendBps before dividendToken because the Flap UI auto-fills
    ///         dividendToken when dividendBps == 0 — catching the mis-bps case first gives a clearer error.
    ///         Quote token itself is validated separately, off-chain, via isQuoteTokenSupported.
    function _validateBeforeLaunch(IVaultFactoryValidationV2.LaunchValidationDataV1 memory data)
        internal
        view
        override
        returns (bool success, string memory reason)
    {
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
        policies = new FactoryPolicy[](2);
        policies[0] = FactoryPolicy({
            target: "dividendToken",
            operator: "eq",
            value: abi.encode(MAGIC_DIVIDEND_COMPUTED),
            description: unicode"Dividend token must be MAGIC_DIVIDEND_COMPUTED (resolved on-chain to myx LP). / 分紅幣必須設為 MAGIC_DIVIDEND_COMPUTED（由合約解析為 myx LP）。"
        });
        policies[1] = FactoryPolicy({
            target: "dividendBps",
            operator: "eq",
            value: abi.encode(uint256(0)),
            description: unicode"Dividend BPS must be 0; the vault feeds the myx LP directly. / 分紅 BPS 必須為 0；Vault 直接注入 myx LP。"
        });
    }

    function vaultDataSchema() public pure override returns (VaultDataSchema memory schema) {
        schema.description =
            unicode"myx market quote token (e.g. USDT/USDC) plus this vault's thresholds. The reward is the resulting myx LP. / myx 市場報價幣（如 USDT/USDC）與本金庫的閾值設定。獎勵為產出的 myx LP。";
        schema.fields = new FieldDescriptor[](4);
        schema.fields[0] = FieldDescriptor(
            "marketQuoteToken", "address", unicode"myx market quote token (e.g. USDT/USDC). / myx 市場報價幣（如 USDT/USDC）。", 0
        );
        schema.fields[1] = FieldDescriptor(
            "minProcessAmount",
            "uint256",
            unicode"Minimum tax (in the launch quote token's smallest unit) before a buyback runs. / 執行回購前的最低稅收（以發行報價幣最小單位計）。",
            0
        );
        schema.fields[2] = FieldDescriptor(
            "gasThreshold",
            "uint256",
            unicode"ERC20 quote only: refill the BNB gas pool below this balance. 0 for native quote. / 僅 ERC20 報價幣：Gas 池低於此值時補充。原生報價幣填 0。",
            18
        );
        schema.fields[3] = FieldDescriptor(
            "gasRefillAmount",
            "uint256",
            unicode"ERC20 quote only: gas pool target after a refill, must exceed gasThreshold. 0 for native quote. / 僅 ERC20 報價幣：補充後的 Gas 池目標，須大於閾值。原生報價幣填 0。",
            18
        );
        schema.isArray = false;
    }

    function upgradeVaultImplementation(address newImplementation) external onlyGuardian {
        require(!upgradesLocked, unicode"Upgrades are locked / 升級已鎖定");
        beacon.upgradeTo(newImplementation);
        emit VaultImplementationUpgraded(newImplementation);
    }

    function lockVaultUpgrades() external onlyGuardian {
        upgradesLocked = true;
        emit VaultUpgradesLocked();
    }
}
