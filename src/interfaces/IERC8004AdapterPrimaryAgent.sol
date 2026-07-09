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
/// "Unset" is represented by the reserved all-ones sentinel `Adapter8004.PRIMARY_AGENT_UNSET`, NOT
/// by `bytes32(0)`: `primaryAgentOf` returns the sentinel for an account that has never set an id or
/// has cleared it, and returns every real id — including agent id `0` — as itself. Setters therefore
/// never treat `0` as a clear; removal is an explicit `clearPrimaryAgent` / `clearPrimaryAgentFor`,
/// and passing the sentinel to a setter reverts `Adapter8004.PrimaryAgentIdReserved`.
///
/// The mapping records only the address's own claim ("I belong to agent X"). It is deliberately NOT
/// proof: a consumer establishes a verified link by ALSO reading the agent's own wallet claim (the
/// ERC-8004 `agentWallet`, or the counterfactual `CounterfactualAgentWalletSet` event) and checking
/// that the wallet and the agent point at each other.
interface IERC8004AdapterPrimaryAgent {
    /// @notice The all-ones sentinel that `primaryAgentOf` returns for an account with no primary
    /// agent set. Declares the generated getter for the concrete contract's `PRIMARY_AGENT_UNSET`
    /// public constant (an interface cannot declare the constant itself). Equals
    /// `bytes32(type(uint256).max)`.
    function PRIMARY_AGENT_UNSET() external pure returns (bytes32);

    /// @notice Emitted when an account's primary agent id is set or updated to a real id.
    /// @dev `setBy` is the caller that performed the write (the account itself, its owner, or a
    /// `DEFAULT_ADMIN_ROLE` holder). Clears emit `PrimaryAgentCleared` instead, not this event.
    event PrimaryAgentSet(address indexed account, bytes32 indexed agentId, address indexed setBy);

    /// @notice Emitted when an account's primary agent id is cleared back to the unset sentinel.
    /// @dev `clearedBy` is the caller that performed the clear. Emitted even for an already-unset
    /// account (an idempotent clear), so downstream indexers see the explicit intent.
    event PrimaryAgentCleared(address indexed account, address indexed clearedBy);

    /// @notice Set the caller's own primary agent id. Reverts `Adapter8004.PrimaryAgentIdReserved`
    /// when `agentId` is the all-ones unset sentinel; use `clearPrimaryAgent` to remove an id.
    function setPrimaryAgent(bytes32 agentId) external;

    /// @notice Set the primary agent id for `account`. Authorized when the caller is the account
    /// itself, the account's `owner()` / `getOwner()`, or a holder of the account's
    /// `DEFAULT_ADMIN_ROLE` (`0x00`). Reverts `NotAccountController` otherwise, or
    /// `Adapter8004.PrimaryAgentIdReserved` for the all-ones sentinel id.
    function setPrimaryAgentFor(address account, bytes32 agentId) external;

    /// @notice Clear the caller's own primary agent id. Afterwards `primaryAgentOf` returns the unset
    /// sentinel. Idempotent, and always emits `PrimaryAgentCleared`.
    function clearPrimaryAgent() external;

    /// @notice Clear the primary agent id for `account`, under the same authorization as
    /// `setPrimaryAgentFor`. Reverts `NotAccountController` when the caller is not authorized.
    function clearPrimaryAgentFor(address account) external;

    /// @notice Reverse-resolve an address to its primary agent id. Returns the all-ones unset
    /// sentinel (`Adapter8004.PRIMARY_AGENT_UNSET`) when the account has no primary agent set.
    function primaryAgentOf(address account) external view returns (bytes32 agentId);
}
