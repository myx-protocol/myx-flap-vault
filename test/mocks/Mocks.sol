// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {ERC20} from "@openzeppelin/token/ERC20/ERC20.sol";
import {IERC20} from "@openzeppelin/token/ERC20/IERC20.sol";
import {IMyxBasePool, IMyxPoolManager, PoolMetadata, PoolId, MarketId} from "../../src/myx/IMyxPool.sol";
import {IPortalTradeV2} from "../../src/flap/IPortal.sol";
import {ITriggerReceiver} from "../../src/flap/IFlapTriggerService.sol";

contract MockERC20 is ERC20 {
    constructor(string memory n, string memory s) ERC20(n, s) {}
    function mint(address to, uint256 amount) external { _mint(to, amount); }
}

contract MockERC20Decimals is ERC20 {
    uint8 private immutable _dec;
    constructor(string memory n, string memory s, uint8 d) ERC20(n, s) { _dec = d; }
    function decimals() public view override returns (uint8) { return _dec; }
    function mint(address to, uint256 amount) external { _mint(to, amount); }
}

contract MockWBNB is ERC20 {
    constructor() ERC20("Wrapped BNB", "WBNB") {}
    function deposit() external payable { _mint(msg.sender, msg.value); }
    function withdraw(uint256 wad) external {
        _burn(msg.sender, wad);
        (bool ok,) = msg.sender.call{value: wad}("");
        require(ok, "MockWBNB: send failed");
    }
    /// @dev Required so MockPancakeRouter can mint WBNB as a swap output token.
    function mint(address to, uint256 amount) external { _mint(to, amount); }
    receive() external payable { _mint(msg.sender, msg.value); }
}

contract MockAggregatorV3 {
    int256 public answer;
    uint8 public immutable decimals_;
    uint256 public updatedAtOverride; // 0 => report block.timestamp (fresh)
    constructor(int256 _answer, uint8 _decimals) { answer = _answer; decimals_ = _decimals; }
    function setAnswer(int256 a) external { answer = a; }
    function setUpdatedAt(uint256 t) external { updatedAtOverride = t; }
    function decimals() external view returns (uint8) { return decimals_; }
    function latestRoundData() external view returns (uint80, int256, uint256, uint256, uint80) {
        uint256 ts = updatedAtOverride == 0 ? block.timestamp : updatedAtOverride;
        return (1, answer, ts, ts, 1);
    }
}

/// @dev Swaps at a fixed rate: amountOut = amountIn * rateNum / rateDen.
contract MockPancakeRouter {
    uint256 public rateNum = 1;
    uint256 public rateDen = 1;
    function setRate(uint256 num, uint256 den) external { rateNum = num; rateDen = den; }
    function swapExactTokensForTokens(
        uint256 amountIn, uint256 amountOutMin, address[] calldata path, address to, uint256
    ) external returns (uint256[] memory amounts) {
        IERC20(path[0]).transferFrom(msg.sender, address(this), amountIn);
        uint256 out = (amountIn * rateNum) / rateDen;
        require(out >= amountOutMin, "MockRouter: INSUFFICIENT_OUTPUT_AMOUNT");
        MockERC20(path[path.length - 1]).mint(to, out);
        amounts = new uint256[](path.length);
        amounts[0] = amountIn;
        amounts[path.length - 1] = out;
    }
}

