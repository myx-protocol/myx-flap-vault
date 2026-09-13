// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.26;

import {Test} from "forge-std/Test.sol";
import {MyxVaultFactory} from "../src/MyxVaultFactory.sol";
import {MyxVault} from "../src/MyxVault.sol";
import "./mocks/Mocks.sol";

contract MyxVaultFactoryPrepaidGasTest is Test {
    MyxVaultFactory factory;
    MockERC20 usdt;
    MockERC20 rwa;
    MockPortal portal;

    address constant VAULT_PORTAL = 0x90497450f2a706f1951b5bdda52B4E5d16f34C06;
    address constant PORTAL = 0xe2cE6ab80874Fa9Fa2aAE65D277Dd6B8e65C9De0;
    address creator = makeAddr("creator");

    event GasPrepaid(address indexed account, uint256 amount, uint256 total);
    event PrepaidGasWithdrawn(address indexed account, uint256 amount);
    event VaultGasFunded(address indexed vault, address indexed creator, uint256 amount);

    function setUp() public {
        vm.chainId(56);
        usdt = new MockERC20("Tether", "USDT");
        rwa = new MockERC20("NVDA bStock", "NVDAB");
        MockPortal impl = new MockPortal();
        vm.etch(PORTAL, address(impl).code);
        portal = MockPortal(PORTAL);
        portal.setQuoteConfig(address(rwa), true, 0);
        factory = new MyxVaultFactory(
            MyxVaultFactory.GlobalConfig({
                poolManager: address(new MockPoolManager()),
                basePool: address(new MockBasePool(new MockERC20("LP", "LP"), usdt)),
                poolFactory: address(new MockMyxPoolFactory()),
                maxSlippageBps: 300,
                minInitialGas: 0.002 ether,
                maxGasRefillAmount: 0.05 ether
            })
        );
        vm.deal(creator, 10 ether);
    }

    function _erc20VaultData() internal view returns (bytes memory) {
        return abi.encode(address(usdt), uint256(10 ether), uint256(0.01 ether), uint256(0.05 ether), type(uint256).max);
    }

    function test_prepayGas_accumulatesAndEmits() public {
        vm.startPrank(creator);
        vm.expectEmit(true, true, true, true);
        emit GasPrepaid(creator, 0.001 ether, 0.001 ether);
        factory.prepayGas{value: 0.001 ether}();
        factory.prepayGas{value: 0.002 ether}();
        vm.stopPrank();
        assertEq(factory.prepaidGas(creator), 0.003 ether);
    }

    function test_withdrawPrepaidGas_refundsAll() public {
        vm.prank(creator);
        factory.prepayGas{value: 0.003 ether}();
        uint256 before = creator.balance;
        vm.prank(creator);
        vm.expectEmit(true, true, true, true);
        emit PrepaidGasWithdrawn(creator, 0.003 ether);
        factory.withdrawPrepaidGas();
        assertEq(creator.balance, before + 0.003 ether);
        assertEq(factory.prepaidGas(creator), 0);
    }

    function test_withdrawPrepaidGas_nothing_reverts() public {
        vm.prank(creator);
        vm.expectRevert(bytes(unicode"Nothing prepaid / 無預付款"));
        factory.withdrawPrepaidGas();
    }

    function test_newVault_erc20_belowMinInitialGas_reverts() public {
        vm.prank(creator);
        factory.prepayGas{value: 0.001 ether}();
        vm.prank(VAULT_PORTAL);
        vm.expectRevert(bytes(unicode"Prepaid gas below minimum / 預付 Gas 低於最低要求"));
        factory.newVault(makeAddr("tax"), address(rwa), creator, _erc20VaultData());
        assertEq(factory.prepaidGas(creator), 0.001 ether, "prepaid untouched on revert");
    }

    function test_newVault_erc20_forwardsAllPrepaidToVault() public {
        vm.prank(creator);
        factory.prepayGas{value: 0.005 ether}();
        vm.prank(VAULT_PORTAL);
        vm.expectEmit(false, true, true, true);
        emit VaultGasFunded(address(0), creator, 0.005 ether);
        address vaultAddr = factory.newVault(makeAddr("tax"), address(rwa), creator, _erc20VaultData());
        assertEq(MyxVault(payable(vaultAddr)).gasBalance(), 0.005 ether);
        assertEq(factory.prepaidGas(creator), 0);
        assertEq(address(factory).balance, 0);
    }

    function test_newVault_native_ignoresPrepaid() public {
        vm.prank(creator);
        factory.prepayGas{value: 0.005 ether}();
        vm.prank(VAULT_PORTAL);
        address vaultAddr = factory.newVault(makeAddr("tax"), address(0), creator, abi.encode(address(usdt), uint256(1), uint256(0), uint256(0), type(uint256).max));
        assertEq(address(vaultAddr).balance, 0);
        assertEq(factory.prepaidGas(creator), 0.005 ether, "still withdrawable");
    }

    function test_newVault_erc20_zeroMinInitialGas_allowsNoPrepay() public {
        MyxVaultFactory lax = new MyxVaultFactory(
            MyxVaultFactory.GlobalConfig({
                poolManager: address(new MockPoolManager()),
                basePool: address(new MockBasePool(new MockERC20("LP", "LP"), usdt)),
                poolFactory: address(new MockMyxPoolFactory()),
                maxSlippageBps: 300,
                minInitialGas: 0,
                maxGasRefillAmount: 0.05 ether
            })
        );
        vm.prank(VAULT_PORTAL);
        address vaultAddr = lax.newVault(makeAddr("tax"), address(rwa), creator, _erc20VaultData());
        assertEq(MyxVault(payable(vaultAddr)).gasBalance(), 0);
    }
}
