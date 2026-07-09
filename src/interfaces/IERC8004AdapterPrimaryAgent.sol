// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

/// @notice Primary-agent (reverse-resolution) surface on `Adapter8004`: an `address => agent id`
/// mapping that lets any consumer go from a wallet address (or any address recorded in agent
/// metadata) to the agent it claims to belong to, on this chain.
///
/// The stored id is either an ERC-8004 identity-registry token id (small, assigned incrementally
/// from 0) or a 32-byte counterfactual `registrationHash`. The two id spaces do not collide in
/// practice — incremental ids occupy the low end of the value range while hashes are ~uniform over
/// 256 bits — so a single `bytes32` mapping holds both. An ERC-8004 id is stored as `bytes32(id)`.
///
/// The mapping records only the address's own claim ("I belong to agent X"). It is deliberately NOT
/// proof: a consumer establishes a verified link by ALSO reading the agent's own wallet claim (the
/// ERC-8004 `agentWallet`, or the counterfactual `CounterfactualAgentWalletSet` event) and checking
/// that the wallet and the agent point at each other.
interface IERC8004AdapterPrimaryAgent {
    /// @notice Emitted when an account's primary agent id is set, updated, or cleared.
    /// @dev `agentId == bytes32(0)` means the registration was cleared. `setBy` is the caller that
    /// performed the write (the account itself, its owner, or a `DEFAULT_ADMIN_ROLE` holder).
    event PrimaryAgentSet(address indexed account, bytes32 indexed agentId, address indexed setBy);

    /// @notice Set (or clear, with `agentId == bytes32(0)`) the caller's own primary agent id.
    function setPrimaryAgent(bytes32 agentId) external;

    /// @notice Set (or clear) the primary agent id for `account`. Authorized when the caller is the
    /// account itself, the account's `owner()` / `getOwner()`, or a holder of the account's
    /// `DEFAULT_ADMIN_ROLE` (`0x00`). Reverts `NotAccountController` otherwise.
    function setPrimaryAgentFor(address account, bytes32 agentId) external;

    /// @notice Reverse-resolve an address to its primary agent id. Returns `bytes32(0)` when unset.
    function primaryAgentOf(address account) external view returns (bytes32 agentId);
}
