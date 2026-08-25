// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {IERC8217} from "./IERC8217.sol";
import {IERC8004IdentityRegistry} from "./IERC8004IdentityRegistry.sol";

/// @notice Declares the counterfactual functions and events of `Adapter8004`. The implementations
/// live on the adapter. The surface writes no storage: every call is recorded entirely in the event
/// log.
///
/// The Universal Binding Identifier, or UBI, is the hash of a binding, derived as
/// `keccak256(abi.encode(bindingContractInteroperableAddress, standard, boundAddress, tokenId))`
/// using `abi.encode` and never `abi.encodePacked`. `standard` is the `Standard` enum as its
/// `uint8`. The authority rules for each standard are documented on that enum in
/// `IERC8217`.
///
/// A counterfactual registration is a claim about a binding that could be made, recorded in the log
/// without being performed, and the UBI is the same value whether or not the binding is ever
/// performed.
///
/// Every counterfactual event carries the `Standard` as its first non-indexed field, so one log
/// line is verifiable on its own without looking up the claim that created the identity. The three
/// indexed fields are `(ubi, boundAddress, tokenId)` on every event.
///
/// Consumers key on the UBI. They must not collapse rows by `(boundAddress, tokenId)`: that pair
/// does not name a standard, and the same pair under two standards is two identities.
///
/// Later events supersede earlier ones per UBI in log order, latest meaning highest block number
/// then highest log index. `counterfactualUnsetAgentWallet` clears the wallet field alone.
interface IERC8004AdapterCounterfactual {
    /// @notice Returns the UBI for a set of coordinates, scoped to this chain and this adapter.
    /// @dev The four components are the adapter address plus exactly the stored `Binding`, so the
    /// coordinates alone determine the value and `bindingHashOf(agentId)` returns the same value for
    /// a registered agent. `standard` selects the identity: the same `(boundAddress, tokenId)` under
    /// two standards yields two different hashes.
    function bindingHashFor(IERC8217.Standard standard, address boundAddress, uint256 tokenId)
        external
        view
        returns (bytes32);

    /// @notice Announce an identity claim for a bound address, recorded entirely in the event log. A
    /// current controller may call this, as may a collection calling directly while one of its
    /// ERC-721, ERC-1155F or ERC-6909F ids has no current owner. Collection-authorized events set
    /// `emitter = boundAddress`, and the same authority may re-emit any number of times.
    /// @return bindingHash The identity claimed, matching `bindingHashFor(standard, boundAddress, tokenId)`.
    function counterfactualRegister(
        IERC8217.Standard standard,
        address boundAddress,
        uint256 tokenId,
        string calldata agentURI,
        IERC8004IdentityRegistry.MetadataEntry[] memory metadata
    ) external returns (bytes32 bindingHash);

    /// @notice Convenience overload equivalent to `counterfactualRegister(...)` with an empty metadata array.
    /// @return bindingHash The identity claimed, matching `bindingHashFor(standard, boundAddress, tokenId)`.
    function counterfactualRegister(
        IERC8217.Standard standard,
        address boundAddress,
        uint256 tokenId,
        string calldata agentURI
    ) external returns (bytes32 bindingHash);

    /// @notice Update the agent URI for a counterfactual identity. The update lives entirely in the
    /// event log. A current controller may call this, as may a collection calling directly while a
    /// supported single-owner id has no current owner.
    /// @return bindingHash The identity updated, matching `bindingHashFor(standard, boundAddress, tokenId)`.
    function counterfactualSetAgentURI(
        IERC8217.Standard standard,
        address boundAddress,
        uint256 tokenId,
        string calldata newURI
    ) external returns (bytes32 bindingHash);

    /// @notice Records one metadata entry for a counterfactual identity. The entry is carried only by
    /// the emitted event, so nothing is written to the ERC-8004 registry or to adapter storage. A
    /// current controller may call it, as may the token contract itself while a supported
    /// single-owner id has no current owner.
    /// @return bindingHash The identity written to, matching `bindingHashFor(standard, boundAddress, tokenId)`.
    function counterfactualSetMetadata(
        IERC8217.Standard standard,
        address boundAddress,
        uint256 tokenId,
        string calldata metadataKey,
        bytes calldata metadataValue
    ) external returns (bytes32 bindingHash);

