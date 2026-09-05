// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {IERC8217} from "./IERC8217.sol";
import {IERC8004IdentityRegistry} from "./IERC8004IdentityRegistry.sol";

/// @notice Declares the counterfactual functions and events of `Adapter8004`, an alternative to full
/// ERC-8004 registration that records each call in the event log rather than the registry, so a claim
/// costs a log instead of a registration.
interface IERC8004AdapterCounterfactual {
    /// @notice Convenience helper that derives a UBID from user supplied arguments.
    function hashBinding(IERC8217.Standard standard, address boundAddress, uint256 tokenId)
        external
        view
        returns (bytes32);

    /// @notice Claims an identity for a bound address without registering it, returning the UBID claimed.
    function counterfactualRegister(
        IERC8217.Standard standard,
        address boundAddress,
        uint256 tokenId,
        string calldata agentURI,
        IERC8004IdentityRegistry.MetadataEntry[] memory metadata
    ) external returns (bytes32 bindingHash);

    /// @notice Overload of `counterfactualRegister` taking no metadata entries.
    function counterfactualRegister(
        IERC8217.Standard standard,
        address boundAddress,
        uint256 tokenId,
        string calldata agentURI
    ) external returns (bytes32 bindingHash);

    /// @notice Updates the agent URI for a counterfactual identity.
    function counterfactualSetAgentURI(
        IERC8217.Standard standard,
        address boundAddress,
        uint256 tokenId,
        string calldata newURI
    ) external returns (bytes32 bindingHash);

    /// @notice Records one metadata entry for a counterfactual identity.
    function counterfactualSetMetadata(
        IERC8217.Standard standard,
        address boundAddress,
        uint256 tokenId,
        string calldata metadataKey,
        bytes calldata metadataValue
    ) external returns (bytes32 bindingHash);

    /// @notice Records several metadata entries for a counterfactual identity, all on one UBID, in one event.
    function counterfactualSetMetadataBatch(
        IERC8217.Standard standard,
        address boundAddress,
        uint256 tokenId,
        IERC8004IdentityRegistry.MetadataEntry[] calldata metadata
    ) external returns (bytes32 bindingHash);

    /// @notice Assigns the agent wallet for a counterfactual identity. No signature is required, because
    /// no ERC-8004 wallet binding is created and the event is only an off-chain claim.
    function counterfactualSetAgentWallet(
        IERC8217.Standard standard,
        address boundAddress,
        uint256 tokenId,
        address newWallet
    ) external returns (bytes32 bindingHash);

    /// @notice Names the caller as this identity's agent wallet and points the caller's wallet back at
    /// it, in one call. The wallet is always `msg.sender`, which supplies consent for the reverse half,
    /// so no signature is needed and any existing designation on the caller is overwritten.
    function counterfactualSetAgentWalletAndUBID(IERC8217.Standard standard, address boundAddress, uint256 tokenId)
        external
        returns (bytes32 bindingHash);

    /// @notice Clears the agent wallet on a counterfactual identity, leaving other fields alone.
    function counterfactualUnsetAgentWallet(IERC8217.Standard standard, address boundAddress, uint256 tokenId)
        external
        returns (bytes32 bindingHash);

    // -----------------------------------------------------------------
    //  Wallet UBID: the reverse claim, wallet to UBID
    // -----------------------------------------------------------------
    //
    // The UBID a wallet picks for itself, emit-only like the rest of this interface. The adapter
    // derives the value from the coordinates rather than taking it from the caller, but the
    // designation itself is only a self-assertion, so a consumer should confirm the identity points
    // back at the wallet before trusting it. Projecting in log order, the latest `WalletUBIDSet` per
    // account wins and `WalletUBIDCleared` unsets. Only the wallet itself may emit either claim:
    // the account and actor are always `msg.sender`. Smart wallets execute these calls through
    // their own authorization policy; the adapter does not probe owners or admins on their behalf.
    // A wallet-to-agent-id surface sat here until `0.0.17` and should not be
    // re-added; see CHANGELOG 0.0.17 Removed for why.

    /// @notice Records the caller's own wallet UBID. Nothing here checks that the caller holds the token,
    /// so a consumer should confirm the identity points back at this wallet before trusting the claim.
    function setWalletUBID(IERC8217.Standard standard, address boundAddress, uint256 tokenId)
        external
        returns (bytes32 bindingHash);

    /// @notice Clears the caller's own wallet UBID. Calling it more than once, or with nothing set, is
    /// harmless and still emits `WalletUBIDCleared`, since the log is the record.
    function clearWalletUBID() external;

    /// @notice Announces a counterfactual identity claim. Consumers key on `ubid`, never on
    /// `(boundAddress, tokenId)`, which does not name a standard. Later events supersede earlier ones
    /// per UBID in log order, highest block then highest log index.
    event CounterfactualAgentRegistered(
        bytes32 indexed ubid,
        address indexed boundAddress,
        uint256 indexed tokenId,
        IERC8217.Standard standard,
        string agentURI,
        IERC8004IdentityRegistry.MetadataEntry[] metadata,
        address emitter
    );

    /// @notice Updates the agent URI for a counterfactual identity.
    event CounterfactualAgentURISet(
        bytes32 indexed ubid,
        address indexed boundAddress,
        uint256 indexed tokenId,
        IERC8217.Standard standard,
        string newURI,
        address emitter
    );

    /// @notice Records one metadata entry for a counterfactual identity.
    event CounterfactualMetadataSet(
        bytes32 indexed ubid,
        address indexed boundAddress,
        uint256 indexed tokenId,
        IERC8217.Standard standard,
        string metadataKey,
        bytes metadataValue,
        address emitter
    );

    /// @notice Records several metadata entries for a counterfactual identity in one event.
    event CounterfactualMetadataBatchSet(
        bytes32 indexed ubid,
        address indexed boundAddress,
        uint256 indexed tokenId,
        IERC8217.Standard standard,
        IERC8004IdentityRegistry.MetadataEntry[] metadata,
        address emitter
    );

    /// @notice Assigns the agent wallet for a counterfactual identity. No signature is required.
    event CounterfactualAgentWalletSet(
        bytes32 indexed ubid,
        address indexed boundAddress,
        uint256 indexed tokenId,
        IERC8217.Standard standard,
        address newWallet,
        address emitter
    );

    /// @notice Clears the agent wallet on a counterfactual identity.
    event CounterfactualAgentWalletUnset(
        bytes32 indexed ubid,
        address indexed boundAddress,
        uint256 indexed tokenId,
        IERC8217.Standard standard,
        address emitter
    );

    /// @notice Records a wallet's own UBID designation. `standard` is carried so a reader can recompute
    /// the UBID from this one log line.
    event WalletUBIDSet(
        address indexed account,
        bytes32 indexed ubid,
        address boundAddress,
        uint256 tokenId,
        IERC8217.Standard standard,
        address indexed setBy
    );

    /// @notice Clears a wallet's own UBID designation.
    event WalletUBIDCleared(address indexed account, address indexed clearedBy);
}
