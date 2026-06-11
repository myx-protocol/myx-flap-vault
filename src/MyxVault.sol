// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.26;

import {VaultBaseV2} from "./flap/VaultBaseV2.sol";
import {VaultUISchema} from "./flap/IVaultSchemasV1.sol";
import {Initializable} from "@openzeppelin-contracts-upgradeable/proxy/utils/Initializable.sol";
import {AccessControlUpgradeable} from "@openzeppelin-contracts-upgradeable/access/AccessControlUpgradeable.sol";
import {ReentrancyGuardUpgradeable} from "@openzeppelin-contracts-upgradeable/security/ReentrancyGuardUpgradeable.sol";
import {IERC20} from "@openzeppelin/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/token/ERC20/utils/SafeERC20.sol";
import {MarketId, PoolId, MyxPoolId, PoolMetadata, IMyxPoolManager, IMyxBasePool} from "./myx/IMyxPool.sol";
import {IPancakeRouterV2} from "./dex/IPancakeRouterV2.sol";
import {IWBNB} from "./dex/IWBNB.sol";
import {IAggregatorV3} from "./oracle/IAggregatorV3.sol";
import {IDividendDistributor} from "./dividend/IDividendDistributor.sol";

/// @title MyxVault
/// @notice Flap vault that deposits tax revenue as MYX base-pool liquidity (LP held by
///         the vault) and forwards harvested rebates to the token's Dividend contract.
/// @dev Invariants:
///      - receive() performs accounting only (Flap Rule 005), never external calls.
///      - All swap minOut values are derived from Chainlink feeds inside the contract.
///      - Guardian roles cannot be revoked by any other account; only the guardian
///        itself may voluntarily renounce (Flap mandate).
contract MyxVault is VaultBaseV2, Initializable, AccessControlUpgradeable, ReentrancyGuardUpgradeable {
    using SafeERC20 for IERC20;

    struct InitParams {
        address taxToken;
        address creator;
        address baseToken;
        MarketId marketId;
        address poolManager;
        address basePool;
        address swapRouter;
        address wbnb;
        address quoteToken;
        address bnbUsdFeed;
        address usdtUsdFeed;
        address baseTokenUsdFeed; // address(0) when baseToken == WBNB
        uint16 maxSlippageBps;
        uint256 minProcessAmount;
    }

    bytes32 public constant EMERGENCY_ROLE = keccak256("EMERGENCY_ROLE");
    uint16 public constant BPS_DENOMINATOR = 10_000;

    error CannotRevokeGuardianRole();
    error BelowMinimumProcessAmount(uint256 pending, uint256 minimum);
    error StalePrice(address feed);
    error MarketNotInitialized();
    error DividendDepositFailed();

    event RevenueReceived(uint256 amount, uint256 pendingTotal);
    event RevenueProcessed(uint256 bnbAmount, uint256 baseAmount, uint256 lpMinted);
    event PoolDeployed(PoolId poolId);
    event Harvested(uint256 rebateAmount, uint256 wbnbForwarded);
    event EmergencyWithdrawal(uint256 lpAmount, uint256 amountOut, address to);
    event EmergencySwept(uint256 bnbAmount, address to);

    address public taxToken;
    address public creator;
    address public baseToken;
    MarketId public marketId;
    PoolId public poolId;
    IMyxPoolManager public poolManager;
    IMyxBasePool public basePool;
    IPancakeRouterV2 public swapRouter;
    IWBNB public wbnb;
    IERC20 public quoteToken;
    IAggregatorV3 public bnbUsdFeed;
    IAggregatorV3 public usdtUsdFeed;
    IAggregatorV3 public baseTokenUsdFeed;
    uint16 public maxSlippageBps;
    uint256 public minProcessAmount;

    uint256 public pendingBnb;
    uint256 public totalLpMinted;
    uint256 public totalRewardsForwarded;

    /// @dev Reserved storage to allow inserting parent mixins or new variables in upgrades.
    uint256[35] private __gap;

    constructor() {
        _disableInitializers();
    }

    function initialize(InitParams calldata p) external initializer {
        __AccessControl_init();
        __ReentrancyGuard_init();

        taxToken = p.taxToken;
        creator = p.creator;
        baseToken = p.baseToken;
        marketId = p.marketId;
        poolId = MyxPoolId.derive(p.marketId, p.baseToken);
        poolManager = IMyxPoolManager(p.poolManager);
        basePool = IMyxBasePool(p.basePool);
        swapRouter = IPancakeRouterV2(p.swapRouter);
        wbnb = IWBNB(p.wbnb);
        quoteToken = IERC20(p.quoteToken);
        bnbUsdFeed = IAggregatorV3(p.bnbUsdFeed);
        usdtUsdFeed = IAggregatorV3(p.usdtUsdFeed);
        baseTokenUsdFeed = IAggregatorV3(p.baseTokenUsdFeed);
        maxSlippageBps = p.maxSlippageBps;
        minProcessAmount = p.minProcessAmount;

        address guardian = _getGuardian();
        _grantRole(DEFAULT_ADMIN_ROLE, guardian);
        _grantRole(EMERGENCY_ROLE, guardian);
        _grantRole(EMERGENCY_ROLE, p.creator);
    }

    /// @dev Flap Rule 005: accounting only. No external calls, no loops, never reverts.
    receive() external payable {
        pendingBnb += msg.value;
        emit RevenueReceived(msg.value, pendingBnb);
    }

    /// @dev Flap mandate: the Guardian role must not be revocable by anyone else.
    function revokeRole(bytes32 role, address account) public override onlyRole(getRoleAdmin(role)) {
        if (account == _getGuardian()) revert CannotRevokeGuardianRole();
        super.revokeRole(role, account);
    }

    /// @notice Converts accumulated BNB into base-pool liquidity. Permissionless by design;
    ///         MEV protection comes from internally computed swap minOut (never caller input).
    function processRevenue() external nonReentrant {
        uint256 amount = pendingBnb;
        if (amount < minProcessAmount) revert BelowMinimumProcessAmount(amount, minProcessAmount);
        pendingBnb = 0;

        uint256 baseAmount = _toBaseToken(amount);
        _ensurePoolExists();

        IERC20(baseToken).safeIncreaseAllowance(address(basePool), baseAmount);
        // minAmountOut = 0: LP mint is oracle-priced upstream (no AMM spot to sandwich);
        // the swap leg in _toBaseToken carries the slippage protection.
        uint256 lpOut = basePool.deposit(poolId, baseAmount, 0, address(this), address(this));
        totalLpMinted += lpOut;

        emit RevenueProcessed(amount, baseAmount, lpOut);
    }

    /// @dev BNB → baseToken. WBNB base: pure wrap. Other bases: wrap then swap (later task).
    function _toBaseToken(uint256 bnbAmount) internal returns (uint256 baseAmount) {
        wbnb.deposit{value: bnbAmount}();
        if (baseToken == address(wbnb)) {
            return bnbAmount;
        }
        revert("SWAP_PATH_NOT_IMPLEMENTED"); // replaced in a later task
    }

    function _ensurePoolExists() internal {
        PoolMetadata memory pool = poolManager.getPool(poolId);
        // basePoolToken is the definitive deposit-readiness signal: myx deployPool
        // atomically deploys the LP token, so a registered pool always has it set.
        if (pool.basePoolToken == address(0)) {
            poolManager.deployPool(IMyxPoolManager.DeployPoolParams({marketId: marketId, baseToken: baseToken}));
            emit PoolDeployed(poolId);
        }
    }

    // ── implemented in later tasks ──
    function description() public view virtual override returns (string memory) {
        return "MyxVault";
    }

    function vaultUISchema() public pure virtual override returns (VaultUISchema memory schema) {
        schema.vaultType = "MyxVault";
    }
}
