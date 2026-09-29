// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

/// @dev Shared registry selection for deployment and offline input computation.
library VanityChainConfig {
    function registryForChain(uint256 chainId) internal pure returns (address) {
        if (chainId == 1 || chainId == 8453 || chainId == 4663) {
            return 0x8004A169FB4a3325136EB29fA0ceB6D2e539a432;
        }
        if (chainId == 11155111) return 0x8004A818BFB912233c491871b3d84c89A494BD9e;
        revert("unsupported chain");
    }
}
