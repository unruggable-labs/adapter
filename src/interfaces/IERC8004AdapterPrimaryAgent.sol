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

    /// @notice Set `account`'s primary agent id from an EIP-712 signature by `account` itself, so any
    /// relayer can submit it and the account pays no gas. EIP-712 payload:
    /// `SetPrimary8004Agent(address account,uint256 agentId,uint256 nonce,uint256 deadline)`.
    /// Strictly account-self. The signature is validated against `account`, whether an EOA or the
    /// account's ERC-1271 policy, and there is deliberately no owner, admin or controller signature
    /// route. That authority stays on the paid `setPrimaryAgentFor`. The nonce is not a calldata
    /// argument. The signed payload embeds the current `primaryAgentNonces(account)`, read on-chain
    /// immediately before verification. Reverts `SignatureDeadlineTooFar` or `SignatureExpired` on the
    /// deadline bounds, and `InvalidSignature` on a bad or stale signature. An `agentId` of
    /// `PRIMARY_AGENT_UNSET` reverts `PrimaryAgentIdReserved`, and `0` is a valid id. Emits
    /// `PrimaryAgentSet(account, agentId, relayer)` then
    /// `PrimaryAgentSetWithSig(account, agentId, relayer, nonce)`.
    function setPrimaryAgentWithSig(address account, uint256 agentId, uint256 deadline, bytes calldata signature)
        external;

    /// @notice Clear `account`'s primary agent id from an EIP-712 signature by `account` itself.
    /// EIP-712 payload: `ClearPrimary8004Agent(address account,uint256 nonce,uint256 deadline)`.
    /// Same account-self authorization, nonce stream and deadline bounds as `setPrimaryAgentWithSig`.
    /// Because both draw on the one nonce stream, a set and a clear sharing a nonce are mutually
    /// exclusive and the one mined first wins. Afterwards `primaryAgentOf` returns
    /// `PRIMARY_AGENT_UNSET`. Emits `PrimaryAgentCleared(account, relayer)` then
    /// `PrimaryAgentClearedWithSig(account, relayer, nonce)`.
    function clearPrimaryAgentWithSig(address account, uint256 deadline, bytes calldata signature) external;
}
