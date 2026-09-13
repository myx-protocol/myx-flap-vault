// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.26;

import {VaultBaseV3} from "./flap/VaultBaseV3.sol";
import {VaultBaseV2} from "./flap/VaultBaseV2.sol";
import {VaultUISchema} from "./flap/IVaultSchemasV1.sol";
import {MyxVaultUISchema} from "./lib/MyxVaultUISchema.sol";
import {Initializable} from "@openzeppelin-contracts-upgradeable/proxy/utils/Initializable.sol";
import {AccessControlUpgradeable} from "@openzeppelin-contracts-upgradeable/access/AccessControlUpgradeable.sol";
import {ReentrancyGuardUpgradeable} from "@openzeppelin-contracts-upgradeable/security/ReentrancyGuardUpgradeable.sol";
import {IERC20} from "@openzeppelin/token/ERC20/IERC20.sol";
import {IERC20Metadata} from "@openzeppelin/token/ERC20/extensions/IERC20Metadata.sol";
import {SafeERC20} from "@openzeppelin/token/ERC20/utils/SafeERC20.sol";
import {MarketId, PoolId, MyxPoolId, MyxMarketId, PoolMetadata, IMyxPoolManager, IMyxBasePool} from "./myx/IMyxPool.sol";
import {IDividendDistributor} from "./dividend/IDividendDistributor.sol";
import {IFlapTaxTokenV3} from "./flap/IFlapTaxTokenV3.sol";
import {IPortalTradeV2} from "./flap/IPortal.sol";
import {Decimal18} from "./lib/Decimal18.sol";
import {IFlapTriggerService, ITriggerReceiver} from "./flap/IFlapTriggerService.sol";
import {Math} from "@openzeppelin/utils/math/Math.sol";
import {ITaxProcessor} from "./flap/ITaxProcessor.sol";
import {ISwapRegistry} from "./flap/ISwapRegistry.sol";
import {IMultiDexRouter} from "./flap/IMultiDexRouter.sol";
import {IPortalQuoteConfigU8} from "./flap/IPortalQuoteConfigU8.sol";
import {IWBNB} from "./dex/IWBNB.sol";

