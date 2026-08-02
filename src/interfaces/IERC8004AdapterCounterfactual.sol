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
///
/// `CONTRACT` (`TokenStandard` value 5, appended; values 0-4 unchanged) uses the same unsigned
/// functions under a different authority. It names a deployed contract itself rather than a token
/// within it, so `tokenId` MUST be `0`; any other id reverts `NonZeroTokenIdForContract`. The bound
/// contract itself is the only authorized emitter: the adapter's immediate EVM caller must be
/// `tokenContract`. A router, forwarder, or multicall that calls the adapter itself fails, since the
/// adapter sees that contract as `msg.sender`; an external owner or governance address may instead
/// call an entry point on the bound contract that makes the outbound adapter call. `delegatecall`
/// into the adapter is unsupported and dangerous — it is a UUPS implementation with its own storage
/// layout, not a library. Holders, an optional `owner()`, and the adapter admin have no authority,
/// and the adapter probes neither `ownerOf` nor either `balanceOf` shape. Unlike the transient
/// single-owner window above — which closes on mint and can reopen on burn — a contract-level
/// binding has no token whose ownership could change hands, so its authority window never closes.
/// (An ERC-20 claiming its own contract-level identity through `CONTRACT` is the motivating example;
/// there is no ERC-20-specific standard value.)
///
/// A counterfactual claim has no whole-claim tombstone. Later events from the same contract only
/// supersede earlier ones by last-event-wins, and `counterfactualUnsetAgentWallet` clears the
/// wallet field alone. The event schema, indexed topics, `registrationHash`, and `version == 1`
/// are unchanged by `CONTRACT`. `CounterfactualAgentRegistered.standard` — the only counterfactual
/// event that carries a standard — remains non-indexed (the on-chain `AgentBound.standard` keeps its
/// own indexed slot). Because the standard is excluded from the hash, any two standards claiming the
/// same `(tokenContract, tokenId)` alias onto one `registrationHash`; a contract that is also an
/// ERC-721 collection claiming both its token `#0` and `CONTRACT` at `(X, 0)` is the worked example.
/// That is accepted and documented: they are deliberately one identity with one current claim, and
/// consumers read the latest `CounterfactualAgentRegistered.standard` in log order to see which
/// claim currently wins.
interface IERC8004AdapterCounterfactual {
    /// @notice Local ERC-7930 v1 Chain Identifier using CAIP-350 `eip155`: version 1, ChainType 0,
    /// shortest non-empty big-endian `block.chainid`, and zero AddressLength.
    function chainIdentifier() external view returns (bytes memory);

    /// @notice Full local ERC-7930 v1 Interoperable Address for an EVM account: the same chain
    /// envelope as `chainIdentifier()`, followed by AddressLength 20 and the raw address bytes.
    function interoperableAddress(address account) external view returns (bytes memory);

    /// @notice Computes the canonical counterfactual registration hash. The identity is
    /// `keccak256(abi.encode(interoperableAddress(adapter), tokenContract, tokenId))`.
    function registrationHash(address tokenContract, uint256 tokenId) external view returns (bytes32);

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
