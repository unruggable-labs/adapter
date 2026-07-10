// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {IERCAgentBindings} from "./IERCAgentBindings.sol";
import {IERC8004IdentityRegistry} from "./IERC8004IdentityRegistry.sol";

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

    /// @notice Supplemental provenance event for a signed (gasless) primary-agent set. Emitted AFTER
    /// the legacy `PrimaryAgentSet`, which remains the single state-transition event indexers act on.
    /// @dev With strict account-self validation, `account` is also the signer, so no separate signer
    /// field is needed. `relayer` is `msg.sender` (the transaction submitter, which the legacy event's
    /// `setBy` also reports). `nonce` is the per-account nonce consumed by this signature.
    event PrimaryAgentSetWithSig(
        address indexed account, bytes32 indexed agentId, address indexed relayer, uint256 nonce
    );

    /// @notice Supplemental provenance event for a signed (gasless) primary-agent clear. Emitted AFTER
    /// the legacy `PrimaryAgentCleared`. `relayer` is `msg.sender`; `nonce` is the consumed nonce.
    event PrimaryAgentClearedWithSig(address indexed account, address indexed relayer, uint256 nonce);

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

    /// @notice Current signature nonce for `account`, shared across all three signed operations
    /// (`setPrimaryAgentWithSig`, `clearPrimaryAgentWithSig`, `counterfactualRegisterAndSetPrimaryWithSig`).
    /// Clients read this immediately before signing; the value is embedded in the signed EIP-712
    /// payload and a successful call increments it exactly once, invalidating any other signature
    /// pre-signed against the same value. Not a calldata argument on any signed method.
    function nonces(address account) external view returns (uint256);

    /// @notice Set `account`'s primary agent id from an EIP-712 signature by `account`, submittable by
    /// any relayer (gasless). Strictly account-self: validated against `account` via EOA `ecrecover`
    /// or the account's ERC-1271 policy — there is NO owner/admin/controller signature route (that
    /// authority stays on the paid `setPrimaryAgentFor`). The signed struct is
    /// `SetPrimaryAgent(address account,bytes32 agentId,uint256 nonce,uint256 deadline)` where `nonce`
    /// is the current `nonces(account)` (not a calldata argument) and `deadline` is bounded by a
    /// 30-minute contract cap. `agentId == 0` is a valid claim; the all-ones sentinel reverts
    /// `Adapter8004.PrimaryAgentIdReserved` and consumes no nonce. Reverts `SignatureDeadlineTooFar` /
    /// `SignatureExpired` / `InvalidSignature`. Emits legacy `PrimaryAgentSet(account, agentId,
    /// relayer)` then `PrimaryAgentSetWithSig(account, agentId, relayer, nonce)`.
    function setPrimaryAgentWithSig(address account, bytes32 agentId, uint256 deadline, bytes calldata signature)
        external;

    /// @notice Clear `account`'s primary agent id from an EIP-712 signature by `account` (gasless).
    /// Same account-self authorization, shared nonce stream, and 30-minute deadline cap as
    /// `setPrimaryAgentWithSig`; a signed clear and signed set supersede each other through the shared
    /// nonce. Signed struct: `ClearPrimaryAgent(address account,uint256 nonce,uint256 deadline)`. Emits
    /// legacy `PrimaryAgentCleared(account, relayer)` then `PrimaryAgentClearedWithSig(account, relayer,
    /// nonce)`.
    function clearPrimaryAgentWithSig(address account, uint256 deadline, bytes calldata signature) external;

    /// @notice Atomically register a counterfactual agent AND set it as the signer's primary agent,
    /// from one EIP-712 signature by a single `signer` (gasless). That sole `signer` is simultaneously
    /// the direct token holder authorizing the registration, the `CounterfactualAgentRegistered`
    /// emitter, and the primary-agent account: there is NO independent `owner`/`account` field and NO
    /// caller-supplied `agentId`. The primary id is the derived `registrationHash(tokenContract,
    /// tokenId)` (also the return value). Registering for X while pointing Y is NOT possible here — use
    /// `counterfactualRegisterWithSig` + `setPrimaryAgentWithSig` (two signatures) for a split workflow.
    /// Shares the primary-agent nonce stream and 30-minute deadline cap (NOT the counterfactual
    /// `expiration` model). Requires strict direct token control by `signer` (no delegate.xyz). Emits
    /// `CounterfactualAgentRegistered` (and, with a bundled `agentWallet`, `CounterfactualAgentWalletSet`)
    /// with `emitter = signer`, then legacy `PrimaryAgentSet(signer, registrationHash, relayer)`, then
    /// `PrimaryAgentSetWithSig(signer, registrationHash, relayer, nonce)`. A derived hash equal to the
    /// all-ones sentinel reverts `Adapter8004.PrimaryAgentIdReserved` and rolls the whole call back.
    function counterfactualRegisterAndSetPrimaryWithSig(
        IERCAgentBindings.TokenStandard standard,
        address tokenContract,
        uint256 tokenId,
        string calldata agentURI,
        IERC8004IdentityRegistry.MetadataEntry[] calldata metadata,
        address agentWallet,
        address signer,
        uint256 deadline,
        bytes calldata signature
    ) external returns (bytes32 registrationHash);
}