    /// @notice Records several metadata entries for a counterfactual identity in one event. The
    /// entries are carried only by that event, so nothing is written to the ERC-8004 registry or to
    /// adapter storage. A current controller may call it, as may the token contract itself while a
    /// supported single-owner id has no current owner.
    /// @return bindingHash The single identity every entry lands on, matching
    /// `bindingHashFor(standard, boundAddress, tokenId)`.
    function counterfactualSetMetadataBatch(
        IERC8217.Standard standard,
        address boundAddress,
        uint256 tokenId,
        IERC8004IdentityRegistry.MetadataEntry[] calldata metadata
    ) external returns (bytes32 bindingHash);

    /// @notice Assigns the agent wallet for a counterfactual identity. It deliberately accepts no
    /// signature, because no ERC-8004 wallet binding is created and the event is only an off-chain
    /// claim. A current controller may call it, as may the token contract itself while a supported
    /// single-owner id has no current owner.
    /// @return bindingHash The identity updated, matching `bindingHashFor(standard, boundAddress, tokenId)`.
    function counterfactualSetAgentWallet(
        IERC8217.Standard standard,
        address boundAddress,
        uint256 tokenId,
        address newWallet
    ) external returns (bytes32 bindingHash);

    /// @notice Name yourself as this identity's agent wallet and point your wallet back at it, in one
    /// call. The caller proves control of the token, which authorizes the forward write, and the
    /// caller is the wallet, which supplies consent for the reverse one, so both halves are
    /// legitimate with no signature needed.
    /// @dev The wallet is always `msg.sender`, so two records that agree show one actor was
    /// authorized on both sides, the emitted pair matches what the separate calls emit, and any
    /// existing designation on the caller is overwritten.
    /// @return bindingHash The identity named, matching
    /// `bindingHashFor(standard, boundAddress, tokenId)` and the hash both emitted events carry.
    function counterfactualSetAgentWalletAndUBI(IERC8217.Standard standard, address boundAddress, uint256 tokenId)
        external
        returns (bytes32 bindingHash);

    /// @notice Clears the agent wallet on a counterfactual identity. The clear is carried only by the
    /// emitted event, so nothing is written to the ERC-8004 registry or to adapter storage. A current
    /// controller may call it, as may the token contract itself while a supported single-owner id has
    /// no current owner.
    /// @return bindingHash The identity cleared, matching `bindingHashFor(standard, boundAddress, tokenId)`.
    function counterfactualUnsetAgentWallet(IERC8217.Standard standard, address boundAddress, uint256 tokenId)
        external
        returns (bytes32 bindingHash);

    // -----------------------------------------------------------------
    //  Wallet UBI: the reverse claim, wallet to UBI
    // -----------------------------------------------------------------
    //
    // The UBI a wallet picks for itself, recorded entirely in the event log. Values are always
    // derived by the adapter from the standard and token coordinates, never supplied by the caller,
    // and the designation is a self-assertion that a consumer must verify reciprocally before
    // treating it as identity.
    //
    // **Emit-only, like the attestation surface and for the same reason.** The contract verifies
    // that the caller holds the authority to designate and then records that fact; nothing is
    // stored. The identifier needs no storage because it is derived from coordinates, so only the
    // designation is a choice, and a choice lives in a log as well as in a slot. What makes the log
    // trustworthy is the authority check, not the storage. Resolution therefore belongs to indexers,
    // exactly as it does for attestations.
    //
    // **Projection rules, applied in log order.** For each account, the latest `WalletUBISet` wins
    // and `WalletUBICleared` unsets. Latest means highest block number, then highest log index. A
    // clear from a different authorized party than the one that set is honoured, because both
    // functions authorize against the account rather than against whoever wrote last: the `For`
    // variants accept the account itself, its `owner()` or `getOwner()`, or a holder of its
    // `DEFAULT_ADMIN_ROLE`, so any of them may undo any other. An account with no `WalletUBISet`
    // after its last `WalletUBICleared`, or with none at all, has no designation.
    //
    // It lives on the counterfactual interface because the division that matters is
    // derivable-from-coordinates against requires-an-actual-registration, and this sits on the
    // derivable side. Counterfactual here does not mean hypothetical, it means determined in
    // advance: all four inputs exist, so the UBI exists, and performing the binding neither creates
    // nor changes it, exactly as a CREATE2 address is known before deployment.
    //
    // **There was a wallet-to-agent-id surface beside this one until `0.0.17`, and it should not be
    // re-added.** ERC-8217 argues that an agent id is meaningful only inside the registry that
    // issued it and is therefore not a universal identifier, so a reverse-resolution surface keyed
    // on agent ids had the contract contradicting the standard. Nothing reconciled the two either:
    // a wallet could point them at unrelated things and no rule said which a consumer should
    // believe. The agent-id half was also the less checkable, returning a bare number no consumer
    // could verify without already knowing the registry, while the adapter had verified nothing.

