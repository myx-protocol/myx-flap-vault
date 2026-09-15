// SPDX-License-Identifier: MIT

pragma solidity ^0.8.13;

/// @title FlapDeployed
/// @notice Returns the deployed VaultPortal address for each supported chain
library FlapDeployed {
    /// @notice Returns the VaultPortal address for the current chain
    /// @return portal The VaultPortal contract address
    function vaultPortal() public view returns (address portal) {
        uint256 chainId = block.chainid;

        // BNB Mainnet
        if (chainId == 56) portal = 0x90497450f2a706f1951b5bdda52B4E5d16f34C06;
        // BNB Testnet
        else if (chainId == 97) portal = 0x027e3704fC5C16522e9393d04C60A3ac5c0d775f;
        // Robinhood Chain Mainnet
        else if (chainId == 4663) portal = 0xe9F7AB7DE8FB8756acbB6a1cd13316a43308197B;

        require(portal != address(0), unicode"Unsupported chain / 不支援的鏈");
    }
}
