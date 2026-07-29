// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

/// @notice Counterfactual reverse resolution. Values are always derived by the adapter from token
/// coordinates using its canonical ERC-7930 registration hash. These account assertions remain
/// separate from full ERC-8004 primaries and require reciprocal wallet-event verification.
interface IERC8004AdapterCounterfactualPrimaryAgent {
    function PRIMARY_COUNTERFACTUAL_AGENT_UNSET() external pure returns (bytes32);

    event PrimaryCounterfactualAgentSet(
        address indexed account,
        bytes32 indexed registrationHash,
        address tokenContract,
        uint256 tokenId,
        address indexed setBy
    );
    event PrimaryCounterfactualAgentCleared(address indexed account, address indexed clearedBy);

    function setPrimaryCounterfactualAgent(address tokenContract, uint256 tokenId)
        external
        returns (bytes32 registrationHash);
    function setPrimaryCounterfactualAgentFor(address account, address tokenContract, uint256 tokenId)
        external
        returns (bytes32 registrationHash);
    function clearPrimaryCounterfactualAgent() external;
    function clearPrimaryCounterfactualAgentFor(address account) external;
    function primaryCounterfactualAgentOf(address account) external view returns (bytes32 registrationHash);
}
