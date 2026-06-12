// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.26;

import {VaultBaseV2} from "./flap/VaultBaseV2.sol";
import {VaultUISchema, VaultMethodSchema, FieldDescriptor} from "./flap/IVaultSchemasV1.sol";
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
import {IPortalTradeV2} from "./flap/IPortal.sol";
import {Strings} from "@openzeppelin/utils/Strings.sol";

/// @title MyxVault
/// @notice Flap vault that buys back the tax token with tax revenue via the Flap Portal,
///         deposits it as MYX base-pool liquidity (LP held by the vault) and forwards
///         harvested rebates to the token's Dividend contract.
/// @dev Invariants:
///      - receive() performs accounting only (Flap Rule 005), never external calls.
///      - harvest swap minOut is derived from Chainlink feeds inside the contract; the
///        buyback leg has no feed and is bounded only by a same-block Portal quote. The
///        processRevenue trigger is mode-gated: AUTO (default) is permissionless so a keeper
///        can run it automatically; MANUAL restricts it to OPERATOR_ROLE. setMode is
///        creator/Guardian-only.
///      - Guardian roles cannot be revoked by any other account; only the guardian
///        itself may voluntarily renounce (Flap mandate).
contract MyxVault is VaultBaseV2, Initializable, AccessControlUpgradeable, ReentrancyGuardUpgradeable {
    using SafeERC20 for IERC20;

    struct InitParams {
        address taxToken;
        address creator;
        MarketId marketId;
        address poolManager;
        address basePool;
        address swapRouter;
        address wbnb;
        address quoteToken;
        address bnbUsdFeed;
        address usdtUsdFeed;
        uint16 maxSlippageBps;
        uint256 minProcessAmount;
        uint32 maxPriceStaleness; // max seconds since a Chainlink feed update before it is rejected
    }

    bytes32 public constant EMERGENCY_ROLE = keccak256("EMERGENCY_ROLE");
    bytes32 public constant OPERATOR_ROLE = keccak256("OPERATOR_ROLE");
    uint16 public constant BPS_DENOMINATOR = 10_000;
    uint256 public constant SWAP_DEADLINE = 300; // seconds; bounds validator tx-holding window (harvest)

    error CannotRevokeGuardianRole();
    error BelowMinimumProcessAmount(uint256 pending, uint256 minimum);
    error StalePrice(address feed);
    error DividendDepositFailed();
    error ZeroDividendContract();
    error ZeroQuote();
    error NotAuthorizedInManualMode();
    error NotModeAdmin();

    event RevenueReceived(uint256 amount, uint256 pendingTotal);
    event ModeChanged(Mode newMode);
    event RevenueProcessed(uint256 bnbAmount, uint256 baseAmount, uint256 lpMinted);
    event PoolDeployed(PoolId poolId);
    event Harvested(uint256 rebateAmount, uint256 wbnbForwarded);
    event EmergencyWithdrawal(uint256 lpAmount, uint256 amountOut, address to);
    event EmergencySwept(uint256 bnbAmount, address to);

    address public taxToken;
    address public creator;
    MarketId public marketId;
    PoolId public poolId;
    IMyxPoolManager public poolManager;
    IMyxBasePool public basePool;
    IPancakeRouterV2 public swapRouter;
    IWBNB public wbnb;
    IERC20 public quoteToken;
    IAggregatorV3 public bnbUsdFeed;
    IAggregatorV3 public usdtUsdFeed;
    uint16 public maxSlippageBps;
    uint256 public minProcessAmount;
    uint32 public maxPriceStaleness;

    enum Mode { AUTO, MANUAL }

    uint256 public pendingBnb;
    uint256 public totalLpMinted;
    uint256 public totalRewardsForwarded;
    Mode public mode;

    /// @dev Reserved storage to allow inserting parent mixins or new variables in upgrades.
    uint256[36] private __gap;

    constructor() {
        _disableInitializers();
    }

    function initialize(InitParams calldata p) external initializer {
        __AccessControl_init();
        __ReentrancyGuard_init();

        taxToken = p.taxToken;
        creator = p.creator;
        marketId = p.marketId;
        poolId = MyxPoolId.derive(p.marketId, p.taxToken);
        poolManager = IMyxPoolManager(p.poolManager);
        basePool = IMyxBasePool(p.basePool);
        swapRouter = IPancakeRouterV2(p.swapRouter);
        wbnb = IWBNB(p.wbnb);
        quoteToken = IERC20(p.quoteToken);
        bnbUsdFeed = IAggregatorV3(p.bnbUsdFeed);
        usdtUsdFeed = IAggregatorV3(p.usdtUsdFeed);
        maxSlippageBps = p.maxSlippageBps;
        minProcessAmount = p.minProcessAmount;
        maxPriceStaleness = p.maxPriceStaleness;

        address guardian = _getGuardian();
        _grantRole(DEFAULT_ADMIN_ROLE, guardian);
        _grantRole(EMERGENCY_ROLE, guardian);
        _grantRole(EMERGENCY_ROLE, p.creator);
        _grantRole(OPERATOR_ROLE, guardian);
        _grantRole(OPERATOR_ROLE, p.creator);

        // BeaconProxy storage is zero so AUTO=0 is already the default; set explicitly for readability.
        mode = Mode.AUTO;
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

    /// @notice Converts accumulated BNB into MYX base-pool liquidity by buying back the tax
    ///         token via the Flap Portal. In AUTO mode this is permissionless (a keeper makes
    ///         it effectively automatic); in MANUAL mode only OPERATOR_ROLE may call it. The
    ///         buy leg's minOut is a same-block Portal quote (no Chainlink feed exists for the
    ///         tax token), which cannot prevent sandwiches on its own — in MANUAL mode the
    ///         caller gate is the protection.
    function processRevenue() external nonReentrant {
        if (mode == Mode.MANUAL && !hasRole(OPERATOR_ROLE, msg.sender)) {
            revert NotAuthorizedInManualMode();
        }
        uint256 amount = pendingBnb;
        if (amount < minProcessAmount) revert BelowMinimumProcessAmount(amount, minProcessAmount);
        pendingBnb = 0;

        uint256 received = _buyTaxToken(amount);
        _ensurePoolExists();

        IERC20(taxToken).forceApprove(address(basePool), received);
        // minAmountOut = 0: LP mint is oracle-priced upstream (no AMM spot to sandwich);
        // the buy leg carries the Portal-level minOut bound and is operator-gated.
        uint256 lpOut = basePool.deposit(poolId, received, 0, address(this), address(this));
        totalLpMinted += lpOut;

        emit RevenueProcessed(amount, received, lpOut);
    }

    /// @notice Switch between AUTO (permissionless processRevenue) and MANUAL (operator-only).
    /// @dev Restricted to creator or Guardian. Guardian retains access per the Flap mandate.
    function setMode(Mode newMode) external {
        if (msg.sender != creator && msg.sender != _getGuardian()) revert NotModeAdmin();
        mode = newMode;
        emit ModeChanged(newMode);
    }

    /// @dev BNB → taxToken via the Flap Portal (bonding curve or DEX phase, Portal routes).
    ///      minOut is a same-block quote bound — it caps single-call deviation but cannot
    ///      prevent sandwiches; the real protection is the OPERATOR_ROLE gate on the caller.
    ///      Returns the BALANCE DELTA, not the Portal's return value: DEX-phase buys land
    ///      net of the token's own transfer tax (docs/phase0-v3-findings.md).
    function _buyTaxToken(uint256 bnbAmount) internal returns (uint256 received) {
        IPortalTradeV2 portal = IPortalTradeV2(_getPortal());
        uint256 quoted = portal.quoteExactInput(
            IPortalTradeV2.QuoteExactInputParams({
                inputToken: address(0),
                outputToken: taxToken,
                inputAmount: bnbAmount
            })
        );
        if (quoted == 0) revert ZeroQuote();
        uint256 minOut = (quoted * (BPS_DENOMINATOR - maxSlippageBps)) / BPS_DENOMINATOR;

        uint256 balanceBefore = IERC20(taxToken).balanceOf(address(this));
        portal.swapExactInput{value: bnbAmount}(
            IPortalTradeV2.ExactInputParams({
                inputToken: address(0),
                outputToken: taxToken,
                inputAmount: bnbAmount,
                minOutputAmount: minOut,
                permitData: ""
            })
        );
        received = IERC20(taxToken).balanceOf(address(this)) - balanceBefore;
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
            poolManager.deployPool(IMyxPoolManager.DeployPoolParams({marketId: marketId, baseToken: taxToken}));
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
        quoteToken.forceApprove(address(swapRouter), usdtBalance);
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
        IERC20(address(wbnb)).forceApprove(dividendAddr, wbnbAmount);
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

    /// @notice Notional LP share for a tax-token holder: vaultLp * holderBalance / totalSupply.
    function userLpShare(address user) external view returns (uint256) {
        uint256 supply = IERC20(taxToken).totalSupply();
        if (supply == 0) return 0;
        address lpToken = poolManager.getPool(poolId).basePoolToken;
        if (lpToken == address(0)) return 0;
        uint256 vaultLp = IERC20(lpToken).balanceOf(address(this));
        return (vaultLp * IERC20(taxToken).balanceOf(user)) / supply;
    }

    /// @notice Vault-level claimable rebates from the MYX base pool.
    /// @param price MYX oracle price input required by pendingUserRebates upstream.
    function pendingVaultRebates(uint256 price) external view returns (uint256 rebates, uint256 genesisRebates) {
        return basePool.pendingUserRebates(poolId, address(this), price);
    }

    /// @notice Per-holder claimable dividend, read from the token's Dividend contract.
    /// @dev Verified signature (docs/phase0-findings.md): withdrawableDividends(address).
    ///      Holders claim via withdrawDividends() on the Dividend contract directly.
    function pendingReward(address user) external view returns (uint256) {
        return IDividendDistributor(IFlapTaxTokenV3(taxToken).dividendContract()).withdrawableDividends(user);
    }

    function description() public view override returns (string memory) {
        return string.concat(
            "MYX liquidity vault: buys back the token with tax revenue via the Flap Portal and provides it as MYX base-pool liquidity held by this vault (",
            Strings.toString(totalLpMinted),
            " LP minted cumulatively; some may have been emergency-withdrawn) and forwards harvested rebates to the token's dividend contract (",
            Strings.toString(totalRewardsForwarded),
            " WBNB forwarded). Pending BNB: ",
            Strings.toString(pendingBnb),
            ". harvest() is permissionless. processRevenue() trigger mode: ",
            mode == Mode.AUTO ? "AUTO (permissionless)" : "MANUAL (operator-only)",
            "."
        );
    }

    function vaultUISchema() public pure override returns (VaultUISchema memory schema) {
        schema.vaultType = "MyxVault";
        schema.description =
            "Tax revenue becomes MYX base-pool liquidity; LP rewards flow back to holders via the dividend contract.";
        schema.methods = new VaultMethodSchema[](5);

        schema.methods[0].name = "userLpShare";
        schema.methods[0].description = "Notional LP share for a holder, pro-rata to token balance.";
        schema.methods[0].inputs = new FieldDescriptor[](1);
        schema.methods[0].inputs[0] = FieldDescriptor("user", "address", "Holder address", 0);
        schema.methods[0].outputs = new FieldDescriptor[](1);
        schema.methods[0].outputs[0] = FieldDescriptor("share", "uint256", "Notional LP amount", 18);

        schema.methods[1].name = "pendingBnb";
        schema.methods[1].description = "Tax revenue awaiting processing.";
        schema.methods[1].outputs = new FieldDescriptor[](1);
        schema.methods[1].outputs[0] = FieldDescriptor("amount", "uint256", "BNB amount", 18);

        schema.methods[2].name = "processRevenue";
        schema.methods[2].description =
            "Convert pending BNB into MYX base-pool liquidity by buying back the token. Permissionless in AUTO mode, operator-only in MANUAL mode.";
        schema.methods[2].isWriteMethod = true;

        schema.methods[3].name = "harvest";
        schema.methods[3].description = "Claim LP rebates and forward them to the dividend contract. Anyone can call.";
        schema.methods[3].isWriteMethod = true;

        schema.methods[4].name = "pendingReward";
        schema.methods[4].description = "Claimable dividend for a holder (claim on the token's dividend contract).";
        schema.methods[4].inputs = new FieldDescriptor[](1);
        schema.methods[4].inputs[0] = FieldDescriptor("user", "address", "Holder address", 0);
        schema.methods[4].outputs = new FieldDescriptor[](1);
        schema.methods[4].outputs[0] = FieldDescriptor("amount", "uint256", "Claimable WBNB amount", 18);
    }
}
