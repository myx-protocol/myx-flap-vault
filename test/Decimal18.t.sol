// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.26;

import {Test} from "forge-std/Test.sol";
import {Decimal18} from "../src/lib/Decimal18.sol";

contract Decimal18Test is Test {
    function test_zero() public pure {
        assertEq(Decimal18.toString(0), "0");
    }

    function test_wholeNumber_stripsFraction() public pure {
        assertEq(Decimal18.toString(1e18), "1");
    }

    /// @dev The LP minted value from the UI screenshot: 15560.495045491564826633 LP.
    function test_lpAmount_fullPrecision() public pure {
        assertEq(Decimal18.toString(15560495045491564826633), "15560.495045491564826633");
    }

    /// @dev The pending BNB value from the UI screenshot: 0.000009409 BNB. Trailing zeros stripped.
    function test_smallValue_stripsTrailingZeros() public pure {
        assertEq(Decimal18.toString(9409000000000), "0.000009409");
    }

    function test_oneAndHalf() public pure {
        assertEq(Decimal18.toString(1.5e18), "1.5");
    }

    /// @dev Smallest representable unit must keep all 18 fractional digits.
    function test_oneWei_minPrecision() public pure {
        assertEq(Decimal18.toString(1), "0.000000000000000001");
    }

    /// @dev Fraction smaller than 0.1 must be zero-padded on the left (1.01, not 1.1).
    function test_leadingFractionalZero() public pure {
        assertEq(Decimal18.toString(1010000000000000000), "1.01");
    }
}
