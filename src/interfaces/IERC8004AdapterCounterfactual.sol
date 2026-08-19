// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {IERCAgentBindings} from "./IERCAgentBindings.sol";
import {IERC8004IdentityRegistry} from "./IERC8004IdentityRegistry.sol";

/// @notice Event-only surface for the counterfactual register family on `Adapter8004`. The functions
/// themselves stay on the adapter (they need internal helpers); this interface owns the event
/// declarations so off-chain consumers and tests can depend on a stable type without importing
/// the full contract.
///
/// Every counterfactual event below carries `bytes32 extraData` as its first non-indexed field,
/// followed by the `TokenStandard`. The three indexed slots are fixed across every event and already
/// spent on `(registrationHash, boundAddress, tokenId)`, so the standard is non-indexed; carrying it
/// on every event is what makes a single log line verifiable against the hash on its own, with no
/// lookup of the claim that created the identity. There is deliberately no in-payload schema
/// version, because `topic0` is the keccak of the full event signature and so already discriminates
/// schema on its own.
///
/// The identity is the `registrationHash`. Each token under each standard has exactly one identity,
/// but `(boundAddress, tokenId)` is not considered a unique identifier, because one contract may
/// have more than one set of ids. An example is a contract with classes of ids, where Class A id 1
/// and Class B id 1 are different tokens. `extraData` is what separates them, so consumers must key
/// on `registrationHash` and must not collapse rows by `(boundAddress, tokenId)`.
///
/// Adapter8004's existing unsigned counterfactual functions accept either ordinary current-controller
/// authority or, for ERC-721/ERC-1155F/ERC-6909F only, temporary authority from the directly calling
/// token contract while `ownerOf(tokenId)` reports no current owner. The collection must call the
/// adapter directly before mint (not through a router, forwarder, or delegatecall). A revert or
/// canonical zero response opens that window; minting to a non-collection owner closes it, while a
/// later burn can reopen it because the adapter deliberately stores no historical-existence bit.
/// Plain ERC-1155/ERC-6909 remain positive-balance controlled. Collection-authorized events retain
/// the existing schema and carry `emitter = boundAddress`; later owner/delegate events overwrite
/// them by normal log ordering.
///
/// `ACCOUNT` (`TokenStandard` value 5) uses the same unsigned
/// functions under a different authority. It names an address itself rather than a token within it,
/// so `tokenId` MUST be `0`; any other id reverts `NonZeroTokenIdForAccount`. The named address is
/// the only authorized emitter: the adapter's immediate EVM caller must be `boundAddress`. A
/// router, forwarder, or multicall that calls the adapter itself fails, since the adapter sees that
/// contract as `msg.sender`. Where the bound address is a contract, an external owner or governance
/// address may instead call an entry point on it that makes the outbound adapter call; where it is an
/// externally owned account, sending a transaction is itself that path. `delegatecall` into the adapter is
/// unsupported and dangerous, because it is a UUPS implementation with its own storage layout rather
/// than a library. Holders, an optional `owner()`, and the adapter admin have no authority, and the
/// adapter probes neither `ownerOf` nor either `balanceOf` shape. The transient single-owner window
/// above closes on mint and can reopen on burn, whereas an account-level binding has no token whose
/// ownership could change hands, so its authority window never closes. An ERC-20 claiming its own
/// contract-level identity through `ACCOUNT` is the motivating example, and there is no
/// ERC-20-specific standard value.
///
/// **`ACCOUNT` accepts any address, with or without runtime code, and applies no code test at all.**
/// It is the only standard that does not, and it can afford not to because it never calls the
/// address it names: authority is the single comparison `msg.sender == boundAddress`, which is well
/// defined either way. The zero address and the identity registry are still rejected. A plain
/// externally-owned account and a deployed contract are therefore equally valid subjects, which is
/// the point of the standard.
///
/// Under EIP-7702 an externally-owned account can carry code, so `msg.sender == boundAddress` is
/// not proof of key possession. Authority means, exactly, whoever can cause a call to originate from
/// that address. For an undelegated account that is the key holder. For a delegated one it is the
/// key holder plus anyone who can drive the delegate to make an outbound call, which for the common
/// batch-executor delegate is a broad set. **An address bound as `ACCOUNT` can install a 7702
/// delegation afterwards, and doing so permanently widens who can act for that identity.** Revoking
/// the delegation narrows it again, but the binding is immutable and cannot be undone. This is the
/// same accepted shape as a `CONTRACT_OWNABLE` binding whose contract renounces ownership: an action
/// outside the adapter, taken by the party the standard trusts, that permanently changes who can
/// authorize and that the adapter will not second-guess. Counterfactual claims are less exposed than
/// bindings, because they are emit-only and last-event-wins, so a key holder who revokes a
/// delegation can re-emit and their claim wins again.
///
/// `CONTRACT_OWNABLE` (`TokenStandard` value 6) is an explicit opt-in to a second
/// authority route. Authority is the contract's current canonical nonzero `owner()`, resolved
/// dynamically, and not the bound contract itself. The probe is a STATICCALL and fails closed: a revert,
/// returndata whose length is not exactly 32 bytes, dirty upper bits, or a zero owner grants nobody.
/// Ownership transfers therefore give existing claims to the new owner and remove authority from
/// the old owner without changing the immutable binding, and they also end any delegation the former
/// owner had granted. A delegate of the current owner is authorized as well, through a
/// contract-scoped delegate.xyz check rather than a token-scoped one, because the binding names a
/// contract rather than a token. Like `ACCOUNT`, this value is outside the single-owner token set
/// and gets no ownerless window. Because there is no contract-self fallback, a contract that
/// renounces ownership permanently freezes the identity: no owner means nobody left to authorize.
///
/// `CONTRACT_ADMIN` (`TokenStandard` value 7) is the same idea for an AccessControl
/// contract that exposes no `owner()`. Authority is any holder of its `DEFAULT_ADMIN_ROLE`, which is
/// `bytes32(0)`, and not the bound contract itself. The `hasRole` probe is a STATICCALL and fails
/// closed: a revert, returndata whose length is not exactly 32 bytes, or a zero word grants nobody.
/// Role membership is read on every call, so revoking it removes authority immediately. There is no
/// delegate.xyz route, because a role is a membership predicate that many addresses can satisfy and
/// none can enumerate, so there is no well-defined delegator to name. Like the other two contract
/// values it is outside the single-owner token set and gets no ownerless window.
///
/// A counterfactual claim cannot be withdrawn. Later events from the same contract only
/// supersede earlier ones by last-event-wins, and `counterfactualUnsetAgentWallet` clears the
/// wallet field alone. The event schema and indexed topics do not vary by account-level standard,
/// and every counterfactual event carries the standard non-indexed. The on-chain `AgentBound.standard`
/// keeps its own indexed slot.
///
/// **The standard is part of the identity.** It sits in the `registrationHash` preimage as its
/// `uint8`, so two standards claiming the same `(boundAddress, tokenId)` are two identities and never
/// alias. A contract that is also an ERC-721 collection, claiming token `#0`, `ACCOUNT`, and
/// `CONTRACT_OWNABLE` at `(X, 0)`, is the worked example: three coordinates, three distinct hashes,
/// three separate histories. Last-event-wins therefore resolves within one standard only, and no
/// claimant's history can be superseded, or attributed to, a different claimant who reached the same
/// `(boundAddress, tokenId)` through a different authority route.
///
/// What the standard in the hash records is that the claimer passed *that standard's* authority probe
/// at claim time. It is not an assertion that the bound contract conforms to the ERC: the adapter
/// probes authority, not interface support, and never calls `supportsInterface`. A claim under
/// `ERC721` means `ownerOf` answered and named the caller, or the collection called during its own
/// ownerless window. It does not certify that the contract is a well-formed ERC-721.
interface IERC8004AdapterCounterfactual {
    /// @notice Local ERC-7930 v1 Chain Identifier using CAIP-350 `eip155`: version 1, ChainType 0,
    /// shortest non-empty big-endian `block.chainid`, and zero AddressLength.
    function chainIdentifier() external view returns (bytes memory);