/// @dev v6: the configured dividendToken is the myx base-pool LP (mBase). deposit() pulls that LP
///      via transferFrom; withdrawDividendsFor(user) claims a holder's pending LP on their behalf,
///      transferring pendingOf[user] of the dividendToken to the user so claimReward()'s effect is
///      assertable. deposit() simulates both real failure modes: returns false (depositSucceeds flag,
///      the totalShares == 0 early window) or reverts (depositReverts flag, external state not ready).
contract MockDividendDistributor {
    address public dividendToken;
    uint256 public totalDeposited;
    bool public depositSucceeds = true;
    bool public depositReverts; // simulate the real contract THROWING (vs. gracefully returning false)
    mapping(address => uint256) public pendingOf;
    constructor(address _dividendToken) { dividendToken = _dividendToken; }
    function setDividendToken(address t) external { dividendToken = t; }
    function setDepositSucceeds(bool v) external { depositSucceeds = v; }
    function setDepositReverts(bool v) external { depositReverts = v; }
    function deposit(uint256 amount) external returns (bool) {
        if (depositReverts) revert("dividend deposit reverted");
        if (!depositSucceeds) return false; // mirrors real contract: false, not revert
        IERC20(dividendToken).transferFrom(msg.sender, address(this), amount);
        totalDeposited += amount;
        return true;
    }
    function setPending(address user, uint256 amount) external { pendingOf[user] = amount; }
    function withdrawableDividends(address user) external view returns (uint256) { return pendingOf[user]; }
    /// @dev Claim-on-behalf: pays the holder its pending LP and zeroes the entry, so a
    ///      vault.claimReward() call's effect is observable in tests.
    function withdrawDividendsFor(address user) external {
        uint256 amount = pendingOf[user];
        pendingOf[user] = 0;
        if (amount > 0) IERC20(dividendToken).transfer(user, amount);
    }
}

contract MockTaxToken is ERC20 {
    address public dividendContract;
    constructor(address _dividend) ERC20("Mock Tax Token", "MTT") { dividendContract = _dividend; }
    function setDividendContract(address d) external { dividendContract = d; }
    /// @dev Required so MockPortal can mint the tax token as a buy output.
    function mint(address to, uint256 amount) external { _mint(to, amount); }
}

/// @dev Buys outputToken at a fixed rate (out = in * rateNum / rateDen), minting MockTaxToken
///      to the buyer. taxBps simulates the DEX-phase transfer tax: the buyer receives
///      out * (10000 - taxBps) / 10000 while quoteExactInput still quotes the gross amount.
contract MockPortal {
    uint256 public rateNum = 1;
    uint256 public rateDen = 1;
    uint16 public taxBps;
    function setRate(uint256 num, uint256 den) external { rateNum = num; rateDen = den; }
    function setTaxBps(uint16 t) external { taxBps = t; }

    function quoteExactInput(IPortalTradeV2.QuoteExactInputParams calldata p) external view returns (uint256) {
        return (p.inputAmount * rateNum) / rateDen;
    }

    function swapExactInput(IPortalTradeV2.ExactInputParams calldata p) external payable returns (uint256 out) {
        require(p.inputToken == address(0) && msg.value == p.inputAmount, "MockPortal: BNB in only");
        out = (p.inputAmount * rateNum) / rateDen;
        require(out >= p.minOutputAmount, "MockPortal: INSUFFICIENT_OUTPUT_AMOUNT");
        uint256 net = (out * (10_000 - taxBps)) / 10_000;
        MockTaxToken(p.outputToken).mint(msg.sender, net);
    }
}

/// @dev Mints LP 1:1 for deposits; pays rebates in quote token; tracks calls for assertions.
contract MockBasePool is IMyxBasePool {
    MockERC20 public immutable lpToken;
    MockERC20 public immutable quoteToken;
    uint256 public rebateToPay;
    uint256 public depositCallCount;
    uint256 public lastDepositAmount;
    address public lastDepositRecipient;

    constructor(MockERC20 _lp, MockERC20 _quote) {
        lpToken = _lp;
        quoteToken = _quote;
    }

    function setRebate(uint256 amount) external { rebateToPay = amount; }

    function deposit(PoolId, uint256 amountIn, uint256 minAmountOut, address, address recipient)
        external
        returns (uint256 amountOut)
    {
        // pull base token like the real pool does (token address not tracked; tests pre-fund)
        amountOut = amountIn; // 1:1 LP
        require(amountOut >= minAmountOut, "MockBasePool: slippage");
        depositCallCount += 1;
        lastDepositAmount = amountIn;
        lastDepositRecipient = recipient;
        lpToken.mint(recipient, amountOut);
    }

    function withdraw(PoolId, uint256 amountIn, uint256 minAmountOut, address, address recipient)
        external
        returns (uint256 amountOut, uint256 rebateOut)
    {
        amountOut = amountIn; // 1:1 back
        require(amountOut >= minAmountOut, "MockBasePool: slippage");
        quoteToken.mint(recipient, amountOut);
        rebateOut = 0;
    }

    function claimUserRebate(PoolId, address, address recipient) external returns (uint256 rebateOut) {
        rebateOut = rebateToPay;
        rebateToPay = 0;
        if (rebateOut > 0) quoteToken.mint(recipient, rebateOut);
    }

    function pendingUserRebates(PoolId, address, uint256) external view returns (uint256, uint256) {
        return (rebateToPay, 0);
    }
}

