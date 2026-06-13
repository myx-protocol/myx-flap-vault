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
import {IDividendDistributor} from "./dividend/IDividendDistributor.sol";
import {IFlapTaxTokenV3} from "./flap/IFlapTaxTokenV3.sol";
import {IPortalTradeV2} from "./flap/IPortal.sol";
import {IFlapTriggerService, ITriggerReceiver} from "./flap/IFlapTriggerService.sol";
import {Strings} from "@openzeppelin/utils/Strings.sol";

/// @title MyxVault
/// @notice Flap vault that buys back the tax token with tax revenue via the Flap Portal,
///         deposits it as MYX base-pool liquidity (LP held by the vault) and forwards
///         harvested rebates directly to the token's Dividend contract.
/// @dev Invariants:
///      - receive() performs accounting only (Flap Rule 005), never external calls.
///      - harvest distributes the claimed rebate DIRECTLY: the myx pool's quote token equals
///        the token's configured dividendToken, so the rebate IS the dividend token — no swap,
///        no price feeds. The processRevenue trigger is mode-gated: AUTO (default) is
///        permissionless so a keeper can run it automatically; MANUAL restricts it to
///        OPERATOR_ROLE. setMode is creator/Guardian-only.
///      - Guardian roles cannot be revoked by any other account; only the guardian
///        itself may voluntarily renounce (Flap mandate).
contract MyxVault is
    VaultBaseV2,
    Initializable,
    AccessControlUpgradeable,
    ReentrancyGuardUpgradeable,
    ITriggerReceiver
{
    using SafeERC20 for IERC20;

    struct InitParams {
        address taxToken;
        address creator;
        MarketId marketId;
        address poolManager;
        address basePool;
        uint16 maxSlippageBps;
        uint256 minProcessAmount;
        address triggerService;
        uint64 triggerInterval;
    }

    bytes32 public constant EMERGENCY_ROLE = keccak256("EMERGENCY_ROLE");
    bytes32 public constant OPERATOR_ROLE = keccak256("OPERATOR_ROLE");
    uint16 public constant BPS_DENOMINATOR = 10_000;

    error CannotRevokeGuardianRole();
    error BelowMinimumProcessAmount(uint256 pending, uint256 minimum);
    error DividendDepositFailed();
    error DividendTokenMismatch(address poolQuote, address dividendToken);
    error ZeroDividendContract();
    error ZeroQuote();
    error NotAuthorized();
    error NotModeAdmin();
    error OnlyTriggerService();
    error UnknownTrigger(uint256 requestId);
    error TriggerAlreadyScheduled();
    error PoolNotDeployed();

    event RevenueReceived(uint256 amount, uint256 pendingTotal);
    event ModeChanged(Mode newMode);
    event RevenueProcessed(uint256 bnbAmount, uint256 baseAmount, uint256 lpMinted);
    event PoolDeployed(PoolId poolId);
    event Harvested(uint256 rebateAmount, uint256 forwarded);
    event EmergencyWithdrawal(uint256 lpAmount, uint256 amountOut, address to);
    event EmergencySwept(uint256 bnbAmount, address to);
    event TriggerScheduled(uint256 requestId, uint64 executeAfter);
    event CycleExecuted(uint256 boughtBnb, uint256 harvested);
    event LoopStalled(uint256 pendingBnb);

    address public taxToken;
    address public creator;
    MarketId public marketId;
    PoolId public poolId;
    IMyxPoolManager public poolManager;
    IMyxBasePool public basePool;
    uint16 public maxSlippageBps;
    uint256 public minProcessAmount;

    enum Mode { TRIGGERED, AUTO, MANUAL }

    uint256 public pendingBnb;
    uint256 public totalLpMinted;
    uint256 public totalRewardsForwarded;
    Mode public mode;

    /// @notice Flap TriggerService used to schedule the automated TRIGGERED cycle. Config-driven
    ///         (NOT hardcoded): BSC mainnet is 0xcf4EE25035CF883895110f367F5BA8172416a7F9 but the
    ///         testnet address is supplied at deploy time.
    address public triggerService;
    /// @notice Seconds between automated cycles (executeAfter = block.timestamp + triggerInterval).
    uint64 public triggerInterval;
    /// @notice The single in-flight trigger request id; 0 means no cycle is scheduled. Bound to
    ///         the next intended cycle and consumed atomically in trigger() (replay protection).
    uint256 public pendingTriggerId;

    /// @dev Reserved storage to allow inserting parent mixins or new variables in upgrades.
    ///      v4 removed 6 address/feed slots (swapRouter, wbnb, quoteToken, bnbUsdFeed,
    ///      usdtUsdFeed, maxPriceStaleness) from storage; gap bumped 36 -> 42 to keep the
    ///      total reserved layout tidy (contract not yet deployed). v4-2 added triggerService +
    ///      triggerInterval (one packed slot) and pendingTriggerId (one slot); gap 42 -> 40.
    uint256[40] private __gap;

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
        maxSlippageBps = p.maxSlippageBps;
        minProcessAmount = p.minProcessAmount;
        triggerService = p.triggerService;
        triggerInterval = p.triggerInterval;

        address guardian = _getGuardian();
        _grantRole(DEFAULT_ADMIN_ROLE, guardian);
        _grantRole(EMERGENCY_ROLE, guardian);
        _grantRole(EMERGENCY_ROLE, p.creator);
        _grantRole(OPERATOR_ROLE, guardian);
        _grantRole(OPERATOR_ROLE, p.creator);

        // BeaconProxy storage is zero so TRIGGERED=0 is already the default; set for readability.
        mode = Mode.TRIGGERED;
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
    ///         token via the Flap Portal. Access is mode-gated: AUTO is permissionless (a keeper
    ///         makes it effectively automatic); TRIGGERED and MANUAL restrict it to OPERATOR_ROLE
    ///         (in TRIGGERED, the automated path runs via the trigger() callback). The buy leg's
    ///         minOut is a same-block Portal quote (no Chainlink feed exists for the tax token),
    ///         which cannot prevent sandwiches on its own — in TRIGGERED/MANUAL the caller gate
    ///         is the protection.
    /// @dev In AUTO mode this is permissionless and the buy leg's minOut derives from a
    ///      same-block Portal quote — it bounds per-call deviation to maxSlippageBps but
    ///      cannot prevent sandwiching (BSC block proposers can reorder at no cost). For
    ///      sandwich-sensitive operation switch to MANUAL/TRIGGERED and submit via a private relay.
    function processRevenue() external nonReentrant {
        if (mode != Mode.AUTO && !hasRole(OPERATOR_ROLE, msg.sender)) revert NotAuthorized();
        if (pendingBnb < minProcessAmount) revert BelowMinimumProcessAmount(pendingBnb, minProcessAmount);
        _processInternal();
    }

    /// @dev The buyback body, callable from the public entrypoint (after the mode/min gate) and
    ///      from the triggered _runCycle (after its own min gate). Consumes all pendingBnb.
    function _processInternal() internal {
        uint256 amount = pendingBnb;
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

    /// @notice Switch between TRIGGERED (automated via the Flap TriggerService, operator-only
    ///         manual fallback), AUTO (permissionless processRevenue) and MANUAL (operator-only).
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

    function _ensurePoolExists() internal {
        PoolMetadata memory pool = poolManager.getPool(poolId);
        // basePoolToken is the definitive deposit-readiness signal: myx deployPool
        // atomically deploys the LP token, so a registered pool always has it set.
        if (pool.basePoolToken == address(0)) {
            poolManager.deployPool(IMyxPoolManager.DeployPoolParams({marketId: marketId, baseToken: taxToken}));
            emit PoolDeployed(poolId);
        }
    }

    /// @notice Claims accumulated LP rebates and distributes them directly to holders via the
    ///         token's native Dividend contract. Permissionless in ALL modes (post-v4 it has no
    ///         swap/MEV surface — just claim + direct deposit).
    function harvest() external nonReentrant {
        _harvestInternal();
    }

    /// @dev The harvest body, callable from the public entrypoint and from the triggered cycle.
    ///      Early-returns when there is nothing to claim (resilient backstop). It CAN still revert
    ///      on a misconfigured vault (DividendTokenMismatch / ZeroDividendContract /
    ///      DividendDepositFailed); in TRIGGERED mode such a revert bricks the whole _runCycle and
    ///      the loop must be recovered via retryTrigger()/manual scheduleTrigger(). This coupling
    ///      is accepted by design (a misconfigured vault is a dead vault) — no silent fallback is
    ///      added (anti-fallback principle).
    function _harvestInternal() internal {
        basePool.claimUserRebate(poolId, address(this), address(this));
        // The pool's quote token IS the reward token AND the token's configured dividendToken
        // (enforced in _forwardToDividend), so the claimed rebate is distributed directly.
        address rewardToken = poolManager.getPool(poolId).quoteToken;
        uint256 amount = IERC20(rewardToken).balanceOf(address(this));
        if (amount == 0) return;
        _forwardToDividend(rewardToken, amount);
        totalRewardsForwarded += amount;
        emit Harvested(amount, amount);
    }

    // ─────────────────────────────────────────────────────────────────────────────
    //  TRIGGERED automation (Flap TriggerService / ITriggerReceiver)
    //  Rule 008 compliance: caller validation (Critical), requestId replay protection
    //  (High), bounded deterministic callback under the 2M gas cap (High), nonReentrant.
    //  Market re-validation: the buyback minOut is re-derived from a fresh same-block Portal
    //  quote inside _buyTaxToken at callback time (no scheduling-time price is reused), and the
    //  minProcessAmount gate is re-checked in _runCycle — so the callback never forces a stale
    //  or below-threshold action.
    // ─────────────────────────────────────────────────────────────────────────────

    /// @inheritdoc ITriggerReceiver
    /// @dev Rule 008: validate the caller is the official TriggerService, reject unknown/replayed
    ///      requestIds, and consume the request id BEFORE any external call so a revert restores
    ///      it (allowing a legit retryTrigger by anyone, no-gas-cap).
    function trigger(uint256 requestId) external override nonReentrant {
        if (msg.sender != triggerService) revert OnlyTriggerService();
        if (requestId == 0 || requestId != pendingTriggerId) revert UnknownTrigger(requestId);
        pendingTriggerId = 0; // consume before external calls; a revert restores it for retryTrigger
        _runCycle();
    }

    /// @dev One automated cycle: always settle rewards (the timed harvest backstop), reserve the
    ///      next cycle's fee from pendingBnb and reschedule, then buy back with whatever BNB remains
    ///      if it clears the threshold. Re-validates the buyback threshold at callback time
    ///      (delay-aware).
    function _runCycle() internal {
        // Order: settle rewards (timed harvest backstop) -> reschedule next cycle (so the timer
        // survives a SKIPPED buyback when pendingBnb < minProcessAmount) -> conditional buyback.
        // NOTE: all three run in one tx; a harvest revert (DividendDepositFailed when
        // totalShares==0, DividendTokenMismatch, ZeroDividendContract) aborts the ENTIRE cycle
        // including the reschedule, stalling the loop until retryTrigger()/manual recovery. This
        // coupling is accepted (see _harvestInternal). In practice tax revenue implies prior
        // trades, which create dividend holders, so totalShares>0 by the time BNB accumulates.
        _harvestInternal(); // always settle rewards; never reverts on an empty rebate

        uint256 fee = IFlapTriggerService(triggerService).getFee();
        // reschedule the next cycle, paying the fee from pendingBnb (the only BNB the vault holds)
        if (pendingBnb >= fee) {
            pendingBnb -= fee;
            _scheduleNext(fee);
        } else {
            // not enough BNB to pay for the next trigger: the automation loop stops here and
            // must be restarted via scheduleTrigger() once new tax revenue arrives.
            emit LoopStalled(pendingBnb);
        }
        // buy back with whatever BNB remains, if it clears the threshold
        uint256 bought = 0;
        if (pendingBnb >= minProcessAmount) {
            bought = pendingBnb;
            _processInternal();
        }
        emit CycleExecuted(bought, 0);
    }

    /// @dev Requests the next trigger from the service, paying `fee`, and binds its id.
    function _scheduleNext(uint256 fee) internal {
        uint64 executeAfter = uint64(block.timestamp + triggerInterval);
        uint256 id = IFlapTriggerService(triggerService).requestTrigger{value: fee}(executeAfter);
        pendingTriggerId = id;
        emit TriggerScheduled(id, executeAfter);
    }

    /// @notice Starts (or restarts) the TRIGGERED automation loop. Anyone may call when no trigger
    ///         is pending; the scheduling fee is paid from pendingBnb. No-op gate if already scheduled.
    function scheduleTrigger() external nonReentrant {
        if (mode != Mode.TRIGGERED) revert NotAuthorized();
        // The heavy myx deployPool must run out-of-band (ensurePoolDeployed), never inside the
        // gas-capped trigger callback. Require the pool to exist before starting the loop.
        if (poolManager.getPool(poolId).basePoolToken == address(0)) revert PoolNotDeployed();
        if (pendingTriggerId != 0) revert TriggerAlreadyScheduled();
        uint256 fee = IFlapTriggerService(triggerService).getFee();
        if (pendingBnb < fee) revert BelowMinimumProcessAmount(pendingBnb, fee);
        pendingBnb -= fee;
        _scheduleNext(fee);
    }

    /// @notice Deploys the myx pool for this token if missing, so the heavy deployPool gas is not
    ///         paid inside a triggered processRevenue callback. Permissionless.
    function ensurePoolDeployed() external nonReentrant {
        _ensurePoolExists();
    }

    /// @dev Distributes the reward directly: the myx pool's quote token MUST equal the Flap
    ///      token's configured dividendToken, so no swap is needed. deposit() pulls the
    ///      dividendToken and returns false on failure (verified) — checked and reverted.
    function _forwardToDividend(address rewardToken, uint256 amount) internal {
        address dividendAddr = IFlapTaxTokenV3(taxToken).dividendContract();
        if (dividendAddr == address(0)) revert ZeroDividendContract();
        address divToken = IDividendDistributor(dividendAddr).dividendToken();
        if (divToken != rewardToken) revert DividendTokenMismatch(rewardToken, divToken);
        IERC20(rewardToken).forceApprove(dividendAddr, amount);
        if (!IDividendDistributor(dividendAddr).deposit(amount)) revert DividendDepositFailed();
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
            " LP minted cumulatively; some may have been emergency-withdrawn) and distributes harvested rebates directly to holders via the token's dividend contract (",
            Strings.toString(totalRewardsForwarded),
            " distributed). Pending BNB: ",
            Strings.toString(pendingBnb),
            ". harvest() is permissionless. processRevenue() trigger mode: ",
            _modeLabel(),
            "."
        );
    }

    /// @dev Human-readable label for the current processRevenue trigger mode.
    function _modeLabel() internal view returns (string memory) {
        if (mode == Mode.TRIGGERED) return "TRIGGERED (automated via Flap TriggerService, operator-only manual)";
        if (mode == Mode.AUTO) return "AUTO (permissionless)";
        return "MANUAL (operator-only)";
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
            "Convert pending BNB into MYX base-pool liquidity by buying back the token. Permissionless in AUTO mode; operator-only in TRIGGERED and MANUAL modes (TRIGGERED also runs automatically via the Flap TriggerService).";
        schema.methods[2].isWriteMethod = true;

        schema.methods[3].name = "harvest";
        schema.methods[3].description =
            "Claim LP rebates and distribute them directly to holders via the dividend contract. Anyone can call.";
        schema.methods[3].isWriteMethod = true;

        schema.methods[4].name = "pendingReward";
        schema.methods[4].description = "Claimable dividend for a holder (claim on the token's dividend contract).";
        schema.methods[4].inputs = new FieldDescriptor[](1);
        schema.methods[4].inputs[0] = FieldDescriptor("user", "address", "Holder address", 0);
        schema.methods[4].outputs = new FieldDescriptor[](1);
        schema.methods[4].outputs[0] = FieldDescriptor("amount", "uint256", "Claimable dividend amount", 18);
    }
}
