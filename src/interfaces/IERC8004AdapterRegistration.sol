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
    /// @notice Mint a new ERC-8004 identity owned by the adapter and bind it permanently to the given
    /// external token. The caller must hold authority over that token under the rules above. The
    /// binding is immutable once set, so a token pair and standard identify the same agent for the
    /// life of the identity, and control follows the token rather than the registering address. The
    /// adapter writes its own `agent-binding` record, so `metadata` may not contain that key and a
    /// caller-supplied entry for it reverts `ReservedMetadataKey`. Every other key is accepted.
    /// Emits `AgentBound` and returns the new `agentId`.
    function register(
        IERCAgentBindings.TokenStandard standard,
        address boundAddress,
        uint256 tokenId,
        string calldata agentURI,
        IERC8004IdentityRegistry.MetadataEntry[] memory metadata
    ) external returns (uint256 agentId);

    /// @notice Convenience overload equivalent to `register(...)` with an empty metadata array.
    function register(
        IERCAgentBindings.TokenStandard standard,
        address boundAddress,
        uint256 tokenId,
        string calldata agentURI
    ) external returns (uint256 agentId);
}
