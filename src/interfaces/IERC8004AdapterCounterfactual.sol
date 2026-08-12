// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {IERCAgentBindings} from "./IERCAgentBindings.sol";
import {IERC8004IdentityRegistry} from "./IERC8004IdentityRegistry.sol";

/// @notice Event-only surface for the counterfactual register family on `Adapter8004`. The functions
/// themselves stay on the adapter (they need internal helpers); this interface owns the event
/// declarations so off-chain consumers and tests can depend on a stable type without importing
/// the full contract.
///
/// Every counterfactual event below carries the canonical subject `identifier` (`bytes`) as its
/// first non-indexed field, making each event self-verifying against its indexed hash. The three
/// indexed slots are fixed across every event: `(registrationHash, tokenContract, emitter)` — the
/// identity, the contract coordinate, and the authorizing caller. There is deliberately no
/// in-payload schema version, because `topic0` is the keccak of the full event signature and so
/// already discriminates schema on its own.
///
/// The identity is the `registrationHash`. Each token has exactly one identity, but
/// `(tokenContract, tokenId)` is not considered a unique identifier, because one contract may have
/// more than one set of ids. An example is a contract with classes of ids, where Class A id 1 and
/// Class B id 1 are different tokens; a future identifier kind separates them. Consumers must key
/// on `registrationHash` and must not collapse rows by coordinates. Contract subjects
/// (`CONTRACT` / `CONTRACT_OWNABLE`) hash the EMPTY identifier — the subject is the contract
/// itself — so a contract's own identity and its token id `0` are distinct identities.
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
/// `CONTRACT` (`TokenStandard` value 5; values 0-4 unchanged) uses the dedicated
/// `...Contract` entry points, which take no `tokenId` at all (the token surface rejects contract
/// standards with `NotTokenStandard`, and the contract surface rejects token standards with
/// `NotContractStandard`). It names a deployed contract itself rather than a token within it. The
/// bound contract itself is the only authorized emitter: the adapter's immediate EVM caller must be
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
/// `CONTRACT_OWNABLE` (appended value 6; values 0-5 unchanged) is an explicit opt-in to a second
/// authority route. The bound contract remains authorized, and its current canonical nonzero
/// `owner()` is authorized dynamically. The probe is a STATICCALL and fails closed: a revert,
/// returndata whose length is not exactly 32 bytes, dirty upper bits, or a zero owner grants nobody.
/// Ownership transfers therefore give existing claims to the new owner and remove authority from
/// the old owner without changing the immutable binding. Like `CONTRACT`, this value is outside the
/// single-owner token set and gets neither an ownerless window nor delegate.xyz authority.
///
/// A counterfactual claim has no whole-claim tombstone. Later events from the same contract only
/// supersede earlier ones by last-event-wins, and `counterfactualUnsetAgentWallet` clears the
/// wallet field alone. `CounterfactualAgentRegistered.standard` — the only counterfactual
/// event that carries a standard — remains non-indexed (the on-chain `AgentBound.standard` keeps its
/// own indexed slot). Subjects split the hash namespace through the identifier grammar: token
/// standards hash the token identifier (`0x00 || tokenId`) while the contract standards hash the
/// empty identifier, so a contract that is also an ERC-721 collection claiming token `#0` and
/// claiming itself produces two distinct, non-contesting identities. Within the token subject the
/// standard remains excluded from the hash, and consumers read the latest
/// `CounterfactualAgentRegistered.standard` in log order to see which claim currently wins.
/// For contract subjects, indexers rank contract-authored events (`emitter == tokenContract`) above
/// owner-authored ones (spec rule R-7), so a stale or hostile `owner()` key can never supersede
/// what the contract itself has said.
interface IERC8004AdapterCounterfactual {
    /// @notice Local ERC-7930 v1 Chain Identifier using CAIP-350 `eip155`: version 1, ChainType 0,
    /// shortest non-empty big-endian `block.chainid`, and zero AddressLength.
    function chainIdentifier() external view returns (bytes memory);

    /// @notice Full local ERC-7930 v1 Interoperable Address for an EVM account: the same chain
    /// envelope as `chainIdentifier()`, followed by AddressLength 20 and the raw address bytes.
    function interoperableAddress(address account) external view returns (bytes memory);

    /// @notice Computes the canonical counterfactual registration hash for a TOKEN subject:
    /// `keccak256(abi.encode(interoperableAddress(adapter), tokenContract, identifier))` with the
    /// canonical token identifier `0x00 || tokenId` (full-width 32-byte big-endian id; 33 bytes).
    /// Contract subjects (`CONTRACT` / `CONTRACT_OWNABLE`) use the single-argument overload: their
    /// identifier is EMPTY, because the subject is the contract itself and there is no token. The
    /// empty identifier is reserved for the contract subject forever, and every non-empty
    /// identifier begins with an append-only kind byte, so subject kinds can never collide.
    /// @dev The identifier is emitted on every counterfactual event, so any single event is
    /// self-verifying against its indexed hash.
    function registrationHash(address tokenContract, uint256 tokenId) external view returns (bytes32);

    /// @notice Contract-subject overload: the canonical registration hash of `tokenContract` itself.
    function registrationHash(address tokenContract) external view returns (bytes32);

    /// @notice Counterfactual registration claim. No registry write, no SSTORE.
    /// Indexers MUST treat the latest event per `registrationHash` as authoritative.
    event CounterfactualAgentRegistered(
        bytes32 indexed registrationHash,
        address indexed tokenContract,
        address indexed emitter,
        bytes identifier,
        IERCAgentBindings.TokenStandard standard,
        string agentURI,
        IERC8004IdentityRegistry.MetadataEntry[] metadata
    );

    /// @notice Counterfactual agent URI update. No registry write, no SSTORE.
    event CounterfactualAgentURISet(
        bytes32 indexed registrationHash,
        address indexed tokenContract,
        address indexed emitter,
        bytes identifier,
        string newURI
    );

    /// @notice Counterfactual metadata write. No registry write, no SSTORE.
    event CounterfactualMetadataSet(
        bytes32 indexed registrationHash,
        address indexed tokenContract,
        address indexed emitter,
        bytes identifier,
        string metadataKey,
        bytes metadataValue
    );

    /// @notice Counterfactual batch metadata write. No registry write, no SSTORE.
    event CounterfactualMetadataBatchSet(
        bytes32 indexed registrationHash,
        address indexed tokenContract,
        address indexed emitter,
        bytes identifier,
        IERC8004IdentityRegistry.MetadataEntry[] metadata
    );

    /// @notice Counterfactual agent wallet assignment. No signature, no registry write.
    event CounterfactualAgentWalletSet(
        bytes32 indexed registrationHash,
        address indexed tokenContract,
        address indexed emitter,
        bytes identifier,
        address newWallet
    );

    /// @notice Counterfactual agent wallet clear. No registry write, no SSTORE.
    event CounterfactualAgentWalletUnset(
        bytes32 indexed registrationHash, address indexed tokenContract, address indexed emitter, bytes identifier
    );
}