/// @dev Stand-in for the myx PoolFactory's authoritative CREATE2 predictor. Tests register the
///      byte-exact basePoolToken (LP / mBase) address for a (marketId, baseToken, baseSymbol) key,
///      mirroring myx's predictBasePoolToken(MarketId, address, string).
contract MockMyxPoolFactory {
    mapping(bytes32 => address) public predictions; // key = keccak(marketId, baseToken, symbol)

    function setPrediction(MarketId marketId, address baseToken, string calldata baseSymbol, address lp) external {
        predictions[keccak256(abi.encode(marketId, baseToken, baseSymbol))] = lp;
    }

    function predictBasePoolToken(MarketId marketId, address baseToken, string calldata baseSymbol)
        external
        view
        returns (address)
    {
        return predictions[keccak256(abi.encode(marketId, baseToken, baseSymbol))];
    }
}

contract MockPoolManager is IMyxPoolManager {
    mapping(bytes32 => PoolMetadata) internal pools;
    uint256 public deployPoolCallCount;
    bool public marketExists = true;
    /// @dev v6: the LP (mBase) address deployPool stamps as basePoolToken. When set to the real
    ///      mock lpToken, the vault's _feedDividend finds a live ERC20 to feed; when 0, a synthetic
    ///      non-contract address is used (faithful to "real deployPool always sets it", but feeding
    ///      against it would revert — tests exercising the feed path set this to the lpToken).
    address public lpTokenForDeploy;

    function setMarketExists(bool v) external { marketExists = v; }
    function setLpTokenForDeploy(address lp) external { lpTokenForDeploy = lp; }

    function setPool(PoolId poolId, PoolMetadata memory meta) external { pools[PoolId.unwrap(poolId)] = meta; }

    function deployPool(DeployPoolParams calldata params) external {
        require(marketExists, "MockPoolManager: market missing");
        deployPoolCallCount += 1;
        bytes32 id = keccak256(abi.encode(params.marketId, params.baseToken));
        PoolMetadata memory meta;
        meta.marketId = params.marketId;
        meta.poolId = PoolId.wrap(id);
        meta.baseToken = params.baseToken;
        // faithful: real deployPool always sets basePoolToken. Use the configured LP when provided
        // so the vault's v6 _feedDividend can pull a live ERC20; else a deterministic synthetic addr.
        meta.basePoolToken =
            lpTokenForDeploy != address(0) ? lpTokenForDeploy : address(uint160(uint256(id)));
        pools[id] = meta;
    }

    function getPool(PoolId poolId) external view returns (PoolMetadata memory) {
        return pools[PoolId.unwrap(poolId)];
    }
}

/// @dev Mock of Flap's FlapTriggerService, etched at the address MyxVault._getTriggerService() returns
///      on chainId 56. vm.etch zeroes storage, so tests MUST call setFee() after etching. requestTrigger
///      ids start at 1; fire() simulates the Flap backend executing the callback after executeAfter.
contract MockFlapTriggerService {
    uint256 internal feeWei;
    uint256 public lastRequestId;
    uint64 public lastExecuteAfter;
    bool public requestReverts;
    mapping(uint256 => address) public requesterOf;

    function setFee(uint256 f) external { feeWei = f; }
    function setRequestReverts(bool v) external { requestReverts = v; }
    function getFee() external view returns (uint256) { return feeWei; }
    function getMaxCallbackGas() external pure returns (uint256) { return 5_000_000; }

    function requestTrigger(uint64 executeAfter) external payable returns (uint256 requestId) {
        if (requestReverts) revert("trigger service unavailable");
        require(msg.value >= feeWei, "insufficient fee");
        requestId = ++lastRequestId; // ids start at 1
        lastExecuteAfter = executeAfter;
        requesterOf[requestId] = msg.sender;
    }

    /// @dev Test helper: simulate the Flap backend firing the callback.
    function fire(uint256 requestId) external {
        ITriggerReceiver(requesterOf[requestId]).trigger(requestId);
    }
}
