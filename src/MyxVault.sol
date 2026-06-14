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
import {IFlapTriggerService, ITriggerReceiver} from "./flap/IFlapTriggerService.sol";
import {Strings} from "@openzeppelin/utils/Strings.sol";

/// @title MyxVault
/// @notice Flap vault that buys back the tax token with tax revenue via the Flap Portal, deposits
///         it as MYX base-pool liquidity, and feeds the resulting LP (mBase) into the token's
///         native Flap Dividend contract — the LP ITSELF is the dividend asset.
/// @dev v6 reward model (Lista pattern): the vault is an LP producer + dividend feeder + claim
///      proxy. tax BNB -> Portal buyback (BASE) -> BasePool.deposit (LP minted to the vault) ->
///      _feedDividend deposits the LP into the Dividend contract whose dividendToken == that same
///      mBase LP (wired at launch via computeDividendToken). Holders claim the mBase LP via the
///      dividend (fairly, via Flap setShare hooks), then claim their myx rebates themselves on myx.
///      The vault NO LONGER claims or handles any USDT rebate.
/// @dev Invariants:
///      - receive() performs accounting only (Flap Rule 005), never external calls.
///      - The dividend asset IS the LP: dividendToken == basePoolToken == mBase. _feedDividend
///        deposits the whole held LP balance; if the dividend is unwired or deposit() returns false
///        (totalShares == 0 early window), the LP is RETAINED (DividendDeferred) and retried on the
///        next feedDividend()/cycle — no swap, no price feeds, no fallback path.
///      - processRevenue is mode-gated: AUTO is permissionless so a keeper can run it automatically;
///        TRIGGERED and MANUAL restrict it to OPERATOR_ROLE. setMode is creator/Guardian-only.
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
        address marketQuoteToken;
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
    error ZeroMarketQuoteToken();
    error BelowMinimumProcessAmount(uint256 pending, uint256 minimum);
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
    /// @notice Emitted when the vault's LP (mBase) balance is successfully fed into the token's
    ///         native Dividend contract. `lpFed` == the LP amount distributed to holders.
    event Harvested(uint256 lpFed, uint256 forwarded);
    /// @notice Emitted when a feed is deferred (dividend not wired yet, or deposit() returned false
    ///         because totalShares == 0 in the early window). The LP is retained for a later retry.
    event DividendDeferred(uint256 lpAmount);
    event EmergencyWithdrawal(uint256 lpAmount, uint256 amountOut, address to);
    event EmergencySwept(uint256 bnbAmount, address to);
    event TriggerScheduled(uint256 requestId, uint64 executeAfter);
    event CycleExecuted(uint256 boughtBnb, uint256 harvested);
    event LoopStalled(uint256 pendingBnb);

    address public taxToken;
    address public creator;
    /// @notice The myx market quote token (= the token's dividendToken, e.g. USDT/USDC). The launch
    ///         param; the vault derives marketId from it on-chain so the dividendToken == pool-quote
    ///         == reward invariant is automatic.
    address public marketQuoteToken;
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
    ///      v4-5 added marketQuoteToken (one slot); gap 40 -> 39.
    uint256[39] private __gap;

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
    ///      from the triggered _runCycle (after its own min gate). Consumes all pendingBnb, mints LP
    ///      to the vault, then feeds the whole LP balance into the dividend (v6: the LP is the reward).
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

        // v6: distribute the freshly minted LP (plus any deferred LP from a prior failed feed) to
        // holders via the token's native Dividend contract. Deferral-safe: never reverts the buyback.
        _feedDividend();
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

    /// @notice Feeds the vault's whole held LP (mBase) balance into the token's native Dividend
    ///         contract, distributing it to holders. Permissionless in ALL modes: anyone can retry a
    ///         deferred feed (e.g. once the dividend gets wired or its totalShares becomes > 0)
    ///         without performing a buyback.
    function feedDividend() external nonReentrant {
        _feedDividend();
    }

    /// @dev Feeds the WHOLE vault LP balance (freshly minted + any deferred from a prior failed feed)
    ///      into the dividend contract. Deferral-safe — NEVER reverts the caller:
    ///        - no LP held              -> no-op
    ///        - dividend not wired      -> retain LP, emit DividendDeferred, retry next time
    ///        - deposit() returns false -> retain LP, emit DividendDeferred, retry next time
    ///          (real Dividend returns false when totalShares == 0 in the early window — Lista pattern)
    ///      This replaces the v4 USDT rebate-claim+forward entirely: the LP IS the dividend asset, so
    ///      there is nothing to claim or swap. The deferral is the documented degraded mode (no
    ///      fallback path, anti-fallback principle): a failed feed simply retains the LP for retry.
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
        emit Harvested(bal, bal);
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

    /// @dev One automated cycle: always flush any deferred LP into the dividend (the timed feed
    ///      backstop), reserve the next cycle's fee from pendingBnb and reschedule, then buy back
    ///      with whatever BNB remains if it clears the threshold (the buyback also feeds the LP it
    ///      mints). Re-validates the buyback threshold at callback time (delay-aware).
    function _runCycle() internal {
        // Order: flush deferred LP (timed feed backstop) -> reschedule next cycle (so the timer
        // survives a SKIPPED buyback when pendingBnb < minProcessAmount) -> conditional buyback+feed.
        // The feed NEVER reverts (deferral-safe), so unlike the v4 harvest it cannot brick the loop:
        // a not-yet-wired dividend or a totalShares==0 window simply retains the LP for the next cycle.
        _feedDividend(); // always settle deferred rewards; never reverts

        // Reschedule ONLY while still in TRIGGERED mode. If a setMode(AUTO|MANUAL) landed while this
        // trigger was in-flight, the current cycle's feed+buyback still complete (harmless), but
        // the loop is NOT re-armed — so switching away from TRIGGERED cleanly winds the automation
        // down after the in-flight trigger instead of self-perpetuating forever (and draining
        // pendingBnb on trigger fees against the operator's intent). pendingTriggerId was already
        // consumed in trigger(), so leaving it at 0 here makes scheduleTrigger() the explicit
        // restart path once TRIGGERED is re-selected.
        if (mode == Mode.TRIGGERED) {
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

    /// @notice Claim proxy (Lista pattern): claims the caller's mBase LP dividend ON THEIR BEHALF
    ///         via the token's Dividend contract, paying the LP directly to msg.sender. A convenience
    ///         only — holders may equivalently call withdrawDividends() on the Dividend contract
    ///         themselves. Reverts if the dividend is not wired (the call on the zero address fails);
    ///         pendingReward() guards that case for read-side UI.
    function claimReward() external nonReentrant {
        IDividendDistributor(IFlapTaxTokenV3(taxToken).dividendContract()).withdrawDividendsFor(msg.sender);
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

    /// @notice Per-holder claimable mBase LP dividend, read from the token's Dividend contract.
    /// @dev v6: the unit is mBase LP, not USDT. Guards an unwired dividend (returns 0). Holders claim
    ///      via claimReward() here or withdrawDividends() on the Dividend contract directly.
    function pendingReward(address user) external view returns (uint256) {
        address div = IFlapTaxTokenV3(taxToken).dividendContract();
        if (div == address(0)) return 0;
        return IDividendDistributor(div).withdrawableDividends(user);
    }

    function description() public view override returns (string memory) {
        return string.concat(
            "MYX liquidity vault: buys back the token with tax revenue via the Flap Portal, provides it as MYX base-pool liquidity (",
            Strings.toString(totalLpMinted),
            " LP minted cumulatively) and feeds the resulting myx LP (mBase) into the token's dividend contract as the reward asset (",
            Strings.toString(totalRewardsForwarded),
            " LP distributed). Holders claim the LP via claimReward() (or the dividend contract directly), then earn myx rebates by holding it. Pending BNB: ",
            Strings.toString(pendingBnb),
            ". feedDividend() is permissionless. processRevenue() trigger mode: ",
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
            "Tax revenue becomes MYX base-pool liquidity (mBase LP); the LP itself is fed into the token's dividend contract as the reward. Holders claim the LP, then earn myx rebates by holding it.";
        schema.methods = new VaultMethodSchema[](5);

        schema.methods[0].name = "pendingBnb";
        schema.methods[0].description = "Tax revenue awaiting processing.";
        schema.methods[0].outputs = new FieldDescriptor[](1);
        schema.methods[0].outputs[0] = FieldDescriptor("amount", "uint256", "BNB amount", 18);

        schema.methods[1].name = "processRevenue";
        schema.methods[1].description =
            "Convert pending BNB into MYX base-pool liquidity by buying back the token, then feed the resulting mBase LP into the dividend contract. Permissionless in AUTO mode; operator-only in TRIGGERED and MANUAL modes (TRIGGERED also runs automatically via the Flap TriggerService).";
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
