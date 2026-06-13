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
contract MyxVault is VaultBaseV2, Initializable, AccessControlUpgradeable, ReentrancyGuardUpgradeable {
    using SafeERC20 for IERC20;

    struct InitParams {
        address taxToken;
        address creator;
        MarketId marketId;
        address poolManager;
        address basePool;
        uint16 maxSlippageBps;
        uint256 minProcessAmount;
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
    error NotAuthorizedInManualMode();
    error NotModeAdmin();

    event RevenueReceived(uint256 amount, uint256 pendingTotal);
    event ModeChanged(Mode newMode);
    event RevenueProcessed(uint256 bnbAmount, uint256 baseAmount, uint256 lpMinted);
    event PoolDeployed(PoolId poolId);
    event Harvested(uint256 rebateAmount, uint256 forwarded);
    event EmergencyWithdrawal(uint256 lpAmount, uint256 amountOut, address to);
    event EmergencySwept(uint256 bnbAmount, address to);

    address public taxToken;
    address public creator;
    MarketId public marketId;
    PoolId public poolId;
    IMyxPoolManager public poolManager;
    IMyxBasePool public basePool;
    uint16 public maxSlippageBps;
    uint256 public minProcessAmount;

    enum Mode { AUTO, MANUAL }

    uint256 public pendingBnb;
    uint256 public totalLpMinted;
    uint256 public totalRewardsForwarded;
    Mode public mode;

    /// @dev Reserved storage to allow inserting parent mixins or new variables in upgrades.
    ///      v4 removed 6 address/feed slots (swapRouter, wbnb, quoteToken, bnbUsdFeed,
    ///      usdtUsdFeed, maxPriceStaleness) from storage; gap bumped 36 -> 42 to keep the
    ///      total reserved layout tidy (contract not yet deployed).
    uint256[42] private __gap;

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
    /// @dev In AUTO mode this is permissionless and the buy leg's minOut derives from a
    ///      same-block Portal quote — it bounds per-call deviation to maxSlippageBps but
    ///      cannot prevent sandwiching (BSC block proposers can reorder at no cost). For
    ///      sandwich-sensitive operation switch to MANUAL and submit via a private relay.
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
    ///         token's native Dividend contract. Permissionless.
    function harvest() external nonReentrant {
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
        schema.methods[3].description =
            "Claim LP rebates and distribute them directly to holders via the dividend contract. Anyone can call.";
        schema.methods[3].isWriteMethod = true;

        schema.methods[4].name = "pendingReward";
        schema.methods[4].description = "Claimable dividend for a holder (claim on the token's dividend contract).";
        schema.methods[4].inputs = new FieldDescriptor[](1);
        schema.methods[4].inputs[0] = FieldDescriptor("user", "address", "Holder address", 0);
        schema.methods[4].outputs = new FieldDescriptor[](1);
        schema.methods[4].outputs[0] = FieldDescriptor("amount", "uint256", "Claimable WBNB amount", 18);
    }
}
