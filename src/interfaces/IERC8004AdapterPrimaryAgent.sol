// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

/// @notice Full ERC-8004 reverse resolution. Each value is a registry `agentId`; counterfactual
/// registration hashes use the separate `IERC8004AdapterCounterfactualPrimaryAgent` surface.
/// This is an account assertion, not proof of a reciprocal wallet relationship.
interface IERC8004AdapterPrimaryAgent {
    function PRIMARY_AGENT_UNSET() external pure returns (uint256);

    event PrimaryAgentSet(address indexed account, uint256 indexed agentId, address indexed setBy);
    event PrimaryAgentCleared(address indexed account, address indexed clearedBy);

    function setPrimaryAgent(uint256 agentId) external;
    function setPrimaryAgentFor(address account, uint256 agentId) external;
    function clearPrimaryAgent() external;
    function clearPrimaryAgentFor(address account) external;
    function primaryAgentOf(address account) external view returns (uint256 agentId);
}
