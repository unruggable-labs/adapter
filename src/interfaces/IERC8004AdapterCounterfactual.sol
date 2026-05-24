// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {IERCAgentBindings} from "./IERCAgentBindings.sol";
import {IERC8004IdentityRegistry} from "./IERC8004IdentityRegistry.sol";

/// @notice Event-only surface for the counterfactual register family on `Adapter8004`. The functions
/// themselves stay on the adapter (they need internal helpers); this interface owns the event
/// declarations so off-chain consumers and tests can depend on a stable type without importing
/// the full contract.
///
/// Every counterfactual event below carries `uint8 version` as its first non-indexed field.
/// Implementations conforming to this baseline MUST emit `version == 1`. The three
/// indexed topics are fixed across every event: `(registrationHash, tokenContract, tokenId)`.
interface IERC8004AdapterCounterfactual {
    /// @notice Computes the canonical counterfactual registration hash.
    function registrationHash(IERCAgentBindings.TokenStandard standard, address tokenContract, uint256 tokenId)
        external
        view
        returns (bytes32);

    /// @notice Signature-authorized counterfactual registration for a token-bound agent.
    /// The direct token holder signs one EIP-712 payload (URI + full metadata + optional bundled
    /// wallet + bounded expiration) and any caller may submit it, solving the register-at-mint sender
    /// mismatch. Supports ERC-721, ERC-1155, ERC-6909, ERC-1155F, and ERC-6909F through
    /// direct-holder control only; no delegate.xyz signer, no nonce, no wallet consent. Emits
    /// `CounterfactualAgentRegistered` (and
    /// `CounterfactualAgentWalletSet` when `agentWallet != address(0)`) with `emitter = owner`.
    /// Returns the canonical registration hash.
    function counterfactualRegisterWithSig(
        IERCAgentBindings.TokenStandard standard,
        address tokenContract,
        uint256 tokenId,
        string calldata agentURI,
        IERC8004IdentityRegistry.MetadataEntry[] calldata metadata,
        address agentWallet,
        address owner,
        uint256 expiration,
        bytes calldata signature
    ) external returns (bytes32 computedHash);

    /// @notice Counterfactual registration claim. No registry write, no SSTORE.
    /// Indexers MUST treat the latest event per (tokenContract, tokenId) as authoritative.
    event CounterfactualAgentRegistered(
        bytes32 indexed registrationHash,
        address indexed tokenContract,
        uint256 indexed tokenId,
        uint8 version,
        IERCAgentBindings.TokenStandard standard,
        string agentURI,
        IERC8004IdentityRegistry.MetadataEntry[] metadata,
        address emitter
    );

    /// @notice Counterfactual agent URI update. No registry write, no SSTORE.
    event CounterfactualAgentURISet(
        bytes32 indexed registrationHash,
        address indexed tokenContract,
        uint256 indexed tokenId,
        uint8 version,
        string newURI,
        address emitter
    );

    /// @notice Counterfactual metadata write. No registry write, no SSTORE.
    event CounterfactualMetadataSet(
        bytes32 indexed registrationHash,
        address indexed tokenContract,
        uint256 indexed tokenId,
        uint8 version,
        string metadataKey,
        bytes metadataValue,
        address emitter
    );

    /// @notice Counterfactual batch metadata write. No registry write, no SSTORE.
    event CounterfactualMetadataBatchSet(
        bytes32 indexed registrationHash,
        address indexed tokenContract,
        uint256 indexed tokenId,
        uint8 version,
        IERC8004IdentityRegistry.MetadataEntry[] metadata,
        address emitter
    );

    /// @notice Counterfactual agent wallet assignment. No signature, no registry write.
    event CounterfactualAgentWalletSet(
        bytes32 indexed registrationHash,
        address indexed tokenContract,
        uint256 indexed tokenId,
        uint8 version,
        address newWallet,
        address emitter
    );

    /// @notice Counterfactual agent wallet clear. No registry write, no SSTORE.
    event CounterfactualAgentWalletUnset(
        bytes32 indexed registrationHash,
        address indexed tokenContract,
        uint256 indexed tokenId,
        uint8 version,
        address emitter
    );

    /// @notice Returns the schema version emitted in the `uint8 version` field of every
    /// counterfactual event. Implementations conforming to this baseline MUST return `1`.
    function counterfactualPayloadVersion() external pure returns (uint8);
}