/// @title MyxVault
/// @notice Flap vault that buys back the tax token with tax revenue via the Flap Portal, deposits
///         it as MYX base-pool liquidity, and feeds the resulting mBase LP into the token's
///         native Flap Dividend contract — the LP ITSELF is the dividend asset.
/// @dev v6 reward model: tax (native or ERC20 quote) → receive() accounting → process() [trigger-only]
///      buys back the token via the Portal, deposits it into the MYX base pool (LP minted to the
///      vault), then _feedDividend deposits the LP into the Dividend contract whose dividendToken ==
///      that same mBase LP (wired at launch). Holders claim the mBase LP via
///      the dividend (fairly, via Flap setShare hooks), then earn myx rebates by holding it.
/// @dev Invariants:
///      - receive() recognizes revenue via Rule-010 balance-delta accounting (pendingQuote advances to
///        the currency-agnostic quote balance — native: address(this).balance, ERC20: quoteToken
///        balanceOf(this)) then best-effort schedules a delayed process() via FlapTriggerService in
///        try/catch; accounting is the Rule-005/010 core and the schedule never reverts receive()
///        (deliberate Rule-005 deviation, see auto-trigger doc). sync() exposes the same recognition
///        permissionlessly for callers who cannot reach receive() with a wake call.
///      - process() runs ONLY through the FlapTriggerService callback (Flap submits callbacks through an
///        MEV-protected channel). Anyone may requestProcess() to schedule it; nobody can execute the swap
///        in their own transaction, which closes the front-run + sandwich surface of a public swap.
///      - The LP IS the dividend asset: dividendToken == basePoolToken == mBase. _feedDividend
///        deposits the whole held LP balance; if the dividend is unwired or deposit() returns false
///        (totalShares == 0 early window), the LP is RETAINED (DividendDeferred) — no swap, no
///        price feed, no fallback path. Anti-fallback: retry via feedDividend() or next process().
///      - Guardian roles cannot be revoked by any other account; only the guardian itself may
///        voluntarily renounce (Flap mandate).
contract MyxVault is VaultBaseV3, Initializable, AccessControlUpgradeable, ReentrancyGuardUpgradeable, ITriggerReceiver {
    using SafeERC20 for IERC20;

    struct InitParams {
        address taxToken;
        address creator;
        /// @dev Launch quote token of the tax token (address(0) = native). Equals vaultQuoteToken().
        address quoteToken;
        address marketQuoteToken;
        address poolManager;
        address basePool;
        uint16 maxSlippageBps;
        /// @dev Minimum recognized quote balance before process() runs; in quote base units.
        uint256 minProcessAmount;
        /// @dev ERC20 quote only: refill the BNB gas pool when it drops below this (wei).
        uint256 gasThreshold;
        /// @dev ERC20 quote only: target BNB gas pool after a refill (wei); must exceed gasThreshold.
        uint256 gasRefillAmount;
        /// @dev Per-call buyback cap in quote base units (>= minProcessAmount). A larger pendingQuote is
        ///      processed in successive batches, each scheduled by the previous one.
        uint256 maxProcessAmount;
    }

    bytes32 public constant EMERGENCY_ROLE = keccak256("EMERGENCY_ROLE");
    uint16 public constant BPS_DENOMINATOR = 10_000;
    /// @notice Delay between a tax receipt and the auto-scheduled process() (seconds).
    uint64 public constant PROCESS_DELAY = 60;
    /// @notice Hard cap on the gas-refill leg: at most this share of pendingQuote may be sold for
    ///         BNB in a single process() call, regardless of the linear size estimate. The refill
    ///         leg uses no external price reference (by design — see _refillGas), so a thinned or
    ///         sandwiched pool could otherwise make the sizing estimate demand up to all of
    ///         pendingQuote for a fixed ~gasRefillAmount of BNB; this bounds that per-batch loss to
    ///         20% of the batch. A capped refill is partial by design — the shortfall is retried on
    ///         the next process() call.
    uint16 public constant MAX_REFILL_SHARE_BPS = 2000;

    event RevenueReceived(uint256 amount, uint256 pendingTotal);
    event RevenueProcessed(uint256 quoteAmount, uint256 baseAmount, uint256 lpMinted);
    event PoolDeployed(PoolId poolId);
    /// @notice Emitted when the vault's mBase LP balance is successfully fed into the Dividend
    ///         contract. `lpFed` is the LP amount distributed to holders.
    event DividendFed(uint256 lpFed);
    /// @notice Emitted when a feed is deferred (dividend not wired yet, or deposit() returned false
    ///         because totalShares == 0 in the early window). LP is retained for retry.
    event DividendDeferred(uint256 lpAmount);
    event EmergencyWithdrawal(uint256 lpAmount, uint256 amountOut, address to);
    event EmergencySwept(uint256 ethAmount, address to);
    /// @notice Emitted when a stuck ERC20 is rescued to `to`. Generic escape hatch covering deferred
    ///         mBase LP, residual tax tokens, or any accidentally sent token — including cases where
    ///         the myx pool's withdraw path is unusable.
    event EmergencyTokenRescued(address indexed token, address to, uint256 amount);
    /// @notice Emitted when receive() schedules a delayed process() via FlapTriggerService.
    event ProcessScheduled(uint256 requestId, uint64 executeAfter);
    /// @notice Emitted when the trigger callback runs; `success` is process()'s try/catch outcome.
    event ProcessTriggered(uint256 requestId, bool success);
    /// @notice Emitted when someone tops up the BNB gas pool of an ERC20-quote vault.
    event GasFunded(address indexed from, uint256 amount);
    /// @notice Emitted when quote revenue was swapped into BNB for the gas pool.
    event GasRefilled(uint256 quoteIn, uint256 nativeOut, uint24 fee);
    /// @notice Emitted when a refill was due but did not happen: no quote/WBNB V3 pool could quote
    ///         it, the venue could not be resolved, or the swap itself reverted. Not a failure — the
    ///         batch is untouched, the buyback proceeds, and the refill is retried on the next
    ///         process().
    event GasRefillSkipped(uint256 pendingQuote);
    /// @notice Emitted when, after a refill, the remaining quote is below minProcessAmount.
    event BuybackSkipped(uint256 pendingQuote);
    /// @notice Emitted when process() hit maxProcessAmount: `processed` was bought back this call and
    ///         `remaining` stays in pendingQuote for the follow-up batch process() tries to schedule.
    event ProcessBatched(uint256 processed, uint256 remaining);

    address public taxToken;
    address public creator;
    /// @notice The myx MARKET quote token (e.g. USDT/USDC) — used ONLY to derive the myx marketId
    ///         (keccak256(chainId, quoteToken)) and base pool on-chain. The dividend ASSET is the
    ///         resulting myx LP (mBase = basePoolToken), not this token.
    address public marketQuoteToken;
    MarketId public marketId;
    PoolId public poolId;
    IMyxPoolManager public poolManager;
    IMyxBasePool public basePool;
    uint16 public maxSlippageBps;
    uint256 public minProcessAmount;

    /// @notice Recognized-and-unspent quote revenue (Flap rule 010 baseline). Native quote: equals
    ///         address(this).balance. ERC20 quote: <= IERC20(quoteToken).balanceOf(this).
    uint256 public pendingQuote;
    uint256 public totalLpMinted;
    uint256 public totalRewardsForwarded;

    /// @notice Last FlapTriggerService request id scheduled by receive(); meaningful only while
    ///         `hasPendingTrigger`. `hasPendingTrigger` is the in-flight gate (true => receive() skips
    ///         a duplicate schedule); kept separate from the id so service ids starting at 0 are safe.
    uint256 public pendingTriggerId;
    bool public hasPendingTrigger;

    /// @notice Revenue currency (address(0) = native gas token). Immutable after initialize.
    address public quoteToken;
    /// @notice ERC20 quote only: refill the BNB gas pool below this balance (wei).
    uint256 public gasThreshold;
    /// @notice ERC20 quote only: gas pool target after a refill (wei).
    uint256 public gasRefillAmount;
    /// @notice Per-call buyback cap (quote base units). Bounds the sandwich exposure of a single
    ///         process() after any accumulation; the remainder is processed in follow-up batches.
    uint256 public maxProcessAmount;

    /// @dev Reserved storage for upgrades. 44 original - 2 (trigger) - 2 (gasThreshold,
    ///      gasRefillAmount; quoteToken packs into the hasPendingTrigger slot) - 1 (maxProcessAmount)
    ///      = 39. Verified with `forge inspect MyxVault storage-layout`.
    uint256[39] private __gap;

    /// @dev Set only while executeGasRefill is unwrapping WBNB, so receive() can recognise the BNB
    ///      coming back from the wrapper and return before doing anything expensive. EIP-1153
    ///      transient storage (cleared at end of transaction): it occupies NO persistent slot, so the
    ///      layout above and __gap are untouched and the beacon upgrade path stays safe.
    /// @dev DEPLOY REQUIREMENT — EIP-1153: this vault requires the target chain to execute
    ///      TLOAD/TSTORE (Cancun, or an L2 whose stack has adopted it). receive() reads this flag as
    ///      its first statement, so on a chain without EIP-1153 EVERY receive() call would revert
    ///      with an invalid opcode: tax payouts would still land (a native transfer to a reverting
    ///      receive() reverts the payout; an ERC20 payout lands but its zero-value ping reverts), yet
    ///      nothing would be recognised or auto-scheduled on arrival. sync() and process() remain
    ///      callable by hand and recover the accounting, but the automatic path is gone. Confirm the
    ///      opcodes are live on the chain before deploying there (see the Robinhood deploy script's
    ///      checklist).
    bool private transient _unwrapping;

    constructor() {
        _disableInitializers();
    }

    function initialize(InitParams calldata p) external initializer {
        __AccessControl_init();
        __ReentrancyGuard_init();

        taxToken = p.taxToken;
        creator = p.creator;
        // Derive the myx marketId on-chain (keccak256(chainId, quoteToken), equivalent to myx
        // MarketIdLib.toId), then the base pool key. This makes the dividendToken == pool-quote ==
        // reward invariant automatic — no opaque id, no myx query, no hardcoding.
        require(p.marketQuoteToken != address(0), unicode"Zero market quote token / 市場報價幣為零地址");
        marketQuoteToken = p.marketQuoteToken;
        marketId = MyxMarketId.derive(uint64(block.chainid), p.marketQuoteToken);
        poolId = MyxPoolId.derive(marketId, p.taxToken);
        poolManager = IMyxPoolManager(p.poolManager);
        basePool = IMyxBasePool(p.basePool);
        maxSlippageBps = p.maxSlippageBps;
        minProcessAmount = p.minProcessAmount;

        quoteToken = p.quoteToken;
        if (p.quoteToken == address(0)) {
            require(
                p.gasThreshold == 0 && p.gasRefillAmount == 0,
                unicode"Gas params must be zero for native quote / 原生報價幣的 Gas 參數必須為零"
            );
        } else {
            require(
                p.gasRefillAmount > p.gasThreshold,
                unicode"Gas refill must exceed threshold / Gas 補充值必須大於閾值"
            );
        }
        gasThreshold = p.gasThreshold;
        gasRefillAmount = p.gasRefillAmount;
        require(
            p.maxProcessAmount >= p.minProcessAmount,
            unicode"Max process amount below minimum / 單批處理上限低於最低處理金額"
        );
        maxProcessAmount = p.maxProcessAmount;

        address guardian = _getGuardian();
        _grantRole(DEFAULT_ADMIN_ROLE, guardian);
        _grantRole(EMERGENCY_ROLE, guardian);
        _grantRole(EMERGENCY_ROLE, p.creator);
    }

    /// @inheritdoc VaultBaseV3
    function vaultQuoteToken() public view override returns (address) {
        return quoteToken;
    }

    /// @dev Rule-010 balance-delta recognition, currency-agnostic. Wake sources: native value
    ///      transfers (native quote), the TaxProcessor's zero-value ping after an ERC20 payout,
    ///      anyone calling with empty calldata. Zero-delta wakes are silent no-ops. Scheduling a
    ///      delayed process() via FlapTriggerService is wrapped in try/catch (self-call) so ANY
    ///      scheduling failure — service down, fee insufficient, OOG — degrades to "not scheduled"
    ///      and NEVER reverts receive() or loses tax. The external call is a deliberate Rule-005
    ///      deviation (see auto-trigger design doc); never-revert is preserved. Skipped while the
    ///      reentrancy guard is entered so process()'s internal WBNB unwrap (Task 7) cannot schedule
    ///      a trigger mid-process.
    /// @dev GAS STIPEND: the FIRST statement must stay a transient-storage read. The gas-refill leg
    ///      unwraps WBNB, and the real WETH9/WBNB pays out with transfer() — 2300 gas, which does not
    ///      cover even one external call, so _sync()'s quote balanceOf would run out of gas and revert
    ///      the whole withdraw. The _unwrapping flag lets this vault's own unwrap return in ~100 gas.
    ///      Nothing is lost by returning early: that BNB is gas-pool funding, never quote revenue,
    ///      and for an ERC20 quote _sync() reads the token balance, which the unwrap does not move.
    receive() external payable {
        if (_unwrapping) return;
        _sync();
        if (!hasPendingTrigger && pendingQuote >= minProcessAmount && !_reentrancyGuardEntered()) {
            try this.scheduleProcess() {} catch {}
        }
    }

    /// @notice Permissionless recognition entry: credits revenue that arrived without a wake call
    ///         (e.g. a plain ERC20 transfer with no follow-up ping, or a forced native credit).
    function sync() external {
        _sync();
    }

    /// @dev Currency-agnostic quote balance: native uses address(this).balance, ERC20 the vault's
    ///      quoteToken balance.
    function _quoteBalance() internal view returns (uint256) {
        return quoteToken == address(0) ? address(this).balance : IERC20(quoteToken).balanceOf(address(this));
    }

    /// @dev Advances pendingQuote to the current quote balance and emits the recognized delta. Never
    ///      reverts; a balance at or below the current baseline (nothing new, or an outflow already
    ///      accounted elsewhere) is a silent no-op.
    function _sync() internal returns (uint256 newRevenue) {
        uint256 bal = _quoteBalance();
        if (bal <= pendingQuote) return 0;
        newRevenue = bal - pendingQuote;
        pendingQuote = bal;
        emit RevenueReceived(newRevenue, pendingQuote);
    }

    /// @notice Schedules a delayed process() via FlapTriggerService. ONLY the vault itself may call it
    ///         (from receive()); the self-call lets receive() wrap getFee()+requestTrigger in one
    ///         try/catch. Native quote: the fee is paid from pendingQuote and debited only on success.
    ///         ERC20 quote: the fee is paid from the BNB gas pool; pendingQuote is untouched.
    function scheduleProcess() external {
        require(msg.sender == address(this), unicode"Caller must be the vault itself / 僅限金庫自身調用");
        IFlapTriggerService service = IFlapTriggerService(_getTriggerService());
        uint256 fee = service.getFee();
        if (quoteToken == address(0)) {
            // Decide on ACCUMULATED pendingQuote (not a single receipt): it must cover the fee AND
            // still leave >= minProcessAmount so the scheduled process() can actually run — no wasted
            // fee, and pendingQuote -= fee can never underflow.
            require(pendingQuote >= minProcessAmount + fee, unicode"Pending below minimum plus fee / 待處理低於下限加手續費");
        } else {
            require(pendingQuote >= minProcessAmount, unicode"Pending below minimum / 待處理金額低於下限");
            require(address(this).balance >= fee, unicode"Gas pool below trigger fee / Gas 池低於觸發手續費");
        }
        uint64 executeAfter = uint64(block.timestamp) + PROCESS_DELAY;
        uint256 id = service.requestTrigger{value: fee}(executeAfter);
        pendingTriggerId = id;
        hasPendingTrigger = true;
        if (quoteToken == address(0)) pendingQuote -= fee;
        emit ProcessScheduled(id, executeAfter);
    }

    /// @notice Tops up the BNB gas pool that pays FlapTriggerService fees. ERC20-quote vaults only:
    ///         on a native-quote vault every BNB is revenue and arrives through receive().
    function fundGas() external payable {
        require(quoteToken != address(0), unicode"Gas pool only for ERC20 quote / 僅 ERC20 報價幣金庫可充值 Gas");
        emit GasFunded(msg.sender, msg.value);
    }

    /// @notice BNB reserved for trigger fees. Zero for native-quote vaults (their BNB is revenue).
    function gasBalance() external view returns (uint256) {
        return quoteToken == address(0) ? 0 : address(this).balance;
    }

    /// @notice FlapTriggerService callback (ITriggerReceiver). Clears the in-flight gate FIRST, then
    ///         runs process() under try/catch so a revert (e.g. pendingQuote already drained below the
    ///         minimum by an earlier callback) cannot deadlock scheduling — the next tax
    ///         receipt re-schedules. Stale/unknown request ids are ignored.
    function trigger(uint256 requestId) external {
        require(msg.sender == _getTriggerService(), unicode"Caller must be the trigger service / 僅限觸發服務調用");
        if (!hasPendingTrigger || requestId != pendingTriggerId) return;
        hasPendingTrigger = false;
        pendingTriggerId = 0;
        bool success;
        try this.process() {
            success = true;
        } catch {
            success = false;
        }
        emit ProcessTriggered(requestId, success);
    }

    /// @notice Manual entry point: schedules process() through the FlapTriggerService instead of
    ///         executing the swap in the caller's transaction. Flap submits callbacks through an
    ///         MEV-protected channel; a public, caller-executed swap would expose the buyback to
    ///         front-running and sandwiching. Anyone may call it. ERC20-quote vaults may attach BNB
    ///         to fund the gas pool (e.g. exactly one fee); native-quote vaults reject value.
    ///         Reverts with the scheduling reason (below minimum, no gas, trigger already pending)
    ///         so the caller learns why nothing was scheduled.
    function requestProcess() external payable nonReentrant {
        if (msg.value != 0) {
            require(quoteToken != address(0), unicode"Gas pool only for ERC20 quote / 僅 ERC20 報價幣金庫可充值 Gas");
            emit GasFunded(msg.sender, msg.value);
        }
        _sync();
        require(!hasPendingTrigger, unicode"Trigger already pending / 已有待執行的觸發");
        this.scheduleProcess();
    }

    /// @dev FlapTriggerService address per chain — hardcoded like _getPortal/_getGuardian.
    ///      Robinhood testnet (46630) has a live service but no Portal/Guardian, so it is omitted
    ///      here too: scheduling on a chain whose vault cannot initialize is dead weight.
    function _getTriggerService() internal view returns (address) {
        if (block.chainid == 56) return 0xcf4EE25035CF883895110f367F5BA8172416a7F9;
        else if (block.chainid == 97) return 0x560E9830926C9e0EB98a59c6b9902383Fc0D9Eb2;
        else if (block.chainid == 4663) return 0xD3421B1b616a72bB88993A0cf75709BB8D532cc1;
        revert(unicode"Trigger service not configured / 觸發服務未配置");
    }

    /// @dev Flap mandate: the Guardian role must not be revocable by anyone else.
    function revokeRole(bytes32 role, address account) public override onlyRole(getRoleAdmin(role)) {
        require(account != _getGuardian(), unicode"Guardian role cannot be revoked / 守護者角色不可撤銷");
        super.revokeRole(role, account);
    }

    /// @notice Converts the accumulated quote revenue into MYX base-pool liquidity by buying back the tax token
    ///         via the Flap Portal, then feeds the resulting mBase LP into the token's dividend
    ///         contract. TRIGGER-ONLY: callable only by the vault itself, i.e. from the
    ///         FlapTriggerService callback in trigger(). Use requestProcess() to schedule a run.
    /// @dev Buy leg minOut is a same-block Portal quote × (1 - maxSlippageBps): bounds per-call
    ///      deviation but cannot prevent sandwiching (BSC block proposers reorder at no cost).
    ///      Consumes ALL pendingQuote; the LP IS the reward (v6 model).
    function process() external nonReentrant {
        require(msg.sender == address(this), unicode"Caller must be the vault itself / 僅限金庫自身調用");
        _sync();
        require(pendingQuote >= minProcessAmount, unicode"Pending below minimum / 待處理金額低於下限");
        _refillGas();
        uint256 available = pendingQuote;
        if (available < minProcessAmount) {
            emit BuybackSkipped(available);
            // Flush any deferred LP from a prior failed feed even when this call's buyback is
            // skipped — the refill leg alone must not stall a pending dividend distribution.
            _feedDividend();
            return;
        }
        // Batch cap: never swap more than maxProcessAmount in one call. Splitting inside one
        // transaction would not help (a sandwich brackets the whole tx); the remainder is left in
        // pendingQuote and a follow-up trigger is scheduled below, so accumulated revenue (e.g. after
        // a failed callback) drains across blocks instead of in one oversized buy.
        uint256 amount = available > maxProcessAmount ? maxProcessAmount : available;
        pendingQuote = available - amount;

        uint256 received = _buyTaxToken(amount);
        _ensurePoolExists();

        IERC20(taxToken).forceApprove(address(basePool), received);
        // minAmountOut = 0: LP mint is oracle-priced upstream (no AMM spot to sandwich);
        // the buy leg carries the Portal-level minOut bound.
        uint256 lpOut = basePool.deposit(poolId, received, 0, address(this), address(this));
        totalLpMinted += lpOut;

        emit RevenueProcessed(amount, received, lpOut);

        // Distribute freshly minted LP (+ any deferred LP from a prior failed feed) to holders.
        // Deferral-safe: never reverts the buyback.
        _feedDividend();

        uint256 remaining = pendingQuote;
        if (remaining != 0) {
            emit ProcessBatched(amount, remaining);
            // No new tax means no receive() wake, so the follow-up must be scheduled here. Same
            // best-effort semantics as receive(): a failed schedule (no gas, service down) is not an
            // error — the remainder waits for the next wake or a manual process().
            if (remaining >= minProcessAmount && !hasPendingTrigger) {
                try this.scheduleProcess() {} catch {}
            }
        }
    }

    /// @notice Feeds the vault's whole held mBase LP balance into the token's native Dividend
    ///         contract. Permissionless: retries a deferred feed (e.g. once the dividend is wired
    ///         or its totalShares becomes > 0) without performing a buyback.
    function feedDividend() external nonReentrant {
        _feedDividend();
    }

    /// @dev Feeds the WHOLE vault LP balance (freshly minted + any deferred) into the dividend
    ///      contract. Deferral-safe — NEVER reverts the caller:
    ///        - no LP held              -> no-op
    ///        - dividend not wired      -> retain LP, emit DividendDeferred, retry next call
    ///        - deposit() fails         -> retain LP, emit DividendDeferred, retry next call
    ///          (returns false in the totalShares == 0 early window, OR reverts when external state
    ///           isn't ready — try/catch degrades both to deferral)
    ///      The LP IS the dividend asset: nothing to swap or claim. Deferral is the documented
    ///      degraded mode; there is no fallback path (anti-fallback principle).
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
        // deposit() may either return false (totalShares == 0 early window) or revert (external
        // state not ready). Both degrade to the same deferral so the permissionless caller is never
        // reverted and the buyback + LP mint always land; the retained LP is retried on the next call.
        try IDividendDistributor(div).deposit(bal) returns (bool ok) {
            if (!ok) {
                emit DividendDeferred(bal);
                return;
            }
        } catch {
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

    /// @notice Claim proxy: claims the caller's mBase LP dividend on their behalf
    ///         via the token's Dividend contract. Convenience only — holders may also call
    ///         withdrawDividends() directly on the Dividend contract.
    function claimReward() external nonReentrant {
        address div = IFlapTaxTokenV3(taxToken).dividendContract();
        require(div != address(0), unicode"Dividend contract not set / 分紅合約未設置");
        IDividendDistributor(div).withdrawDividendsFor(msg.sender);
    }

    /// @notice Per-holder claimable mBase LP dividend, read from the token's Dividend contract.
    /// @dev Unit is mBase LP (not USDT). Returns 0 if the dividend is not yet wired.
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

    /// @notice Sweeps the vault's native balance. Native quote: this is the tax revenue, baseline
    ///         reset to zero (rule 010). ERC20 quote: this is only the gas pool, revenue untouched.
    function emergencySweepNative(address to) external nonReentrant onlyRole(EMERGENCY_ROLE) {
        uint256 amount = address(this).balance;
        if (quoteToken == address(0)) pendingQuote = 0;
        (bool ok,) = to.call{value: amount}("");
        require(ok, unicode"Native sweep failed / 原生幣清退失敗");
        emit EmergencySwept(amount, to);
    }

    /// @notice Rescues the full balance of any stuck ERC20 to `to`. Disaster recovery only.
    ///         Generic escape hatch for deferred mBase LP (retained when the dividend stays unwired
    ///         or totalShares == 0 indefinitely) and residual tax tokens from a failed buyback —
    ///         covering cases where emergencyWithdraw is unusable (myx pool withdraw path broken).
    ///         Rule 010: rescuing the quote token itself is an outflow of tax revenue, so the
    ///         baseline is reset to zero.
    function emergencyRescueToken(address token, address to) external nonReentrant onlyRole(EMERGENCY_ROLE) {
        require(token != address(0) && to != address(0), unicode"Zero address / 零地址");
        uint256 bal = IERC20(token).balanceOf(address(this));
        if (token == quoteToken) pendingQuote = 0;
        if (bal > 0) {
            IERC20(token).safeTransfer(to, bal);
            emit EmergencyTokenRescued(token, to, bal);
        }
    }

    /// @dev quote -> taxToken via the Flap Portal (bonding curve or DEX phase, Portal routes).
    ///      Native quote sends value; ERC20 quote approves the Portal and sends no value (the
    ///      Portal pulls the input, "BUY with quote"). minOut is a same-block quote bound — caps
    ///      single-call deviation, cannot prevent sandwiches. Returns the BALANCE DELTA: DEX-phase
    ///      buys land net of the token's own transfer tax.
    function _buyTaxToken(uint256 quoteAmount) internal returns (uint256 received) {
        IPortalTradeV2 portal = IPortalTradeV2(_getPortal());
        uint256 quoted = portal.quoteExactInput(
            IPortalTradeV2.QuoteExactInputParams({
                inputToken: quoteToken,
                outputToken: taxToken,
                inputAmount: quoteAmount
            })
        );
        require(quoted != 0, unicode"Buyback quote is zero / 回購報價為零");
        uint256 minOut = (quoted * (BPS_DENOMINATOR - maxSlippageBps)) / BPS_DENOMINATOR;

        uint256 balanceBefore = IERC20(taxToken).balanceOf(address(this));
        uint256 value;
        if (quoteToken == address(0)) {
            value = quoteAmount;
        } else {
            IERC20(quoteToken).forceApprove(address(portal), quoteAmount);
        }
        portal.swapExactInput{value: value}(
            IPortalTradeV2.ExactInputParams({
                inputToken: quoteToken,
                outputToken: taxToken,
                inputAmount: quoteAmount,
                minOutputAmount: minOut,
                permitData: ""
            })
        );
        received = IERC20(taxToken).balanceOf(address(this)) - balanceBefore;
    }

    /// @dev ERC20 quote only. When the BNB gas pool is below gasThreshold, swaps just enough quote
    ///      to bring it to gasRefillAmount (capped by pendingQuote) through Flap's MultiDexRouter:
    ///        venue: taxToken.taxProcessor().swapRegistry() -> multiDexRouter() / weth();
    ///        dexId: Portal.getQuoteTokenConfiguration(quote).dexId;
    ///        pool:  the V3 fee tier with the best quote among getDEXInfo(dexId).v3SupportedFees.
    ///      minOut is the same-block quote x (1 - maxSlippageBps). No pool -> skip with an event.
    ///      Sizing uses no external price reference by design (the same quoter that prices the
    ///      swap also sizes it) — MAX_REFILL_SHARE_BPS bounds the resulting per-batch loss under
    ///      pool manipulation to 20% of pendingQuote, independent of how far the estimate is off.
    ///      Venue resolution (swapVenue()) is wrapped in try/catch: a revert anywhere in the
    ///      taxProcessor -> swapRegistry -> router/weth -> Portal quote-config chain degrades to
    ///      GasRefillSkipped rather than bricking process() for every call while the gas pool is
    ///      low. The outflow itself is equally isolated: it lives in executeGasRefill, a self-call
    ///      under try/catch, so a swap that reverts (an RWA transfer restriction toward the pool, a
    ///      venue that prices a swap it will not execute) degrades to GasRefillSkipped and the
    ///      buyback still runs on the untouched batch. Rule 010 holds because the pendingQuote
    ///      decrement sits in the same function as the outflow and reverts with it.
    function _refillGas() internal {
        if (quoteToken == address(0)) return;
        uint256 gasBal = address(this).balance;
        if (gasBal >= gasThreshold) return;
        uint256 needed = gasRefillAmount - gasBal;
        uint256 available = pendingQuote;

        address routerAddr;
        address wbnb;
        uint8 dexId;
        try this.swapVenue() returns (address r, address w, uint8 d) {
            routerAddr = r;
            wbnb = w;
            dexId = d;
        } catch {
            emit GasRefillSkipped(available);
            return;
        }
        if (routerAddr == address(0) || wbnb == address(0)) {
            emit GasRefillSkipped(available);
            return;
        }
        IMultiDexRouter router = IMultiDexRouter(routerAddr);

        (uint24 fee, uint256 outForAll) = _bestPool(router, wbnb, dexId, available);
        if (outForAll == 0) {
            emit GasRefillSkipped(available);
            return;
        }
        uint256 quoteIn =
            outForAll > needed ? Math.mulDiv(available, needed, outForAll, Math.Rounding.Up) : available;
        uint256 cap = (available * MAX_REFILL_SHARE_BPS) / BPS_DENOMINATOR;
        if (quoteIn > cap) quoteIn = cap;
        // MAX_REFILL_SHARE_BPS keeps quoteIn strictly below `available`, so the sized amount is
        // always re-quoted at its own size — never reused from the full-amount outForAll quote.
        uint256 quoted = _quoteOut(router, wbnb, dexId, fee, quoteIn);
        if (quoteIn == 0 || quoted == 0) {
            emit GasRefillSkipped(available);
            return;
        }
        uint256 minOut = (quoted * (BPS_DENOMINATOR - maxSlippageBps)) / BPS_DENOMINATOR;

        try this.executeGasRefill(address(router), wbnb, dexId, fee, quoteIn, minOut) returns (uint256 got) {
            emit GasRefilled(quoteIn, got, fee);
        } catch {
            // The whole outflow — the pendingQuote decrement included — rolled back with the swap.
            emit GasRefillSkipped(available);
        }
    }

    /// @notice Performs the gas-refill outflow: sells `quoteIn` of the quote token for WBNB on
    ///         `router` and unwraps it into the vault's BNB gas pool. ONLY the vault itself may call
    ///         it; `_refillGas` self-calls it through try/catch so a reverting swap cannot brick the
    ///         buyback leg of process().
    /// @dev Rule 010: the pendingQuote decrement is the FIRST statement and lives in the same
    ///      function as the outflow, so a revert anywhere below (approve, swap, unwrap) reverts the
    ///      decrement with it — the baseline can never drift from the balance.
    ///      The allowance is zeroed after the swap: the router is re-resolved from a mutable
    ///      registry on every call, so no allowance may stand for a stale or replaced venue.
    ///      The closing unwrap runs under _unwrapping: real WBNB pays out with transfer() (2300 gas),
    ///      and the flag makes receive() return before it touches storage or calls out, which is the
    ///      only way the callback fits that budget (see receive()).
    function executeGasRefill(address router, address wbnb, uint8 dexId, uint24 fee, uint256 quoteIn, uint256 minOut)
        external
        returns (uint256 got)
    {
        require(msg.sender == address(this), unicode"Caller must be the vault itself / 僅限金庫自身調用");
        pendingQuote -= quoteIn;
        IERC20(quoteToken).forceApprove(router, quoteIn);
        got = IMultiDexRouter(router).exactInputSingle(
            dexId,
            IMultiDexRouter.ExactInputSingleParams({
                tokenIn: quoteToken,
                tokenOut: wbnb,
                fee: fee,
                recipient: address(this),
                amountIn: quoteIn,
                amountOutMinimum: minOut,
                sqrtPriceLimitX96: 0
            })
        );
        IERC20(quoteToken).forceApprove(router, 0);
        _unwrapping = true;
        IWBNB(wbnb).withdraw(got); // pays BNB into receive(); the flag suppresses accounting there
        _unwrapping = false;
    }

    /// @notice Resolves the gas-refill swap venue: the Flap MultiDexRouter and wrapped-native token
    ///         behind this vault's taxToken, plus the Portal's configured dexId for this quote
    ///         token. Public so `this.swapVenue()` can be called through try/catch from
    ///         `_refillGas` (a revert here degrades to GasRefillSkipped, never bricks process()).
    function swapVenue() public view returns (address router, address wbnb, uint8 dexId) {
        ISwapRegistry registry = ISwapRegistry(ITaxProcessor(IFlapTaxTokenV3(taxToken).taxProcessor()).swapRegistry());
        router = registry.multiDexRouter();
        wbnb = registry.weth();
        dexId = IPortalQuoteConfigU8(_getPortal()).getQuoteTokenConfiguration(quoteToken).dexId;
    }

    /// @dev Best V3 quote/WBNB tier for `amountIn`. A tier is considered only if its pool has code;
    ///      a reverting quoter call on one tier never blocks the others.
    function _bestPool(IMultiDexRouter router, address wbnb, uint8 dexId, uint256 amountIn)
        internal
        returns (uint24 bestFee, uint256 bestOut)
    {
        if (amountIn == 0) return (0, 0);
        uint24[] memory fees = router.getDEXInfo(dexId).v3SupportedFees;
        for (uint256 i = 0; i < fees.length; i++) {
            if (router.computeV3PoolAddress(dexId, quoteToken, wbnb, fees[i]).code.length == 0) continue;
            uint256 out = _quoteOut(router, wbnb, dexId, fees[i], amountIn);
            if (out > bestOut) {
                bestOut = out;
                bestFee = fees[i];
            }
        }
    }

    function _quoteOut(IMultiDexRouter router, address wbnb, uint8 dexId, uint24 fee, uint256 amountIn)
        internal
        returns (uint256 out)
    {
        try router.quoteExactInputSingle(
            dexId,
            IMultiDexRouter.QuoteExactInputSingleParams({
                tokenIn: quoteToken,
                tokenOut: wbnb,
                amountIn: amountIn,
                fee: fee,
                sqrtPriceLimitX96: 0
            })
        ) returns (uint256 amountOut, uint160, uint32, uint256) {
            out = amountOut;
        } catch {
            out = 0;
        }
    }

    function _ensurePoolExists() internal {
        PoolMetadata memory pool = poolManager.getPool(poolId);
        // basePoolToken is the deposit-readiness signal: myx deployPool atomically deploys the LP
        // token, so a registered pool always has it set.
        if (pool.basePoolToken == address(0)) {
            poolManager.deployPool(IMyxPoolManager.DeployPoolParams({marketId: marketId, baseToken: taxToken}));
            emit PoolDeployed(poolId);
        }
    }

    function _nativeSymbol() internal view returns (string memory) {
        return block.chainid == 4663 ? "ETH" : "BNB";
    }

    /// @dev DISPLAY ONLY. symbol() and decimals() are optional in EIP-20 and a quote token is free
    ///      to omit them or revert; description() is a UI read, so it degrades to "?" rather than
    ///      reverting. Nothing in the accounting or swap path reads these — quote amounts are always
    ///      handled in base units.
    function _quoteSymbol() internal view returns (string memory) {
        if (quoteToken == address(0)) return _nativeSymbol();
        try IERC20Metadata(quoteToken).symbol() returns (string memory sym) {
            return sym;
        } catch {
            return "?";
        }
    }

    /// @dev DISPLAY ONLY, same contract as _quoteSymbol: the fallback is 18, the EIP-20 default.
    function _quoteDecimals() internal view returns (uint8) {
        if (quoteToken == address(0)) return 18;
        try IERC20Metadata(quoteToken).decimals() returns (uint8 dec) {
            return dec;
        } catch {
            return 18;
        }
    }

    function description() public view override returns (string memory) {
        string memory sym = _quoteSymbol();
        string memory head = string.concat(
            unicode"MYX liquidity vault / MYX 流動性金庫: ",
            Decimal18.toString(totalLpMinted),
            unicode" LP minted / LP 已鑄造, ",
            Decimal18.toString(totalRewardsForwarded),
            unicode" LP distributed / LP 已分發, pending ",
            sym,
            unicode" / 待處理 ",
            sym,
            ": ",
            Decimal18.toString(pendingQuote, _quoteDecimals())
        );
        if (quoteToken == address(0)) return string.concat(head, ".");
        return string.concat(
            head, unicode", gas pool / Gas 池: ", Decimal18.toString(address(this).balance), " ", _nativeSymbol(), "."
        );
    }

    /// @inheritdoc VaultBaseV2
    /// @dev Delegated to the linked MyxVaultUISchema library to keep the vault under EIP-170.
    function vaultUISchema() public pure override returns (VaultUISchema memory schema) {
        return MyxVaultUISchema.build();
    }
}
