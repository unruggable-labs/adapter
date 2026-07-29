// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

/// @notice Full ERC-8004 reverse resolution. Each value is a registry `agentId`; counterfactual
/// registration hashes use the separate `IERC8004AdapterCounterfactualPrimaryAgent` surface.
/// This is an account assertion, not proof of a reciprocal wallet relationship.
interface IERC8004AdapterPrimaryAgent {
    function PRIMARY_AGENT_UNSET() external pure returns (uint256);

    event PrimaryAgentSet(address indexed account, uint256 indexed agentId, address indexed setBy);
    event PrimaryAgentCleared(address indexed account, address indexed clearedBy);
    event PrimaryAgentSetWithSig(
        address indexed account, uint256 indexed agentId, address indexed relayer, uint256 nonce
    );
    event PrimaryAgentClearedWithSig(address indexed account, address indexed relayer, uint256 nonce);

    function setPrimaryAgent(uint256 agentId) external;
    function setPrimaryAgentFor(address account, uint256 agentId) external;
    function clearPrimaryAgent() external;
    function clearPrimaryAgentFor(address account) external;
    function primaryAgentOf(address account) external view returns (uint256 agentId);

    /// @notice Nonce for full-system signed set/clear operations only.
    function primaryAgentNonces(address account) external view returns (uint256);

    /// @notice EIP-712:
    /// `SetPrimary8004Agent(address account,uint256 agentId,uint256 nonce,uint256 deadline)`.
    function setPrimaryAgentWithSig(address account, uint256 agentId, uint256 deadline, bytes calldata signature)
        external;

    /// @notice EIP-712:
    /// `ClearPrimary8004Agent(address account,uint256 nonce,uint256 deadline)`.
    function clearPrimaryAgentWithSig(address account, uint256 deadline, bytes calldata signature) external;
}
