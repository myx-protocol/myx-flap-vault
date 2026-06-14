// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.26;

import {VaultBaseV2} from "./flap/VaultBaseV2.sol";
import {VaultUISchema, VaultMethodSchema, FieldDescriptor} from "./flap/IVaultSchemasV1.sol";
import {Initializable} from "@openzeppelin-contracts-upgradeable/proxy/utils/Initializable.sol";
import {AccessControlUpgradeable} from "@openzeppelin-contracts-upgradeable/access/AccessControlUpgradeable.sol";
import {ReentrancyGuardUpgradeable} from "@openzeppelin-contracts-upgradeable/security/ReentrancyGuardUpgradeable.sol";
import {IERC20} from "@openzeppelin/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/token/ERC20/utils/SafeERC20.sol";
import {MarketId, PoolId, MyxPoolId, MyxMarketId, PoolMetadata, IMyxPoolManager, IMyxBasePool} from "./myx/IMyxPool.sol";
import {IDividendDistributor} from "./dividend/IDividendDistributor.sol";
import {IFlapTaxTokenV3} from "./flap/IFlapTaxTokenV3.sol";
import {IPortalTradeV2} from "./flap/IPortal.sol";
import {Strings} from "@openzeppelin/utils/Strings.sol";

/// @title MyxVault
/// @notice Flap vault that buys back the tax token with tax revenue via the Flap Portal, deposits
///         it as MYX base-pool liquidity, and feeds the resulting LP (mBase) into the token's
///         native Flap Dividend contract — the LP ITSELF is the dividend asset.
/// @dev v6 reward model (Lista pattern): the vault is an LP producer + dividend feeder + claim
///      proxy. tax BNB -> receive() accounting -> process() [permissionless] buys back the token
///      via the Portal (BASE), deposits it into the MYX base pool (LP minted to the vault), then
///      _feedDividend deposits the LP into the Dividend contract whose dividendToken == that same
///      mBase LP (wired at launch via computeDividendToken). Holders claim the mBase LP via the
///      dividend (fairly, via Flap setShare hooks), then earn myx rebates by holding it.
/// @dev Invariants:
///      - receive() performs accounting only (Flap Rule 005), never external calls, never reverts.
///      - process() is permissionless: anyone may convert pending BNB into liquidity + dividend.
///      - The dividend asset IS the LP: dividendToken == basePoolToken == mBase. _feedDividend
///        deposits the whole held LP balance; if the dividend is unwired or deposit() returns false
///        (totalShares == 0 early window), the LP is RETAINED (DividendDeferred) and retried on the
///        next feedDividend()/process() — no swap, no price feeds, no fallback path.
///      - Guardian roles cannot be revoked by any other account; only the guardian itself may
///        voluntarily renounce (Flap mandate).
contract MyxVault is VaultBaseV2, Initializable, AccessControlUpgradeable, ReentrancyGuardUpgradeable {
    using SafeERC20 for IERC20;

    struct InitParams {
        address taxToken;
        address creator;
        address marketQuoteToken;
        address poolManager;
        address basePool;
        uint16 maxSlippageBps;
        uint256 minProcessAmount;
    }

    bytes32 public constant EMERGENCY_ROLE = keccak256("EMERGENCY_ROLE");
    uint16 public constant BPS_DENOMINATOR = 10_000;

    error CannotRevokeGuardianRole();
    error ZeroMarketQuoteToken();
    error BelowMinimumProcessAmount(uint256 pending, uint256 minimum);
    error ZeroQuote();
    error ZeroDividendContract();

    event RevenueReceived(uint256 amount, uint256 pendingTotal);
    event RevenueProcessed(uint256 bnbAmount, uint256 baseAmount, uint256 lpMinted);
    event PoolDeployed(PoolId poolId);
    /// @notice Emitted when the vault's LP (mBase) balance is successfully fed into the token's
    ///         native Dividend contract. `lpFed` == the LP amount distributed to holders.
    event DividendFed(uint256 lpFed);
    /// @notice Emitted when a feed is deferred (dividend not wired yet, or deposit() returned false
    ///         because totalShares == 0 in the early window). The LP is retained for a later retry.
    event DividendDeferred(uint256 lpAmount);
    event EmergencyWithdrawal(uint256 lpAmount, uint256 amountOut, address to);
    event EmergencySwept(uint256 bnbAmount, address to);
    /// @notice Emitted when an arbitrary stuck ERC20 (deferred mBase LP, residual tax token, or any
    ///         token accidentally sent here) is rescued to `to`. The generic escape hatch that
    ///         guarantees deferred LP is recoverable even if the myx pool's withdraw path is unusable.
    event EmergencyTokenRescued(address indexed token, address to, uint256 amount);

    address public taxToken;
    address public creator;
    /// @notice The myx MARKET quote token (e.g. USDT/USDC) — the launch param, used ONLY to derive
    ///         the myx marketId/base pool on-chain (marketId = keccak256(chainId, quoteToken)). v6: the
    ///         dividend ASSET is NOT this token but the resulting myx LP (mBase = basePoolToken), which
    ///         the vault produces and feeds into the dividend contract as the reward.
    address public marketQuoteToken;
    MarketId public marketId;
    PoolId public poolId;
    IMyxPoolManager public poolManager;
    IMyxBasePool public basePool;
    uint16 public maxSlippageBps;
    uint256 public minProcessAmount;

    uint256 public pendingBnb;
    uint256 public totalLpMinted;
    uint256 public totalRewardsForwarded;

    /// @dev Reserved storage to allow inserting parent mixins or new variables in upgrades.
    uint256[44] private __gap;

    constructor() {
        _disableInitializers();
    }

    function initialize(InitParams calldata p) external initializer {
        __AccessControl_init();
        __ReentrancyGuard_init();

        taxToken = p.taxToken;
        creator = p.creator;
        // The launch param is the market quote token (= the token's dividendToken). Derive the myx
        // marketId on-chain (marketId = keccak256(chainId, quoteToken), verified equivalent to myx
        // MarketIdLib.toId), then the base pool key from it. This makes the dividendToken ==
        // pool-quote == reward invariant automatic — no opaque id, no myx query, no hardcoding.
        if (p.marketQuoteToken == address(0)) revert ZeroMarketQuoteToken();
        marketQuoteToken = p.marketQuoteToken;
        marketId = MyxMarketId.derive(uint64(block.chainid), p.marketQuoteToken);
        poolId = MyxPoolId.derive(marketId, p.taxToken);
        poolManager = IMyxPoolManager(p.poolManager);
        basePool = IMyxBasePool(p.basePool);
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

    /// @notice Converts accumulated BNB into MYX base-pool liquidity by buying back the tax token
    ///         via the Flap Portal, then feeds the resulting mBase LP into the token's dividend
    ///         contract. PERMISSIONLESS — anyone may run it.
    /// @dev The buy leg's minOut is a same-block Portal quote (no Chainlink feed exists for the tax
    ///      token) × (1 - maxSlippageBps): it bounds per-call deviation but cannot prevent
    ///      sandwiching (BSC block proposers can reorder at no cost). Consumes ALL pendingBnb, mints
    ///      LP to the vault, then feeds the whole LP balance into the dividend (v6: the LP is the reward).
    function process() external nonReentrant {
        uint256 amount = pendingBnb;
        if (amount < minProcessAmount) revert BelowMinimumProcessAmount(amount, minProcessAmount);
        pendingBnb = 0;

        uint256 received = _buyTaxToken(amount);
        _ensurePoolExists();

        IERC20(taxToken).forceApprove(address(basePool), received);
        // minAmountOut = 0: LP mint is oracle-priced upstream (no AMM spot to sandwich);
        // the buy leg carries the Portal-level minOut bound.
        uint256 lpOut = basePool.deposit(poolId, received, 0, address(this), address(this));
        totalLpMinted += lpOut;

        emit RevenueProcessed(amount, received, lpOut);

        // v6: distribute the freshly minted LP (plus any deferred LP from a prior failed feed) to
        // holders via the token's native Dividend contract. Deferral-safe: never reverts the buyback.
        _feedDividend();
    }

    /// @notice Feeds the vault's whole held LP (mBase) balance into the token's native Dividend
    ///         contract, distributing it to holders. Permissionless: anyone can retry a deferred
    ///         feed (e.g. once the dividend gets wired or its totalShares becomes > 0) without
    ///         performing a buyback.
    function feedDividend() external nonReentrant {
        _feedDividend();
    }

    /// @dev Feeds the WHOLE vault LP balance (freshly minted + any deferred from a prior failed feed)
    ///      into the dividend contract. Deferral-safe — NEVER reverts the caller:
    ///        - no LP held              -> no-op
    ///        - dividend not wired      -> retain LP, emit DividendDeferred, retry next time
    ///        - deposit() returns false -> retain LP, emit DividendDeferred, retry next time
    ///          (real Dividend returns false when totalShares == 0 in the early window — Lista pattern)
    ///      The LP IS the dividend asset, so there is nothing to claim or swap. The deferral is the
    ///      documented degraded mode (no fallback path, anti-fallback principle).
    function _feedDividend() internal {
        address lp = poolManager.getPool(poolId).basePoolToken; // the mBase LP token
        if (lp == address(0)) return;
        uint256 bal = IERC20(lp).balanceOf(address(this));
        if (bal == 0) return;
        address div = IFlapTaxTokenV3(taxToken).dividendContract();
        if (div == address(0)) {
            emit DividendDeferred(bal); // not wired yet -> keep LP, retry next time
            return;
        }
        IERC20(lp).forceApprove(div, bal);
        // deposit() returns false when totalShares == 0 (early window) -> keep LP, retry (Lista pattern)
        if (!IDividendDistributor(div).deposit(bal)) {
            emit DividendDeferred(bal);
            return;
        }
        totalRewardsForwarded += bal;
        emit DividendFed(bal);
    }

    /// @notice Deploys the myx pool for this token if missing. Permissionless pre-deploy so the heavy
    ///         deployPool gas can be paid out-of-band rather than inside the first process() call.
    function ensurePoolDeployed() external nonReentrant {
        _ensurePoolExists();
    }

    /// @notice Claim proxy (Lista pattern): claims the caller's mBase LP dividend ON THEIR BEHALF
    ///         via the token's Dividend contract, paying the LP directly to msg.sender. A convenience
    ///         only — holders may equivalently call withdrawDividends() on the Dividend contract.
    function claimReward() external nonReentrant {
        address div = IFlapTaxTokenV3(taxToken).dividendContract();
        if (div == address(0)) revert ZeroDividendContract();
        IDividendDistributor(div).withdrawDividendsFor(msg.sender);
    }

    /// @notice Per-holder claimable mBase LP dividend, read from the token's Dividend contract.
    /// @dev v6: the unit is mBase LP, not USDT. Guards an unwired dividend (returns 0). Holders claim
    ///      via claimReward() here or withdrawDividends() on the Dividend contract directly.
    function pendingReward(address user) external view returns (uint256) {
        address div = IFlapTaxTokenV3(taxToken).dividendContract();
        if (div == address(0)) return 0;
        return IDividendDistributor(div).withdrawableDividends(user);
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

    /// @notice Sweeps stuck native BNB. Disaster recovery only (e.g. process() permanently broken).
    function emergencySweepBnb(address to) external nonReentrant onlyRole(EMERGENCY_ROLE) {
        uint256 amount = address(this).balance;
        pendingBnb = 0;
        (bool ok,) = to.call{value: amount}("");
        require(ok, "BNB_SWEEP_FAILED");
        emit EmergencySwept(amount, to);
    }

    /// @notice Rescues the full balance of any stuck ERC20 held by the vault to `to`. Disaster
    ///         recovery only. This is the generic escape hatch for DEFERRED mBase LP (retained when
    ///         the dividend stays unwired or its totalShares == 0 forever) and for residual tax
    ///         tokens left by a failed buyback — neither of which `emergencyWithdraw` can recover if
    ///         the myx pool's withdraw path is itself unusable. Guardian/creator-gated, full-balance
    ///         drain, `nonReentrant` (Rule 009 `emergencyWithdrawToken` pattern).
    function emergencyRescueToken(address token, address to) external nonReentrant onlyRole(EMERGENCY_ROLE) {
        require(token != address(0) && to != address(0), "Zero address");
        uint256 bal = IERC20(token).balanceOf(address(this));
        if (bal > 0) {
            IERC20(token).safeTransfer(to, bal);
            emit EmergencyTokenRescued(token, to, bal);
        }
    }

    /// @dev BNB → taxToken via the Flap Portal (bonding curve or DEX phase, Portal routes).
    ///      minOut is a same-block quote bound — it caps single-call deviation but cannot
    ///      prevent sandwiches. Returns the BALANCE DELTA, not the Portal's return value:
    ///      DEX-phase buys land net of the token's own transfer tax (docs/phase0-v3-findings.md).
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

    function _ensurePoolExists() internal {
        PoolMetadata memory pool = poolManager.getPool(poolId);
        // basePoolToken is the definitive deposit-readiness signal: myx deployPool
        // atomically deploys the LP token, so a registered pool always has it set.
        if (pool.basePoolToken == address(0)) {
            poolManager.deployPool(IMyxPoolManager.DeployPoolParams({marketId: marketId, baseToken: taxToken}));
            emit PoolDeployed(poolId);
        }
    }

    function description() public view override returns (string memory) {
        return string.concat(
            "MYX liquidity vault: buys back the token with tax revenue via the Flap Portal, provides it as MYX base-pool liquidity (",
            Strings.toString(totalLpMinted),
            " LP minted cumulatively) and feeds the resulting myx LP (mBase) into the token's dividend contract as the reward asset (",
            Strings.toString(totalRewardsForwarded),
            " LP distributed). Holders claim the LP via claimReward() (or the dividend contract directly), then earn myx rebates by holding it. Pending BNB: ",
            Strings.toString(pendingBnb),
            ". process() and feedDividend() are permissionless."
        );
    }

    function vaultUISchema() public pure override returns (VaultUISchema memory schema) {
        schema.vaultType = "MyxVault";
        schema.description =
            "Tax revenue becomes MYX base-pool liquidity (mBase LP); the LP itself is fed into the token's dividend contract as the reward. Holders claim the LP, then earn myx rebates by holding it.";
        schema.methods = new VaultMethodSchema[](5);

        schema.methods[0].name = "pendingBnb";
        schema.methods[0].description = "Tax revenue awaiting processing.";
        schema.methods[0].outputs = new FieldDescriptor[](1);
        schema.methods[0].outputs[0] = FieldDescriptor("amount", "uint256", "BNB amount", 18);

        schema.methods[1].name = "process";
        schema.methods[1].description =
            "Convert pending BNB into MYX base-pool liquidity by buying back the token, then feed the resulting mBase LP into the dividend contract. Permissionless.";
        schema.methods[1].isWriteMethod = true;

        schema.methods[2].name = "feedDividend";
        schema.methods[2].description =
            "Feed the vault's held mBase LP into the dividend contract, distributing it to holders. Permissionless; retries any deferred feed without a buyback.";
        schema.methods[2].isWriteMethod = true;

        schema.methods[3].name = "claimReward";
        schema.methods[3].description =
            "Claim your mBase LP dividend on your behalf via the token's dividend contract (or claim on the dividend contract directly).";
        schema.methods[3].isWriteMethod = true;

        schema.methods[4].name = "pendingReward";
        schema.methods[4].description = "Claimable mBase LP dividend for a holder.";
        schema.methods[4].inputs = new FieldDescriptor[](1);
        schema.methods[4].inputs[0] = FieldDescriptor("user", "address", "Holder address", 0);
        schema.methods[4].outputs = new FieldDescriptor[](1);
        schema.methods[4].outputs[0] = FieldDescriptor("amount", "uint256", "Claimable LP amount", 18);
    }
}
