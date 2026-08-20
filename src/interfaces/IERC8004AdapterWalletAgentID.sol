// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

/// @notice The agent id a wallet picks for itself. `wallet -> agentId` is one to many, because
/// ERC-8004's `setAgentWallet` makes every agent prove the wallet consented, so many agents can
/// validly list one wallet and the reverse direction is ambiguous. This mapping is how the wallet
/// chooses which of them speaks for it, and it is an assertion by the wallet rather than proof.
interface IERC8004AdapterWalletAgentID {
    function WALLET_AGENT_ID_UNSET() external pure returns (uint256);

    event WalletAgentIDSet(address indexed account, uint256 indexed agentId, address indexed setBy);
    event WalletAgentIDCleared(address indexed account, address indexed clearedBy);

    function setWalletAgentID(uint256 agentId) external;
    function setWalletAgentIDFor(address account, uint256 agentId) external;
    function clearWalletAgentID() external;
    function clearWalletAgentIDFor(address account) external;
    function walletAgentIDOf(address account) external view returns (uint256 agentId);
}
