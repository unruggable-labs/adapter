// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {IERCAgentBindings} from "./IERCAgentBindings.sol";
import {IERC8004IdentityRegistry} from "./IERC8004IdentityRegistry.sol";

/// @notice Agent creation entry point for `Adapter8004`: registers through an ERC-8004 registry
/// after proving authority over an external bound token. Authority is ordinary current control or,
/// for ERC-721/ERC-1155F/ERC-6909F only, the directly calling token contract while `ownerOf(tokenId)`
/// reports no current owner. That temporary collection path closes after mint. Plain ERC-1155 and
/// ERC-6909 remain positive-balance controlled. Differs from `IERC8004IdentityRegistry.register`,
/// which mints an identity directly from URI + metadata only.
interface IERC8004AdapterRegistration {
    function register(
        IERCAgentBindings.TokenStandard standard,
        address tokenContract,
        uint256 tokenId,
        string calldata agentURI,
        IERC8004IdentityRegistry.MetadataEntry[] memory metadata
    ) external returns (uint256 agentId);

    /// @notice Convenience overload equivalent to `register(...)` with an empty metadata array.
    function register(
        IERCAgentBindings.TokenStandard standard,
        address tokenContract,
        uint256 tokenId,
        string calldata agentURI
    ) external returns (uint256 agentId);

    /// @notice Caller-paid one-transaction wrapper: `register(standard, tokenContract, tokenId,
    /// agentURI)` (empty metadata) immediately followed by recording the returned `agentId` as the
    /// CALLER's own full primary agent (`setPrimaryAgent(agentId)`). No signature or relayer. Same
    /// token-authority rules and `AgentBound` event/return as `register`, plus a
    /// `PrimaryAgentSet(caller, agentId, caller)`. When an ownerless collection calls, the primary is
    /// therefore recorded for the collection, not a future buyer.
    function registerAndSetPrimary(
        IERCAgentBindings.TokenStandard standard,
        address tokenContract,
        uint256 tokenId,
        string calldata agentURI
    ) external returns (uint256 agentId);

    /// @notice Bind an already-minted ERC-8004 `agentId` into adapter management against an external
    /// token. The caller MUST own the agent in the ERC-8004 registry and MUST currently control the
    /// external token under the ordinary current-control model (the ownerless collection window
    /// used by `register` does not apply). The adapter MUST have prior ERC-721 transfer
    /// approval for `agentId` (per-token or operator-level). The pre-existing `agentURI` and all
    /// non-binding metadata are preserved; only the reserved `agent-binding` metadata key is
    /// overwritten to point at this adapter, and the default agent wallet is cleared.
    function bindExisting(
        uint256 agentId,
        IERCAgentBindings.TokenStandard standard,
        address tokenContract,
        uint256 tokenId
    ) external;
}
