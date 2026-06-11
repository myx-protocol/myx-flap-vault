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
import {IFlapTaxTokenV3} from "./flap/IFlapTaxTokenV3.sol";

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
        uint32 maxPriceStaleness; // max seconds since a Chainlink feed update before it is rejected
    }

    bytes32 public constant EMERGENCY_ROLE = keccak256("EMERGENCY_ROLE");
    uint16 public constant BPS_DENOMINATOR = 10_000;
    uint256 public constant SWAP_DEADLINE = 300; // seconds; bounds validator tx-holding window

    error CannotRevokeGuardianRole();
    error BelowMinimumProcessAmount(uint256 pending, uint256 minimum);
    error StalePrice(address feed);
    error MarketNotInitialized();
    error DividendDepositFailed();
    error ZeroDividendContract();

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
    uint32 public maxPriceStaleness;

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
        maxPriceStaleness = p.maxPriceStaleness;

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

    /// @dev Uses a direct [WBNB, baseToken] PancakeV2 path. The factory MUST only admit base
    ///      tokens that have a liquid direct WBNB pair; tokens routed via an intermediate would
    ///      make the feed-derived minOut revert every call. Multi-hop path support is future work.
    /// @dev BNB → baseToken. WBNB base: pure wrap. Other bases: wrap then swap via PancakeV2.
    ///      minOut is derived from Chainlink feeds; slippage guard is never caller-supplied.
    function _toBaseToken(uint256 bnbAmount) internal returns (uint256 baseAmount) {
        wbnb.deposit{value: bnbAmount}();
        if (baseToken == address(wbnb)) {
            return bnbAmount;
        }
        // fair amount from feeds: base = bnbAmount * (BNB/USD) / (BASE/USD); both feeds 8 dec, tokens 18 dec
        uint256 bnbUsd = _readPrice(bnbUsdFeed);
        uint256 baseUsd = _readPrice(baseTokenUsdFeed);
        uint256 fairOut = (bnbAmount * bnbUsd) / baseUsd;
        uint256 minOut = (fairOut * (BPS_DENOMINATOR - maxSlippageBps)) / BPS_DENOMINATOR;

        address[] memory path = new address[](2);
        path[0] = address(wbnb);
        path[1] = baseToken;
        IERC20(address(wbnb)).safeIncreaseAllowance(address(swapRouter), bnbAmount);
        uint256[] memory amounts =
            swapRouter.swapExactTokensForTokens(bnbAmount, minOut, path, address(this), block.timestamp + SWAP_DEADLINE);
        baseAmount = amounts[amounts.length - 1];
    }

    function _readPrice(IAggregatorV3 feed) internal view returns (uint256) {
        (uint80 roundId, int256 answer,, uint256 updatedAt, uint80 answeredInRound) = feed.latestRoundData();
        if (answer <= 0) revert StalePrice(address(feed));
        if (answeredInRound < roundId) revert StalePrice(address(feed));
        if (block.timestamp - updatedAt > maxPriceStaleness) revert StalePrice(address(feed));
        return uint256(answer);
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

    /// @notice Claims accumulated LP rebates and forwards them to the token's native
    ///         Dividend contract as WBNB. Permissionless; minOut is feed-priced internally.
    function harvest() external nonReentrant {
        basePool.claimUserRebate(poolId, address(this), address(this));
        // Use the full USDT balance (not just this claim's return value) so any dust left by a
        // prior dust-skipped harvest is swept once it becomes economic. The only USDT path into
        // this vault is rebate claims; forwarding it to holders is the vault's purpose.
        uint256 usdtBalance = quoteToken.balanceOf(address(this));
        if (usdtBalance == 0) return;

        // fair WBNB out = usdt * (USDT/USD) / (BNB/USD); both feeds 8 dec, tokens 18 dec
        uint256 usdtUsd = _readPrice(usdtUsdFeed);
        uint256 bnbUsd = _readPrice(bnbUsdFeed);
        uint256 fairOut = (usdtBalance * usdtUsd) / bnbUsd;
        // dust below 1 wei WBNB-equivalent would yield minOut == 0 (no slippage floor);
        // retain it in the vault until the next harvest accumulates an economic amount.
        if (fairOut == 0) return;
        uint256 minOut = (fairOut * (BPS_DENOMINATOR - maxSlippageBps)) / BPS_DENOMINATOR;

        address[] memory path = new address[](2);
        path[0] = address(quoteToken);
        path[1] = address(wbnb);
        quoteToken.safeIncreaseAllowance(address(swapRouter), usdtBalance);
        uint256[] memory amounts =
            swapRouter.swapExactTokensForTokens(usdtBalance, minOut, path, address(this), block.timestamp + SWAP_DEADLINE);
        uint256 wbnbOut = amounts[amounts.length - 1];

        _forwardToDividend(wbnbOut);
        totalRewardsForwarded += wbnbOut;
        emit Harvested(usdtBalance, wbnbOut);
    }

    /// @dev Verified ABI (docs/phase0-findings.md): deposit() is approve+pull and returns
    ///      false on failure WITHOUT reverting (e.g. totalShares == 0) — must be checked so
    ///      a failed forward reverts the harvest and funds stay in the vault for retry.
    function _forwardToDividend(uint256 wbnbAmount) internal {
        // Resolved live (not cached): the taxToken does not exist at initialize() time
        // (CREATE2 predicted address), so its dividendContract() cannot be read then.
        address dividendAddr = IFlapTaxTokenV3(taxToken).dividendContract();
        if (dividendAddr == address(0)) revert ZeroDividendContract();
        IERC20(address(wbnb)).safeIncreaseAllowance(dividendAddr, wbnbAmount);
        if (!IDividendDistributor(dividendAddr).deposit(wbnbAmount)) revert DividendDepositFailed();
    }

    /// @notice Redeems vault-held LP back to quote token, sent to `to`. Disaster recovery only.
    function emergencyWithdraw(uint256 lpAmount, uint256 minAmountOut, address to)
        external
        nonReentrant
        onlyRole(EMERGENCY_ROLE)
    {
        (uint256 amountOut,) = basePool.withdraw(poolId, lpAmount, minAmountOut, address(this), to);
        emit EmergencyWithdrawal(lpAmount, amountOut, to);
    }

    /// @notice Sweeps stuck native BNB. Disaster recovery only (e.g. processRevenue permanently broken).
    function emergencySweepBnb(address to) external nonReentrant onlyRole(EMERGENCY_ROLE) {
        uint256 amount = address(this).balance;
        pendingBnb = 0;
        (bool ok,) = to.call{value: amount}("");
        require(ok, "BNB_SWEEP_FAILED");
        emit EmergencySwept(amount, to);
    }

    // ── implemented in later tasks ──
    function description() public view virtual override returns (string memory) {
        return "MyxVault";
    }

    function vaultUISchema() public pure virtual override returns (VaultUISchema memory schema) {
        schema.vaultType = "MyxVault";
    }
}
