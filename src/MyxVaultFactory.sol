// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.26;

import {VaultFactoryBaseV2} from "./flap/VaultFactoryBaseV2.sol";
import {IVaultFactory, IVaultFactoryValidationV2} from "./flap/IVaultFactory.sol";
import {VaultDataSchema, FieldDescriptor} from "./flap/IVaultSchemasV1.sol";
import {BeaconProxy} from "@openzeppelin/proxy/beacon/BeaconProxy.sol";
import {UpgradeableBeacon} from "@openzeppelin/proxy/beacon/UpgradeableBeacon.sol";
import {MyxVault} from "./MyxVault.sol";

/// @title MyxVaultFactory
/// @notice Deploys MyxVault beacon proxies for the Flap VaultPortal. The factory itself is
///         non-upgradeable; vault implementation upgrades are Guardian-only via the beacon.
contract MyxVaultFactory is VaultFactoryBaseV2 {
    struct GlobalConfig {
        address poolManager;
        address basePool;
        uint16 maxSlippageBps;
        uint256 minProcessAmount;
        address triggerService;
        uint64 triggerInterval;
    }

    error UnsupportedQuoteToken();
    error OnlyGuardian();
    error UpgradesLocked();

    /// @dev Flap "self-dividend" sentinel: a token configured to distribute ITSELF as the dividend.
    ///      Our myx pool distributes its quote token as the reward, so the dividendToken must be a
    ///      real ERC20 we can match to a myx market quote — the self magic is incompatible.
    address internal constant MAGIC_DIVIDEND_SELF = 0xfEEDFEEDfeEDFEedFEEdFEEDFeEdfEEdFeEdFEEd;

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
                            minProcessAmount: c.minProcessAmount,
                            triggerService: c.triggerService,
                            triggerInterval: c.triggerInterval
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

    /// @notice Pre-launch validation hook (Flap VaultPortal calls this before token creation).
    function _validateBeforeLaunch(IVaultFactoryValidationV2.LaunchValidationDataV1 memory data)
        internal
        view
        override
        returns (bool success, string memory reason)
    {
        if (data.quoteToken != address(0)) {
            return (false, "MyxVaultFactory: only native BNB quote is supported");
        }
        // Our myx pool distributes its quote token as the reward, so the token's dividendToken
        // must be a real ERC20 we can match to a myx market quote — not native BNB (address(0))
        // and not the "self" magic (distribute the tax token itself). Exact dividendToken<->market
        // consistency is enforced at runtime in the vault (pool.quoteToken == dividend.dividendToken()).
        if (data.dividendToken == address(0)) {
            return (false, "MyxVaultFactory: native BNB dividend not supported; use an ERC20 (USDT/USDC)");
        }
        if (data.dividendToken == MAGIC_DIVIDEND_SELF) {
            return (false, "MyxVaultFactory: self-dividend not supported");
        }
        return (true, "");
    }

    function vaultDataSchema() public pure override returns (VaultDataSchema memory schema) {
        schema.description =
            "MyxVault parameter: the myx market quote token, which MUST equal this token's dividendToken "
            "(USDT or USDC). The vault derives the myx market and base pool from it on-chain, so LP rebates "
            "(paid in this quote token) distribute to holders directly. Pass the same ERC20 address you set "
            "as the token's dividendToken.";
        schema.fields = new FieldDescriptor[](1);
        schema.fields[0] = FieldDescriptor(
            "quoteToken",
            "address",
            "ERC20 quote/dividend token (e.g. USDT or USDC). Must equal the token's dividendToken; the vault "
            "derives marketId = keccak256(chainId, quoteToken) and the base pool from it.",
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