    /// @notice `standard` is the `Standard` folded into the UBI. It is carried here
    /// because `(boundAddress, tokenId)` alone does not name an identity, so a reader can recompute
    /// the hash from this one log line. See `IERC8004AdapterCounterfactual`.
    event WalletUBISet(
        address indexed account,
        bytes32 indexed ubi,
        address boundAddress,
        uint256 tokenId,
        IERC8217.Standard standard,
        address indexed setBy
    );
    event WalletUBICleared(address indexed account, address indexed clearedBy);

    /// @notice Record the caller's own wallet UBI, named by standard and token
    /// coordinates. The adapter derives the UBI itself, so a caller cannot assert a
    /// hash it did not compute from a real triple. `standard` selects which identity is named: the
    /// same `(boundAddress, tokenId)` under two standards resolves to two different hashes. This is a
    /// self-assertion and is not proof: nothing here checks that the caller holds the token or would
    /// pass that standard's authority probe, so a consumer must verify the claim reciprocally before
    /// treating it as identity. Emits `WalletUBISet` and returns the derived hash.
    function setWalletUBI(IERC8217.Standard standard, address boundAddress, uint256 tokenId)
        external
        returns (bytes32 ubi);

    /// @notice Record `account`'s wallet UBI on its behalf. Authorized when the
    /// caller is the account itself, its `owner()` or `getOwner()`, or a holder of its
    /// `DEFAULT_ADMIN_ROLE`, and reverts `NotAccountController` otherwise. An account that misreports
    /// its controller can only affect its own entry.
    function setWalletUBIFor(address account, IERC8217.Standard standard, address boundAddress, uint256 tokenId)
        external
        returns (bytes32 ubi);

    /// @notice Clear the caller's own wallet UBI. Idempotent, and clearing an account that never set
    /// one still emits `WalletUBICleared`, because the log is the record.
    function clearWalletUBI() external;

    /// @notice Clear `account`'s wallet UBI, under the same authorization rules as
    /// `setWalletUBIFor`.
    function clearWalletUBIFor(address account) external;

    /// @notice Announces a counterfactual identity claim for a bound address. The claim lives
    /// entirely in the event log. Indexers MUST treat the latest event per UBI as
    /// authoritative, latest meaning highest block number, then highest log index.
    event CounterfactualAgentRegistered(
        bytes32 indexed ubi,
        address indexed boundAddress,
        uint256 indexed tokenId,
        IERC8217.Standard standard,
        string agentURI,
        IERC8004IdentityRegistry.MetadataEntry[] metadata,
        address emitter
    );

    /// @notice Updates the agent URI for a counterfactual identity. The update lives entirely in the
    /// event log.
    event CounterfactualAgentURISet(
        bytes32 indexed ubi,
        address indexed boundAddress,
        uint256 indexed tokenId,
        IERC8217.Standard standard,
        string newURI,
        address emitter
    );

    /// @notice Records one metadata entry for a counterfactual identity. The entry is carried only by
    /// this event, so nothing is written to the ERC-8004 registry or to adapter storage.
    event CounterfactualMetadataSet(
        bytes32 indexed ubi,
        address indexed boundAddress,
        uint256 indexed tokenId,
        IERC8217.Standard standard,
        string metadataKey,
        bytes metadataValue,
        address emitter
    );

    /// @notice Records several metadata entries for a counterfactual identity in one event. The
    /// entries are carried only by this event, so nothing is written to the ERC-8004 registry or to
    /// adapter storage.
    event CounterfactualMetadataBatchSet(
        bytes32 indexed ubi,
        address indexed boundAddress,
        uint256 indexed tokenId,
        IERC8217.Standard standard,
        IERC8004IdentityRegistry.MetadataEntry[] metadata,
        address emitter
    );

    /// @notice Assigns the agent wallet for a counterfactual identity. No signature is required, and
    /// the assignment is carried only by this event, so nothing is written to the ERC-8004 registry.
    event CounterfactualAgentWalletSet(
        bytes32 indexed ubi,
        address indexed boundAddress,
        uint256 indexed tokenId,
        IERC8217.Standard standard,
        address newWallet,
        address emitter
    );

    /// @notice Clears the agent wallet on a counterfactual identity. The clear is carried only by this
    /// event, so nothing is written to the ERC-8004 registry or to adapter storage.
    event CounterfactualAgentWalletUnset(
        bytes32 indexed ubi,
        address indexed boundAddress,
        uint256 indexed tokenId,
        IERC8217.Standard standard,
        address emitter
    );
}
