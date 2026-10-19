// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

/// @dev Shared registry selection for deployment and offline input computation, plus the table of
/// chains that already run a live adapter proxy. Fresh deployment scripts refuse those chains so an
/// operator cannot create a second proxy by mistake. Existing proxies upgrade in place through
/// `PrepareChainUpgrade.s.sol` and the Safe.
library VanityChainConfig {
    /// @notice A fresh deployment was attempted on a chain that already has a live adapter proxy.
    error ProxyAlreadyLive(uint256 chainId, address proxy);

    /// @dev The canonical adapter proxy on each chain that has one, or the zero address.
    function liveProxyForChain(uint256 chainId) internal pure returns (address) {
        if (chainId == 1) return 0xde152AfB7db5373F34876E1499fbD893A82dD336;
        if (chainId == 8453) return 0x270d25D2c59A8bcA1B0f40ad95fF7806c0025c27;
        if (chainId == 11155111) return 0x7621630cB63a73a194f45A3E6801B8C6A7eC2f92;
        if (chainId == 4663) return 0x000000009d62675362a58911e3f32FEcf46F5E18;
        return address(0);
    }

    /// @dev Reverts with `ProxyAlreadyLive` when `chainId` already has a canonical proxy.
    function requireNoLiveProxy(uint256 chainId) internal pure {
        address proxy = liveProxyForChain(chainId);
        if (proxy != address(0)) revert ProxyAlreadyLive(chainId, proxy);
    }

    function registryForChain(uint256 chainId) internal pure returns (address) {
        if (chainId == 1 || chainId == 8453 || chainId == 4663) {
            return 0x8004A169FB4a3325136EB29fA0ceB6D2e539a432;
        }
        if (chainId == 11155111) return 0x8004A818BFB912233c491871b3d84c89A494BD9e;
        revert("unsupported chain");
    }
}
