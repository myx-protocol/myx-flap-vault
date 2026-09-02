// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.26;

import {Strings} from "@openzeppelin/utils/Strings.sol";

/// @title Decimal18
/// @notice Formats an 18-decimals fixed-point wei value as a human-readable decimal string.
library Decimal18 {
    /// @notice Renders `value` (an 18-decimals wei amount) as "<whole>.<fraction>", stripping
    ///         trailing fractional zeros. A zero fraction yields just the integer part.
    ///         e.g. 15560495045491564826633 -> "15560.495045491564826633",
    ///              1e18 -> "1", 9409000000000 -> "0.000009409", 1 -> "0.000000000000000001".
    function toString(uint256 value) internal pure returns (string memory) {
        return toString(value, 18);
    }

    /// @notice Renders `value` with `decimals` fractional digits, stripping trailing zeros.
    function toString(uint256 value, uint8 decimals) internal pure returns (string memory) {
        if (decimals == 0) return Strings.toString(value);
        uint256 unit = 10 ** uint256(decimals);
        uint256 whole = value / unit;
        uint256 frac = value % unit;
        if (frac == 0) return Strings.toString(whole);

        // frac in [1, unit); toString drops its leading zeros, so left-pad back to `decimals` digits.
        bytes memory fracDigits = bytes(Strings.toString(frac));
        uint256 leadingZeros = uint256(decimals) - fracDigits.length;

        // Drop trailing zeros (e.g. 9409000000000 -> keep "9409").
        uint256 end = fracDigits.length;
        while (end > 0 && fracDigits[end - 1] == "0") {
            end--;
        }

        bytes memory fracOut = new bytes(leadingZeros + end);
        for (uint256 i = 0; i < leadingZeros; i++) {
            fracOut[i] = "0";
        }
        for (uint256 i = 0; i < end; i++) {
            fracOut[leadingZeros + i] = fracDigits[i];
        }
        return string.concat(Strings.toString(whole), ".", string(fracOut));
    }
}
