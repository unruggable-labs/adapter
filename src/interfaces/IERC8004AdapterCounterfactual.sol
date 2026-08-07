// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {IERCAgentBindings} from "./IERCAgentBindings.sol";
import {IERC8004IdentityRegistry} from "./IERC8004IdentityRegistry.sol";

/// @notice Event-only surface for the counterfactual register family on `Adapter8004`. The functions
/// themselves stay on the adapter (they need internal helpers); this interface owns the event
/// declarations so off-chain consumers and tests can depend on a stable type without importing
/// the full contract.
///
/// Every counterfactual event below carries `bytes32 extraData` as its first non-indexed field.
/// The three indexed slots are fixed across every event and already spent on
/// `(registrationHash, tokenContract, tokenId)`. There is deliberately no in-payload schema
/// version, because `topic0` is the keccak of the full event signature and so already discriminates
/// schema on its own.
///
/// The identity is the `registrationHash`. Each token has exactly one identity, but
/// `(tokenContract, tokenId)` is not considered a unique identifier, because one contract may have
/// more than one set of ids. An example is a contract with classes of ids, where Class A id 1 and
/// Class B id 1 are different tokens. `extraData` is what separates them, so consumers must key on
/// `registrationHash` and must not collapse rows by `(tokenContract, tokenId)`.
///
/// Adapter8004's existing unsigned counterfactual functions accept either ordinary current-controller
/// authority or, for ERC-721/ERC-1155F/ERC-6909F only, temporary authority from the directly calling
/// token contract while `ownerOf(tokenId)` reports no current owner. The collection must call the
/// adapter directly before mint (not through a router, forwarder, or delegatecall). A revert or
/// canonical zero response opens that window; minting to a non-collection owner closes it, while a
/// later burn can reopen it because the adapter deliberately stores no historical-existence bit.
/// Plain ERC-1155/ERC-6909 remain positive-balance controlled. Collection-authorized events retain
/// the existing schema and carry `emitter = tokenContract`; later owner/delegate events overwrite
/// them by normal log ordering.
interface IERC8004AdapterCounterfactual {
    /// @notice Local ERC-7930 v1 Chain Identifier using CAIP-350 `eip155`: version 1, ChainType 0,
    /// shortest non-empty big-endian `block.chainid`, and zero AddressLength.
    function chainIdentifier() external view returns (bytes memory);

    /// @notice Full local ERC-7930 v1 Interoperable Address for an EVM account: the same chain
    /// envelope as `chainIdentifier()`, followed by AddressLength 20 and the raw address bytes.
    function interoperableAddress(address account) external view returns (bytes memory);

    /// @notice Computes the canonical counterfactual registration hash. The identity is
    /// `keccak256(abi.encode(interoperableAddress(adapter), tokenContract, tokenId, extraData))`,
    /// where `extraData` is `bytes32(0)` for every implementation of this baseline.
    /// @dev `extraData` is deliberately not a parameter anywhere on this surface, because it is
    /// reserved rather than used. Read its value from the `extraData` field on any counterfactual
    /// event.
    function registrationHash(address tokenContract, uint256 tokenId) external view returns (bytes32);

    /// @notice Counterfactual registration claim. No registry write, no SSTORE.
    /// Indexers MUST treat the latest event per `registrationHash` as authoritative.
    event CounterfactualAgentRegistered(
        bytes32 indexed registrationHash,
        address indexed tokenContract,
        uint256 indexed tokenId,
        bytes32 extraData,
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
        bytes32 extraData,
        string newURI,
        address emitter
    );

    /// @notice Counterfactual metadata write. No registry write, no SSTORE.
    event CounterfactualMetadataSet(
        bytes32 indexed registrationHash,
        address indexed tokenContract,
        uint256 indexed tokenId,
        bytes32 extraData,
        string metadataKey,
        bytes metadataValue,
        address emitter
    );

    /// @notice Counterfactual batch metadata write. No registry write, no SSTORE.
    event CounterfactualMetadataBatchSet(
        bytes32 indexed registrationHash,
        address indexed tokenContract,
        uint256 indexed tokenId,
        bytes32 extraData,
        IERC8004IdentityRegistry.MetadataEntry[] metadata,
        address emitter
    );

    /// @notice Counterfactual agent wallet assignment. No signature, no registry write.
    event CounterfactualAgentWalletSet(
        bytes32 indexed registrationHash,
        address indexed tokenContract,
        uint256 indexed tokenId,
        bytes32 extraData,
        address newWallet,
        address emitter
    );

    /// @notice Counterfactual agent wallet clear. No registry write, no SSTORE.
    event CounterfactualAgentWalletUnset(
        bytes32 indexed registrationHash,
        address indexed tokenContract,
        uint256 indexed tokenId,
        bytes32 extraData,
        address emitter
    );
}
