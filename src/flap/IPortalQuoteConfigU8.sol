// SPDX-License-Identifier: MIT
pragma solidity ^0.8.13;

/// @title IPortalQuoteConfigU8
/// @notice Decode-safe view of Portal.getQuoteTokenConfiguration. The canonical struct in IPortal.sol
///         uses CurveType / NativeToQuoteSwapType enums; live quote tokens carry enum values the local
///         copy does not know (e.g. RWA quotes use curve ids >= 30 and swap type 7), and Solidity 0.8
///         reverts when decoding an out-of-range enum. Mirroring every field as uint8 keeps the ABI
///         byte-identical while never reverting on new variants.
interface IPortalQuoteConfigU8 {
    struct QuoteTokenConfigurationU8 {
        uint8 enabled; // 1 if the quote token is allowed
        uint8 defaultCurve; // IPortalTypes.CurveType
        uint8 alternativeCurve; // IPortalTypes.CurveType
        uint8 nativeToQuoteSwapType; // IPortalTypes.NativeToQuoteSwapType (7 = SWAP_VIA_ROUTE)
        uint8 dexId; // IPortalTypes.DEXId used by MultiDexRouter dispatch
    }

    function getQuoteTokenConfiguration(address quoteToken)
        external
        view
        returns (QuoteTokenConfigurationU8 memory config);
}
