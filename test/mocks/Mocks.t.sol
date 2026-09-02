// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.26;

import {Test} from "forge-std/Test.sol";
import {IERC20} from "@openzeppelin/token/ERC20/IERC20.sol";
import {IPortalTradeV2} from "../../src/flap/IPortal.sol";
import {IMultiDexRouter} from "../../src/flap/IMultiDexRouter.sol";
import "./Mocks.sol";

contract MocksTest is Test {
    MockWBNB wbnb;
    MockERC20 rwa;
    MockMultiDexRouter router;
    MockPortal portal;
    MockTaxToken taxToken;

    function setUp() public {
        wbnb = new MockWBNB();
        rwa = new MockERC20("NVDA bStock", "NVDAB");
        router = new MockMultiDexRouter(wbnb);
        vm.deal(address(router), 100 ether);
        portal = new MockPortal();
        taxToken = new MockTaxToken(address(0));
    }

    function test_portal_quoteConfig_roundTrip() public {
        portal.setQuoteConfig(address(rwa), true, 0);
        IPortalQuoteConfigU8.QuoteTokenConfigurationU8 memory c = portal.getQuoteTokenConfiguration(address(rwa));
        assertEq(c.enabled, 1);
        assertEq(c.dexId, 0);
        assertEq(portal.getQuoteTokenConfiguration(makeAddr("other")).enabled, 0);
    }

    function test_portal_swapExactInput_pullsErc20Input() public {
        rwa.mint(address(this), 10 ether);
        rwa.approve(address(portal), 10 ether);
        portal.setRate(1000, 1);
        uint256 out = portal.swapExactInput(
            IPortalTradeV2.ExactInputParams({
                inputToken: address(rwa),
                outputToken: address(taxToken),
                inputAmount: 10 ether,
                minOutputAmount: 0,
                permitData: ""
            })
        );
        assertEq(out, 10_000 ether);
        assertEq(rwa.balanceOf(address(portal)), 10 ether);
        assertEq(taxToken.balanceOf(address(this)), 10_000 ether);
    }

    function test_router_quoteAndSwapOnlyExistingPools() public {
        router.setPool(2500, true);
        router.setRate(2500, 3, 10); // 1 RWA -> 0.3 WBNB
        assertEq(router.getDEXInfo(0).v3SupportedFees.length, 4);
        assertTrue(router.computeV3PoolAddress(0, address(rwa), address(wbnb), 2500).code.length > 0);
        assertEq(router.computeV3PoolAddress(0, address(rwa), address(wbnb), 500).code.length, 0);

        (uint256 out,,,) = router.quoteExactInputSingle(
            0, IMultiDexRouter.QuoteExactInputSingleParams(address(rwa), address(wbnb), 1 ether, 2500, 0)
        );
        assertEq(out, 0.3 ether);

        rwa.mint(address(this), 1 ether);
        rwa.approve(address(router), 1 ether);
        uint256 got = router.exactInputSingle(
            0, IMultiDexRouter.ExactInputSingleParams(address(rwa), address(wbnb), 2500, address(this), 1 ether, 0.29 ether, 0)
        );
        assertEq(got, 0.3 ether);
        assertEq(wbnb.balanceOf(address(this)), 0.3 ether);
        assertEq(router.lastFeeUsed(), 2500);
        assertEq(router.lastAmountIn(), 1 ether);
    }

    function test_router_quoteRevertsWhenConfigured() public {
        router.setPool(500, true);
        router.setQuoteReverts(500, true);
        vm.expectRevert();
        router.quoteExactInputSingle(
            0, IMultiDexRouter.QuoteExactInputSingleParams(address(rwa), address(wbnb), 1 ether, 500, 0)
        );
    }

    function test_taxProcessor_chain() public {
        MockSwapRegistry reg = new MockSwapRegistry(address(router), address(wbnb));
        MockTaxProcessor tp = new MockTaxProcessor(address(reg));
        taxToken.setTaxProcessor(address(tp));
        assertEq(taxToken.taxProcessor(), address(tp));
        assertEq(MockTaxProcessor(taxToken.taxProcessor()).swapRegistry(), address(reg));
        assertEq(reg.multiDexRouter(), address(router));
        assertEq(reg.weth(), address(wbnb));
    }
}