    /// @notice Full local ERC-7930 v1 Interoperable Address for an EVM account: the same chain
    /// envelope as `chainIdentifier()`, followed by AddressLength 20 and the raw address bytes.
    function interoperableAddress(address account) external view returns (bytes memory);

    /// @notice Computes the canonical counterfactual registration hash, scoped to this chain and this
    /// adapter proxy, so off-chain consumers can derive it without reimplementing the rules. The
    /// identity is
    /// `keccak256(abi.encode(interoperableAddress(adapter), standard, boundAddress, tokenId, extraData))`,
    /// with `standard` encoded as the `TokenStandard` enum's `uint8` and `extraData` fixed at
    /// `bytes32(0)` for every implementation of this baseline. Always `abi.encode`, never
    /// `abi.encodePacked`.
    /// @dev `extraData` is deliberately not a parameter anywhere on this surface, because it is
    /// reserved rather than used. Read its value from the `extraData` field on any counterfactual
    /// event. `standard` is a parameter, because it selects the identity: the same
    /// `(boundAddress, tokenId)` under two standards yields two different hashes.
    function registrationHash(IERCAgentBindings.TokenStandard standard, address boundAddress, uint256 tokenId)
        external
        view
        returns (bytes32);

    /// @notice Announces a counterfactual identity claim for a bound address. The claim lives
    /// entirely in the event log. Indexers MUST treat the latest event per `registrationHash` as
    /// authoritative, latest meaning highest block number, then highest log index.
    event CounterfactualAgentRegistered(
        bytes32 indexed registrationHash,
        address indexed boundAddress,
        uint256 indexed tokenId,
        bytes32 extraData,
        IERCAgentBindings.TokenStandard standard,
        string agentURI,
        IERC8004IdentityRegistry.MetadataEntry[] metadata,
        address emitter
    );

