// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.26;

import {VaultFactoryBaseV2} from "./flap/VaultFactoryBaseV2.sol";
import {IVaultFactory, IVaultFactoryValidationV2} from "./flap/IVaultFactory.sol";
import {VaultDataSchema, FieldDescriptor} from "./flap/IVaultSchemasV1.sol";
import {BeaconProxy} from "@openzeppelin/proxy/beacon/BeaconProxy.sol";
import {UpgradeableBeacon} from "@openzeppelin/proxy/beacon/UpgradeableBeacon.sol";
import {MyxVault} from "./MyxVault.sol";
import {MarketId} from "./myx/IMyxPool.sol";

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

    event VaultCreated(address indexed vault, address indexed taxToken, address indexed creator, MarketId marketId);
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

        MarketId marketId = abi.decode(vaultData, (MarketId));

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
                            marketId: marketId,
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
        emit VaultCreated(vault, taxToken, creator, marketId);
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
        schema.description = "MyxVault parameters: MYX market id. The token itself becomes the base asset.";
        schema.fields = new FieldDescriptor[](1);
        schema.fields[0] = FieldDescriptor("marketId", "bytes32", "MYX market identifier for the token's base pool", 0);
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
