// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.26;

import {console2} from "forge-std/Test.sol";
import {IERC20} from "@openzeppelin/token/ERC20/IERC20.sol";
import {FlapBSCFixture} from "./FlapBSCFixture.sol";
import {IVaultPortalTypes} from "../src/flap/IVaultPortal.sol";
import {MAGIC_DIVIDEND_COMPUTED, IPortalTradeV2} from "../src/flap/IPortal.sol";
import {IFlapTaxTokenV3} from "../src/flap/IFlapTaxTokenV3.sol";
import {ITaxProcessor} from "../src/flap/ITaxProcessor.sol";
import {MyxVault} from "../src/MyxVault.sol";
import {MyxVaultFactory} from "../src/MyxVaultFactory.sol";
import {MarketId} from "../src/myx/IMyxPool.sol";
import {MockERC20, MockBasePool, MockPoolManager} from "./mocks/Mocks.sol";

/// @dev Minimal stand-in for the myx PoolFactory: answers every predictBasePoolToken query with a
///      fixed, real ERC20 so the VaultPortal's v2.3 resolveDividendToken callback returns a token
///      the live launch path accepts.
contract FixedLpPredictor {
    address public immutable lp;

    constructor(address _lp) {
        lp = _lp;
    }

    function predictBasePoolToken(MarketId, address, string calldata) external view returns (address) {
        return lp;
    }
}

/// @notice BSC mainnet fork: NVDAB (bStock) quote end to end against the REAL VaultPortal, Portal,
///         TaxProcessor (ERC20 payout + ping), SwapRegistry and MultiDexRouter. Only myx is mocked.
contract MyxVaultErc20QuoteForkTest is FlapBSCFixture {
    address internal constant BSC_USDT = 0x55d398326f99059fF775485246999027B3197955;
    address internal constant NVDAB = 0x02Fca66C1D1aFB4E2A7884261eB00F63598a7436;

    MyxVaultFactory internal factory;
    MockPoolManager internal poolManager;
    MockBasePool internal basePool;
    MockERC20 internal usdt;
    MockERC20 internal lpToken;
    uint256 internal saltNonce;

    function setUp() public {
        _forkBSCMainnet();
        usdt = new MockERC20("Tether", "USDT");
        lpToken = new MockERC20("MYX LP", "MLP");
        basePool = new MockBasePool(lpToken, usdt);
        poolManager = new MockPoolManager();
        poolManager.setLpTokenForDeploy(address(lpToken));
        factory = new MyxVaultFactory(
            MyxVaultFactory.GlobalConfig({
                poolManager: address(poolManager),
                basePool: address(basePool),
                poolFactory: address(new FixedLpPredictor(BSC_USDT)),
                maxSlippageBps: 500,
                minInitialGas: 0.002 ether
            })
        );
        deal(NVDAB, address(this), 1_000 ether);
        IERC20(NVDAB).approve(address(vaultPortal), type(uint256).max);
        IERC20(NVDAB).approve(address(portal), type(uint256).max);
        vm.deal(address(this), 1 ether);
    }

    /// @dev A salt whose predicted token address is both vanity-7777 and UNUSED on mainnet. The
    ///      VanityHelper salt is seeded from block.number, which on a pinned fork collides with
    ///      tokens already staged on mainnet (TokenAlreadyStaged).
    function _freshSalt() internal returns (bytes32 salt) {
        salt = keccak256(abi.encode(address(this), block.timestamp, saltNonce++, "myx-erc20"));
        while (true) {
            address predicted = _predictAddress(TOKEN_IMPL_TAXED_V3, salt, PORTAL);
            if (_endsWith7777(predicted) && predicted.code.length == 0) return salt;
            salt = bytes32(uint256(salt) + 1);
        }
    }

    function _launch() internal returns (address token, MyxVault vault) {
        // vaultData: myx market quote, 1 NVDAB min, refill below 0.005 BNB up to 0.01 BNB
        bytes memory vaultData = abi.encode(BSC_USDT, uint256(1 ether), uint256(0.005 ether), uint256(0.01 ether));
        IVaultPortalTypes.NewTokenV6WithVaultParams memory p =
            _buildV3TaxTokenParams("Myx RWA Vault Token", "MRV", _freshSalt(), address(factory), vaultData);
        p.quoteToken = NVDAB;
        p.quoteAmt = 0;
        p.dividendToken = MAGIC_DIVIDEND_COMPUTED;
        factory.prepayGas{value: 0.003 ether}();
        token = vaultPortal.newTokenV6WithVault(p);
        vault = MyxVault(payable(vaultPortal.getVault(token).vault));
    }

    function test_erc20Quote_endToEnd() public {
        (address token, MyxVault vault) = _launch();
        assertEq(vault.vaultQuoteToken(), NVDAB);
        assertEq(vault.gasBalance(), 0.003 ether, "prepaid gas forwarded at launch");
        assertEq(factory.prepaidGas(address(this)), 0);

        // trade in NVDAB to generate tax
        uint256 got = portal.swapExactInput{gas: MAX_OP_GAS}(
            IPortalTradeV2.ExactInputParams({
                inputToken: NVDAB, outputToken: token, inputAmount: 100 ether, minOutputAmount: 0, permitData: ""
            })
        );
        IERC20(token).approve(address(portal), got / 2);
        portal.swapExactInput{gas: MAX_OP_GAS}(
            IPortalTradeV2.ExactInputParams({
                inputToken: token, outputToken: NVDAB, inputAmount: got / 2, minOutputAmount: 0, permitData: ""
            })
        );

        // real dispatch: ERC20 payout + zero-value ping under the 1M cap
        address tp = IFlapTaxTokenV3(token).taxProcessor();
        uint256 expected = ITaxProcessor(tp).marketQuoteBalance();
        assertGt(expected, 1 ether, "enough tax to clear minProcessAmount");
        _dispatchTax(token);
        assertEq(vault.pendingQuote(), expected, "ping recognized the ERC20 revenue");
        assertTrue(vault.hasPendingTrigger(), "gas pool paid the trigger fee");
        assertLt(vault.gasBalance(), 0.003 ether);

        // process: gas pool is below 0.005 -> refill via Flap MultiDexRouter, then buy back + deposit
        uint256 gasBefore = vault.gasBalance();
        vm.prank(makeAddr("keeper"));
        vault.process();
        assertGt(vault.gasBalance(), gasBefore, "refill topped up the gas pool");
        assertGe(vault.gasBalance(), 0.005 ether);
        assertEq(vault.pendingQuote(), 0);
        assertEq(IERC20(NVDAB).balanceOf(address(vault)), 0, "all quote spent");
        assertGt(basePool.lastDepositAmount(), 0, "bought-back token deposited");
        assertEq(poolManager.deployPoolCallCount(), 1);
        console2.log("gas pool after process (wei):", vault.gasBalance());
    }

    function test_erc20Quote_launchWithoutPrepay_reverts() public {
        bytes memory vaultData = abi.encode(BSC_USDT, uint256(1 ether), uint256(0.005 ether), uint256(0.01 ether));
        IVaultPortalTypes.NewTokenV6WithVaultParams memory p =
            _buildV3TaxTokenParams("Myx RWA Vault Token", "MRV", _freshSalt(), address(factory), vaultData);
        p.quoteToken = NVDAB;
        p.dividendToken = MAGIC_DIVIDEND_COMPUTED;
        vm.expectRevert(bytes(unicode"Prepaid gas below minimum / 預付 Gas 低於最低要求"));
        vaultPortal.newTokenV6WithVault(p);
    }

    receive() external payable {}
}