    /// @notice Updates the agent URI for a counterfactual identity. The update lives entirely in the
    /// event log.
    event CounterfactualAgentURISet(
        bytes32 indexed registrationHash,
        address indexed boundAddress,
        uint256 indexed tokenId,
        bytes32 extraData,
        IERCAgentBindings.TokenStandard standard,
        string newURI,
        address emitter
    );

    /// @notice Records one metadata entry for a counterfactual identity. The entry is carried only by
    /// this event, so nothing is written to the ERC-8004 registry or to adapter storage.
    event CounterfactualMetadataSet(
        bytes32 indexed registrationHash,
        address indexed boundAddress,
        uint256 indexed tokenId,
        bytes32 extraData,
        IERCAgentBindings.TokenStandard standard,
        string metadataKey,
        bytes metadataValue,
        address emitter
    );

    /// @notice Records several metadata entries for a counterfactual identity in one event. The
    /// entries are carried only by this event, so nothing is written to the ERC-8004 registry or to
    /// adapter storage.
    event CounterfactualMetadataBatchSet(
        bytes32 indexed registrationHash,
        address indexed boundAddress,
        uint256 indexed tokenId,
        bytes32 extraData,
        IERCAgentBindings.TokenStandard standard,
        IERC8004IdentityRegistry.MetadataEntry[] metadata,
        address emitter
    );

    /// @notice Assigns the agent wallet for a counterfactual identity. No signature is required, and
    /// the assignment is carried only by this event, so nothing is written to the ERC-8004 registry.
    event CounterfactualAgentWalletSet(
        bytes32 indexed registrationHash,
        address indexed boundAddress,
        uint256 indexed tokenId,
        bytes32 extraData,
        IERCAgentBindings.TokenStandard standard,
        address newWallet,
        address emitter
    );

    /// @notice Clears the agent wallet on a counterfactual identity. The clear is carried only by this
    /// event, so nothing is written to the ERC-8004 registry or to adapter storage.
    event CounterfactualAgentWalletUnset(
        bytes32 indexed registrationHash,
        address indexed boundAddress,
        uint256 indexed tokenId,
        bytes32 extraData,
        IERCAgentBindings.TokenStandard standard,
        address emitter
    );
}
