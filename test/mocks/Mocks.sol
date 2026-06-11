// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {ERC20} from "@openzeppelin/token/ERC20/ERC20.sol";
import {IERC20} from "@openzeppelin/token/ERC20/IERC20.sol";

contract MockERC20 is ERC20 {
    constructor(string memory n, string memory s) ERC20(n, s) {}
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
    receive() external payable { _mint(msg.sender, msg.value); }
}

contract MockAggregatorV3 {
    int256 public answer;
    uint8 public immutable decimals_;
    constructor(int256 _answer, uint8 _decimals) { answer = _answer; decimals_ = _decimals; }
    function setAnswer(int256 a) external { answer = a; }
    function decimals() external view returns (uint8) { return decimals_; }
    function latestRoundData() external view returns (uint80, int256, uint256, uint256, uint80) {
        return (1, answer, block.timestamp, block.timestamp, 1);
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

contract MockDividendDistributor {
    IERC20 public immutable wbnb;
    uint256 public totalDeposited;
    bool public depositSucceeds = true;
    mapping(address => uint256) public pendingOf;
    constructor(address _wbnb) { wbnb = IERC20(_wbnb); }
    function setDepositSucceeds(bool v) external { depositSucceeds = v; }
    function deposit(uint256 amount) external returns (bool) {
        if (!depositSucceeds) return false; // mirrors real contract: false, not revert
        wbnb.transferFrom(msg.sender, address(this), amount);
        totalDeposited += amount;
        return true;
    }
    function setPending(address user, uint256 amount) external { pendingOf[user] = amount; }
    function withdrawableDividends(address user) external view returns (uint256) { return pendingOf[user]; }
}

contract MockTaxToken is ERC20 {
    address public dividendContract;
    constructor(address _dividend) ERC20("Mock Tax Token", "MTT") { dividendContract = _dividend; }
}
