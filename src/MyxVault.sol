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
import {Decimal18} from "./lib/Decimal18.sol";
import {IFlapTriggerService, ITriggerReceiver} from "./flap/IFlapTriggerService.sol";

/// @title MyxVault
/// @notice Flap vault that buys back the tax token with tax revenue via the Flap Portal, deposits
///         it as MYX base-pool liquidity, and feeds the resulting mBase LP into the token's
///         native Flap Dividend contract — the LP ITSELF is the dividend asset.
/// @dev v6 reward model: tax BNB → receive() accounting → process() [permissionless]
///      buys back the token via the Portal, deposits it into the MYX base pool (LP minted to the
///      vault), then _feedDividend deposits the LP into the Dividend contract whose dividendToken ==
///      that same mBase LP (wired at launch). Holders claim the mBase LP via
///      the dividend (fairly, via Flap setShare hooks), then earn myx rebates by holding it.
/// @dev Invariants:
///      - receive() does accounting (pendingBnb += msg.value) then best-effort schedules a delayed
///        process() via FlapTriggerService in try/catch; accounting is the Rule-005 core and the
///        schedule never reverts receive() (deliberate Rule-005 deviation, see auto-trigger doc).
///      - process() is permissionless: anyone may convert pending BNB into liquidity + dividend.
///      - The LP IS the dividend asset: dividendToken == basePoolToken == mBase. _feedDividend
///        deposits the whole held LP balance; if the dividend is unwired or deposit() returns false
///        (totalShares == 0 early window), the LP is RETAINED (DividendDeferred) — no swap, no
///        price feed, no fallback path. Anti-fallback: retry via feedDividend() or next process().
///      - Guardian roles cannot be revoked by any other account; only the guardian itself may
///        voluntarily renounce (Flap mandate).
contract MyxVault is VaultBaseV2, Initializable, AccessControlUpgradeable, ReentrancyGuardUpgradeable, ITriggerReceiver {
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
    /// @notice Delay between a tax receipt and the auto-scheduled process() (seconds).
    uint64 public constant PROCESS_DELAY = 60;

    event RevenueReceived(uint256 amount, uint256 pendingTotal);
    event RevenueProcessed(uint256 bnbAmount, uint256 baseAmount, uint256 lpMinted);
    event PoolDeployed(PoolId poolId);
    /// @notice Emitted when the vault's mBase LP balance is successfully fed into the Dividend
    ///         contract. `lpFed` is the LP amount distributed to holders.
    event DividendFed(uint256 lpFed);
    /// @notice Emitted when a feed is deferred (dividend not wired yet, or deposit() returned false
    ///         because totalShares == 0 in the early window). LP is retained for retry.
    event DividendDeferred(uint256 lpAmount);
    event EmergencyWithdrawal(uint256 lpAmount, uint256 amountOut, address to);
    event EmergencySwept(uint256 bnbAmount, address to);
    /// @notice Emitted when a stuck ERC20 is rescued to `to`. Generic escape hatch covering deferred
    ///         mBase LP, residual tax tokens, or any accidentally sent token — including cases where
    ///         the myx pool's withdraw path is unusable.
    event EmergencyTokenRescued(address indexed token, address to, uint256 amount);
    /// @notice Emitted when receive() schedules a delayed process() via FlapTriggerService.
    event ProcessScheduled(uint256 requestId, uint64 executeAfter);
    /// @notice Emitted when the trigger callback runs; `success` is process()'s try/catch outcome.
    event ProcessTriggered(uint256 requestId, bool success);

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

    uint256 public pendingBnb;
    uint256 public totalLpMinted;
    uint256 public totalRewardsForwarded;

    /// @notice Last FlapTriggerService request id scheduled by receive(); meaningful only while
    ///         `hasPendingTrigger`. `hasPendingTrigger` is the in-flight gate (true => receive() skips
    ///         a duplicate schedule); kept separate from the id so service ids starting at 0 are safe.
    uint256 public pendingTriggerId;
    bool public hasPendingTrigger;

    /// @dev Reserved storage for upgrades. Reduced from 44 to 42 for the two slots added above.
    uint256[42] private __gap;

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

        address guardian = _getGuardian();
        _grantRole(DEFAULT_ADMIN_ROLE, guardian);
        _grantRole(EMERGENCY_ROLE, guardian);
        _grantRole(EMERGENCY_ROLE, p.creator);
    }

    /// @dev Accounting + best-effort auto-schedule. Accounting (pendingBnb += msg.value) runs first
    ///      and is the Rule-005 core. Scheduling a delayed process() via FlapTriggerService is wrapped
    ///      in try/catch (self-call) so ANY scheduling failure — service down, fee insufficient, OOG —
    ///      degrades to "not scheduled" and NEVER reverts receive() or loses tax. The external call is
    ///      a deliberate Rule-005 deviation (see auto-trigger design doc); never-revert is preserved.
    receive() external payable {
        pendingBnb += msg.value;
        emit RevenueReceived(msg.value, pendingBnb);
        if (!hasPendingTrigger && pendingBnb >= minProcessAmount) {
            try this.scheduleProcess() {} catch {}
        }
    }

    /// @notice Schedules a delayed process() via FlapTriggerService. ONLY the vault itself may call
    ///         it (from receive()); the self-call lets receive() wrap getFee()+requestTrigger in one
    ///         try/catch. The fee is paid from tax revenue: pendingBnb is debited ONLY on a successful
    ///         schedule, preserving the (vault BNB balance == pendingBnb) invariant.
    function scheduleProcess() external {
        require(msg.sender == address(this), unicode"Caller must be the vault itself / 僅限金庫自身調用");
        IFlapTriggerService service = IFlapTriggerService(_getTriggerService());
        uint256 fee = service.getFee();
        // Decide on ACCUMULATED pendingBnb (not a single receipt): it must cover the fee AND still
        // leave >= minProcessAmount so the scheduled process() can actually run — no wasted fee, and
        // pendingBnb -= fee can never underflow.
        require(pendingBnb >= minProcessAmount + fee, unicode"Pending below minimum plus fee / 待處理低於下限加手續費");
        uint64 executeAfter = uint64(block.timestamp) + PROCESS_DELAY;
        uint256 id = service.requestTrigger{value: fee}(executeAfter);
        pendingTriggerId = id;
        hasPendingTrigger = true;
        pendingBnb -= fee;
        emit ProcessScheduled(id, executeAfter);
    }

    /// @notice FlapTriggerService callback (ITriggerReceiver). Clears the in-flight gate FIRST, then
    ///         runs process() under try/catch so a revert (e.g. pendingBnb already drained below the
    ///         minimum by a permissionless process()) cannot deadlock scheduling — the next tax
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

    /// @dev FlapTriggerService address per chain — hardcoded like _getPortal/_getGuardian. The BSC
    ///      testnet address is pending (see auto-trigger design doc open items).
    function _getTriggerService() internal view returns (address) {
        if (block.chainid == 56) return 0xcf4EE25035CF883895110f367F5BA8172416a7F9;
        else if (block.chainid == 97) return 0x560E9830926C9e0EB98a59c6b9902383Fc0D9Eb2;
        revert(unicode"Trigger service not configured / 觸發服務未配置");
    }

    /// @dev Flap mandate: the Guardian role must not be revocable by anyone else.
    function revokeRole(bytes32 role, address account) public override onlyRole(getRoleAdmin(role)) {
        require(account != _getGuardian(), unicode"Guardian role cannot be revoked / 守護者角色不可撤銷");
        super.revokeRole(role, account);
    }

    /// @notice Converts accumulated BNB into MYX base-pool liquidity by buying back the tax token
    ///         via the Flap Portal, then feeds the resulting mBase LP into the token's dividend
    ///         contract. PERMISSIONLESS — anyone may run it.
    /// @dev Buy leg minOut is a same-block Portal quote × (1 - maxSlippageBps): bounds per-call
    ///      deviation but cannot prevent sandwiching (BSC block proposers reorder at no cost).
    ///      Consumes ALL pendingBnb; the LP IS the reward (v6 model).
    function process() external nonReentrant {
        uint256 amount = pendingBnb;
        require(amount >= minProcessAmount, unicode"Pending below minimum / 待處理金額低於下限");
        pendingBnb = 0;

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

    /// @notice Sweeps stuck native BNB. Disaster recovery only (e.g. process() permanently broken).
    function emergencySweepBnb(address to) external nonReentrant onlyRole(EMERGENCY_ROLE) {
        uint256 amount = address(this).balance;
        pendingBnb = 0;
        (bool ok,) = to.call{value: amount}("");
        require(ok, unicode"BNB sweep failed / BNB 清退失敗");
        emit EmergencySwept(amount, to);
    }

    /// @notice Rescues the full balance of any stuck ERC20 to `to`. Disaster recovery only.
    ///         Generic escape hatch for deferred mBase LP (retained when the dividend stays unwired
    ///         or totalShares == 0 indefinitely) and residual tax tokens from a failed buyback —
    ///         covering cases where emergencyWithdraw is unusable (myx pool withdraw path broken).
    function emergencyRescueToken(address token, address to) external nonReentrant onlyRole(EMERGENCY_ROLE) {
        require(token != address(0) && to != address(0), unicode"Zero address / 零地址");
        uint256 bal = IERC20(token).balanceOf(address(this));
        if (bal > 0) {
            IERC20(token).safeTransfer(to, bal);
            emit EmergencyTokenRescued(token, to, bal);
        }
    }

    /// @dev BNB → taxToken via the Flap Portal (bonding curve or DEX phase, Portal routes).
    ///      minOut is a same-block quote bound — caps single-call deviation, cannot prevent sandwiches.
    ///      Returns the BALANCE DELTA (not the Portal return value): DEX-phase buys land net of the
    ///      token's own transfer tax (docs/phase0-v3-findings.md).
    function _buyTaxToken(uint256 bnbAmount) internal returns (uint256 received) {
        IPortalTradeV2 portal = IPortalTradeV2(_getPortal());
        uint256 quoted = portal.quoteExactInput(
            IPortalTradeV2.QuoteExactInputParams({
                inputToken: address(0),
                outputToken: taxToken,
                inputAmount: bnbAmount
            })
        );
        require(quoted != 0, unicode"Buyback quote is zero / 回購報價為零");
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
        // basePoolToken is the deposit-readiness signal: myx deployPool atomically deploys the LP
        // token, so a registered pool always has it set.
        if (pool.basePoolToken == address(0)) {
            poolManager.deployPool(IMyxPoolManager.DeployPoolParams({marketId: marketId, baseToken: taxToken}));
            emit PoolDeployed(poolId);
        }
    }

    function description() public view override returns (string memory) {
        return string.concat(
            unicode"MYX liquidity vault / MYX 流動性金庫: ",
            Decimal18.toString(totalLpMinted),
            unicode" LP minted / LP 已鑄造, ",
            Decimal18.toString(totalRewardsForwarded),
            unicode" LP distributed / LP 已分發, pending BNB / 待處理 BNB: ",
            Decimal18.toString(pendingBnb),
            "."
        );
    }

    function vaultUISchema() public pure override returns (VaultUISchema memory schema) {
        schema.vaultType = "MyxVault";
        schema.description =
            unicode"Tax revenue is converted to MYX LP and distributed to holders as dividends. / 稅收轉換為 MYX LP，作為分紅分配給持幣者。";
        schema.methods = new VaultMethodSchema[](5);

        schema.methods[0].name = "pendingBnb";
        schema.methods[0].description = unicode"Tax revenue awaiting processing. / 待處理的稅收金額。";
        schema.methods[0].outputs = new FieldDescriptor[](1);
        schema.methods[0].outputs[0] = FieldDescriptor("amount", "uint256", "BNB amount", 18);

        schema.methods[1].name = "process";
        schema.methods[1].description =
            unicode"Buy back the token with pending BNB, deposit into MYX pool, and feed LP to dividends. Permissionless. / 用待處理 BNB 回購代幣，注入 MYX 池並將 LP 分發為分紅。任何人可調用。";
        schema.methods[1].isWriteMethod = true;

        schema.methods[2].name = "feedDividend";
        schema.methods[2].description =
            unicode"Feed held mBase LP into the dividend contract. Permissionless; retries a deferred feed. / 將持有的 mBase LP 注入分紅合約。任何人可調用，可重試延遲分發。";
        schema.methods[2].isWriteMethod = true;

        schema.methods[3].name = "claimReward";
        schema.methods[3].description =
            unicode"Claim your mBase LP dividend. You may also claim directly on the dividend contract. / 領取您的 mBase LP 分紅，也可直接在分紅合約上領取。";
        schema.methods[3].isWriteMethod = true;

        schema.methods[4].name = "pendingReward";
        schema.methods[4].description = unicode"Claimable mBase LP dividend for a holder. / 持幣者可領取的 mBase LP 分紅金額。";
        schema.methods[4].inputs = new FieldDescriptor[](1);
        schema.methods[4].inputs[0] = FieldDescriptor("user", "address", "Holder address", 0);
        schema.methods[4].outputs = new FieldDescriptor[](1);
        schema.methods[4].outputs[0] = FieldDescriptor("amount", "uint256", "Claimable LP amount", 18);
    }
}
