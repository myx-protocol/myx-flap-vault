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
        address swapRouter;
        address wbnb;
        address quoteToken;
        address bnbUsdFeed;
        address usdtUsdFeed;
        uint16 maxSlippageBps;
        uint256 minProcessAmount;
        uint32 maxPriceStaleness;
    }

    error UnsupportedBaseToken();
    error UnsupportedQuoteToken();
    error OnlyGuardian();
    error UpgradesLocked();
    error ConfigLengthMismatch();

    event VaultCreated(address indexed vault, address indexed taxToken, address indexed creator, address baseToken);
    event VaultImplementationUpgraded(address newImplementation);
    event VaultUpgradesLocked();

    UpgradeableBeacon public immutable beacon;
    GlobalConfig public config;
    /// @dev base token => Chainlink USD feed (address(0) allowed only for WBNB). Constructor-fixed.
    mapping(address => address) public baseTokenFeeds;
    mapping(address => bool) public isSupportedBaseToken;
    bool public upgradesLocked;

    constructor(GlobalConfig memory _config, address[] memory baseTokens, address[] memory feeds) {
        if (baseTokens.length != feeds.length) revert ConfigLengthMismatch();
        config = _config;
        for (uint256 i = 0; i < baseTokens.length; i++) {
            isSupportedBaseToken[baseTokens[i]] = true;
            baseTokenFeeds[baseTokens[i]] = feeds[i];
        }
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

        (address baseToken, MarketId marketId) = abi.decode(vaultData, (address, MarketId));
        if (!isSupportedBaseToken[baseToken]) revert UnsupportedBaseToken();

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
                            baseToken: baseToken,
                            marketId: marketId,
                            poolManager: c.poolManager,
                            basePool: c.basePool,
                            swapRouter: c.swapRouter,
                            wbnb: c.wbnb,
                            quoteToken: c.quoteToken,
                            bnbUsdFeed: c.bnbUsdFeed,
                            usdtUsdFeed: c.usdtUsdFeed,
                            baseTokenUsdFeed: baseTokenFeeds[baseToken],
                            maxSlippageBps: c.maxSlippageBps,
                            minProcessAmount: c.minProcessAmount,
                            maxPriceStaleness: c.maxPriceStaleness
                        })
                    )
                )
            )
        );
        emit VaultCreated(vault, taxToken, creator, baseToken);
    }

    function isQuoteTokenSupported(address quoteToken) external pure override returns (bool) {
        return quoteToken == address(0); // native BNB only
    }

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
        schema.description = "MyxVault parameters: target base token and MYX market id.";
        schema.fields = new FieldDescriptor[](2);
        schema.fields[0] =
            FieldDescriptor("baseToken", "address", "Base asset for MYX liquidity (must be factory-supported)", 0);
        schema.fields[1] = FieldDescriptor("marketId", "bytes32", "MYX market identifier", 0);
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
