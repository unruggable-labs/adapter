// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {IERC721} from "@openzeppelin/contracts/token/ERC721/IERC721.sol";
import {IERC721Receiver} from "@openzeppelin/contracts/token/ERC721/IERC721Receiver.sol";
import {IERC1155} from "@openzeppelin/contracts/token/ERC1155/IERC1155.sol";
import {IERC6909} from "@openzeppelin/contracts/interfaces/IERC6909.sol";
import {ReentrancyGuard} from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import {Initializable} from "@openzeppelin/contracts-upgradeable/proxy/utils/Initializable.sol";
import {OwnableUpgradeable} from "@openzeppelin/contracts-upgradeable/access/OwnableUpgradeable.sol";
import {UUPSUpgradeable} from "@openzeppelin/contracts-upgradeable/proxy/utils/UUPSUpgradeable.sol";
import {IDelegateRegistry} from "./interfaces/IDelegateRegistry.sol";
import {IERCAgentBindings} from "./interfaces/IERCAgentBindings.sol";
import {IERC8004AdapterCounterfactual} from "./interfaces/IERC8004AdapterCounterfactual.sol";
import {IERC8004AdapterRegistration} from "./interfaces/IERC8004AdapterRegistration.sol";
import {IERC8004IdentityRecord} from "./interfaces/IERC8004IdentityRecord.sol";
import {IERC8004IdentityRegistry} from "./interfaces/IERC8004IdentityRegistry.sol";

/// @custom:version 0.0.6
contract Adapter8004 is
    Initializable,
    OwnableUpgradeable,
    UUPSUpgradeable,
    ReentrancyGuard,
    IERC721Receiver,
    IERCAgentBindings,
    IERC8004IdentityRecord,
    IERC8004AdapterRegistration,
    IERC8004AdapterCounterfactual
{
    string public constant BINDING_METADATA_KEY = "agent-binding";
    bytes32 private constant BINDING_METADATA_KEY_HASH = keccak256(bytes(BINDING_METADATA_KEY));

    /// @notice Reserved canonical-promotion metadata key. A counterfactual write that targets this
    /// key would let a caller fabricate a promotion back-link before any canonical ERC-8004 mint has
    /// occurred. The reservation is therefore enforced on every counterfactual write path.
    string public constant CF_REGISTRATION_KEY = "cf-registration";
    bytes32 private constant CF_REGISTRATION_KEY_HASH = keccak256(bytes(CF_REGISTRATION_KEY));

    /// @notice Canonical immutable delegate.xyz v2 registry, identical on Ethereum, Base, and Sepolia.
    /// A delegated hot wallet authorized here can drive ERC-721-bound agents while the NFT stays in
    /// cold storage. Authorization fails closed to direct ownership when the registry has no code.
    address public constant DELEGATE_REGISTRY = 0x00000000000000447e69651d841bD8D104Bed493;

    /// @notice Rights identifier a cold wallet delegates to scope a hot wallet to Adapter8004 management
    /// only. delegate.xyz v2 also accepts empty/full delegations when this nonzero rights value is checked.
    bytes32 public constant DELEGATE_RIGHTS = keccak256("adapter8004.manage");

    /// @notice Schema version emitted as the first non-indexed field on every counterfactual event.
    /// Bumped only on payload-structure breakage (re-ordered or removed fields).
    ///
    /// !! BREAKING CHANGE WARNING !!
    /// Adding, removing, or reordering any field in a counterfactual event (including this
    /// `uint8 version` field itself) changes the event signature, which changes the keccak256
    /// topic[0]. Indexers watching the old topic stop receiving events on the upgraded
    /// implementation. Treat any change to this constant or to the surrounding event ABIs as
    /// a hard cutover: bump the implementation, document the cutover block, and require every
    /// downstream indexer to subscribe to the new topics from that block forward.
    uint8 private constant COUNTERFACTUAL_PAYLOAD_VERSION = 1;

    error InvalidTokenContract();
    /// @notice Thrown when a binding attempts to set `tokenContract` to the ERC-8004 identity registry
    /// itself. Permitted-and-then-bound, the agent would be permanently uncontrollable because
    /// `ownerOf(tokenId)` on the registry resolves to the adapter post-bind, locking the only path
    /// through `_hasBindingControl`.
    error InvalidTokenContractIsRegistry();
    error ReservedMetadataKey(string metadataKey);
    error NotController(address account, uint256 agentId);
    error UnknownAgent(uint256 agentId);
    error AlreadyBound(uint256 agentId);
    error NotAgentOwner(uint256 agentId, address owner);
    error AgentTransferNotApproved(uint256 agentId);

    event AgentBound(
        uint256 indexed agentId,
        TokenStandard indexed standard,
        address indexed tokenContract,
        uint256 tokenId,
        address registeredBy
    );

    event MetadataBatchSet(uint256 indexed agentId, uint256 count, address indexed updatedBy);
    event IdentityRegistryUpdated(
        address indexed previousRegistry, address indexed newRegistry, address indexed updatedBy
    );

    event AgentURISet(uint256 indexed agentId, string newURI, address indexed updatedBy);
    event MetadataSet(uint256 indexed agentId, string metadataKey, bytes metadataValue, address indexed updatedBy);
    event AgentWalletSet(uint256 indexed agentId, address indexed newWallet, address indexed updatedBy);
    event AgentWalletUnset(uint256 indexed agentId, address indexed updatedBy);
    event BindingMetadataRewritten(uint256 indexed agentId, address indexed updatedBy);

    IERC8004IdentityRegistry public identityRegistry;

    mapping(uint256 agentId => Binding binding) private _bindings;

    /// @custom:oz-upgrades-unsafe-allow constructor
    constructor() {
        _disableInitializers();
    }

    function initialize(address identityRegistry_, address initialOwner) external initializer {
        // 1. Reject an unusable registry target before any state is initialized.
        if (identityRegistry_ == address(0)) {
            revert InvalidTokenContract();
        }

        // 2. Set the adapter admin who controls upgrades and registry repointing.
        __Ownable_init(initialOwner);

        // 3. Store the initial ERC-8004 registry the adapter will forward into.
        identityRegistry = IERC8004IdentityRegistry(identityRegistry_);
    }

    function setIdentityRegistry(address newIdentityRegistry) external onlyOwner nonReentrant {
        // 1. Reject an unusable registry target.
        if (newIdentityRegistry == address(0)) {
            revert InvalidTokenContract();
        }

        // 2. Capture the previous address for upgrade/migration observability.
        address previousRegistry = address(identityRegistry);

        // 3. Repoint future adapter calls to the new ERC-8004 registry.
        identityRegistry = IERC8004IdentityRegistry(newIdentityRegistry);

        // 4. Emit the registry change so indexers and operators can track migrations.
        emit IdentityRegistryUpdated(previousRegistry, newIdentityRegistry, msg.sender);
    }

    function register(
        TokenStandard standard,
        address tokenContract,
        uint256 tokenId,
        string calldata agentURI,
        IERC8004IdentityRegistry.MetadataEntry[] memory metadata
    ) public nonReentrant returns (uint256 agentId) {
        return _registerImpl(standard, tokenContract, tokenId, agentURI, metadata);
    }

    function register(TokenStandard standard, address tokenContract, uint256 tokenId, string calldata agentURI)
        external
        nonReentrant
        returns (uint256 agentId)
    {
        return
            _registerImpl(standard, tokenContract, tokenId, agentURI, new IERC8004IdentityRegistry.MetadataEntry[](0));
    }

    function bindExisting(uint256 agentId, TokenStandard standard, address tokenContract, uint256 tokenId)
        external
        nonReentrant
    {
        // 1. Reject an unusable external token contract address (matches `register` taxonomy) and
        //    reject the registry itself, which would lock the agent permanently post-bind.
        _requireValidTokenContract(tokenContract);

        // 2. Reject an already-bound agent so adapter bindings remain immutable post-bind.
        if (_bindings[agentId].tokenContract != address(0)) {
            revert AlreadyBound(agentId);
        }

        // 3. Require the caller to own the ERC-8004 agent in the registry. An external-token
        //    controller cannot pull a stranger's agent into the adapter just because the adapter
        //    happens to be approved. `ownerOf` will surface its native revert for unknown ids.
        address owner = identityRegistry.ownerOf(agentId);
        if (owner != msg.sender) {
            revert NotAgentOwner(agentId, owner);
        }

        // 4. Require external-token binding control under the existing authority model
        //    (direct ownership for ERC-721/1155/6909, plus delegate.xyz v2 for ERC-721).
        _requireBindingControl(standard, tokenContract, tokenId, msg.sender);

        // 5. Require the adapter to have prior ERC-721 transfer approval for `agentId` —
        //    either per-token (`approve`) or operator-level (`setApprovalForAll`).
        _requireAgentTransferApproval(agentId, msg.sender);

        // 6. Transfer the ERC-8004 identity into the adapter before any adapter storage or
        //    registry-metadata writes. Any failure here reverts the whole transaction with no
        //    adapter state changes.
        IERC721(address(identityRegistry)).transferFrom(msg.sender, address(this), agentId);

        // 7. Persist the immutable adapter binding for this agent.
        _bindings[agentId] = Binding({standard: standard, tokenContract: tokenContract, tokenId: tokenId});

        // 8. Overwrite the canonical binding metadata to point at this adapter. Any pre-existing
        //    value at the reserved key (arbitrary user data or a value pointing at another adapter)
        //    is intentionally replaced once the adapter owns the identity.
        identityRegistry.setMetadata(agentId, BINDING_METADATA_KEY, abi.encodePacked(address(this)));

        // 9. Emit the existing binding event so indexers do not need a separate event family.
        emit AgentBound(agentId, standard, tokenContract, tokenId, msg.sender);
    }

    function _registerImpl(
        TokenStandard standard,
        address tokenContract,
        uint256 tokenId,
        string calldata agentURI,
        IERC8004IdentityRegistry.MetadataEntry[] memory metadata
    ) private returns (uint256 agentId) {
        // 1. Reject an unusable external token contract address, and reject the registry itself
        //    (binding to the registry would lock the agent permanently post-register).
        _requireValidTokenContract(tokenContract);

        // 2. Confirm the caller currently controls the token being bound.
        _requireBindingControl(standard, tokenContract, tokenId, msg.sender);

        // 3. Reject user-supplied metadata entries that try to override the canonical binding record.
        _requireNoReservedBindingKey(metadata);

        // 4. Register the ERC-8004 identity so the adapter becomes the registry owner.
        //    Skip the metadata-array overload when there is nothing to write — saves the
        //    empty-array calldata + memory copy on the registry side.
        if (metadata.length == 0) {
            agentId = identityRegistry.register(agentURI);
        } else {
            agentId = identityRegistry.register(agentURI, metadata);
        }

        // 5. Persist the immutable link from the ERC-8004 agent to the external token.
        _bindings[agentId] = Binding({standard: standard, tokenContract: tokenContract, tokenId: tokenId});

        // 6. Write the canonical binding metadata (binding contract address only; ERC-8217).
        identityRegistry.setMetadata(agentId, BINDING_METADATA_KEY, abi.encodePacked(address(this)));

        // 7. Clear the default ERC-8004 wallet because registration set it to the adapter.
        identityRegistry.unsetAgentWallet(agentId);

        // 8. Emit the final binding record for off-chain discovery.
        emit AgentBound(agentId, standard, tokenContract, tokenId, msg.sender);
    }

    function getMetadata(uint256 agentId, string memory metadataKey) external view returns (bytes memory) {
        return identityRegistry.getMetadata(agentId, metadataKey);
    }

    function getAgentWallet(uint256 agentId) external view returns (address) {
        return identityRegistry.getAgentWallet(agentId);
    }

    function ownerOf(uint256 agentId) external view returns (address) {
        return identityRegistry.ownerOf(agentId);
    }

    function tokenURI(uint256 agentId) external view returns (string memory) {
        return identityRegistry.tokenURI(agentId);
    }

    function setAgentURI(uint256 agentId, string calldata newURI) external nonReentrant {
        // 1. Confirm the caller currently controls the bound token.
        _requireController(agentId, msg.sender);

        // 2. Forward the URI update into the ERC-8004 registry.
        identityRegistry.setAgentURI(agentId, newURI);

        // 3. Emit the adapter-level URI update after the forwarded registry call succeeds.
        emit AgentURISet(agentId, newURI, msg.sender);
    }

    function setMetadata(uint256 agentId, string memory metadataKey, bytes memory metadataValue)
        external
        nonReentrant
    {
        // 1. Confirm the caller currently controls the bound token.
        _requireController(agentId, msg.sender);

        // 2. Prevent callers from overwriting the canonical binding metadata.
        if (keccak256(bytes(metadataKey)) == BINDING_METADATA_KEY_HASH) {
            revert ReservedMetadataKey(metadataKey);
        }

        // 3. Forward the metadata write into the ERC-8004 registry.
        identityRegistry.setMetadata(agentId, metadataKey, metadataValue);

        // 4. Emit the adapter-level metadata write after the forwarded registry call succeeds.
        emit MetadataSet(agentId, metadataKey, metadataValue, msg.sender);
    }

    function setMetadataBatch(uint256 agentId, IERC8004IdentityRegistry.MetadataEntry[] calldata metadata)
        external
        nonReentrant
    {
        // 1. Confirm the caller currently controls the bound token.
        _requireController(agentId, msg.sender);

        // 2. Prevent callers from overwriting the canonical binding metadata.
        _requireNoReservedBindingKey(metadata);

        // 3. Replay each metadata write through the ERC-8004 registry one by one.
        uint256 length = metadata.length;
        for (uint256 i; i < length; ++i) {
            identityRegistry.setMetadata(agentId, metadata[i].metadataKey, metadata[i].metadataValue);
        }

        // 4. Emit one adapter-level event describing the batch operation.
        emit MetadataBatchSet(agentId, length, msg.sender);
    }

    /// @notice Owner-only migration helper to rewrite legacy `agent-binding` rows into the ERC-8217 20-byte format.
    function rewriteBindingMetadata(uint256 agentId) external onlyOwner nonReentrant {
        // 1. Reject unknown agents before touching registry state.
        Binding memory binding = _bindings[agentId];
        if (binding.tokenContract == address(0)) {
            revert UnknownAgent(agentId);
        }

        // 2. Rewrite the canonical metadata using the proxy address as the binding contract.
        identityRegistry.setMetadata(agentId, BINDING_METADATA_KEY, abi.encodePacked(address(this)));

        // 3. Emit the adapter-level rewrite event after the forwarded registry call succeeds.
        emit BindingMetadataRewritten(agentId, msg.sender);
    }

    function setAgentWallet(uint256 agentId, address newWallet, uint256 deadline, bytes calldata signature)
        external
        nonReentrant
    {
        // 1. Confirm the caller currently controls the bound token.
        _requireController(agentId, msg.sender);

        // 2. Forward the wallet assignment to ERC-8004, which enforces the wallet proof.
        identityRegistry.setAgentWallet(agentId, newWallet, deadline, signature);

        // 3. Emit the adapter-level wallet assignment after the forwarded registry call succeeds.
        emit AgentWalletSet(agentId, newWallet, msg.sender);
    }

    function unsetAgentWallet(uint256 agentId) external nonReentrant {
        // 1. Confirm the caller currently controls the bound token.
        _requireController(agentId, msg.sender);

        // 2. Forward the wallet clear operation to the ERC-8004 registry.
        identityRegistry.unsetAgentWallet(agentId);

        // 3. Emit the adapter-level wallet clear after the forwarded registry call succeeds.
        emit AgentWalletUnset(agentId, msg.sender);
    }

    function bindingOf(uint256 agentId) external view returns (Binding memory) {
        // 1. Load the stored binding for the requested agent.
        Binding memory binding = _bindings[agentId];

        // 2. Reject unknown agents instead of returning an empty struct.
        if (binding.tokenContract == address(0)) {
            revert UnknownAgent(agentId);
        }

        // 3. Return the immutable token binding.
        return binding;
    }

    function isController(uint256 agentId, address account) external view returns (bool) {
        // 1. Load the binding that defines who controls this agent.
        Binding memory binding = _bindings[agentId];

        // 2. Unknown agents do not have a controller.
        if (binding.tokenContract == address(0)) {
            return false;
        }

        // 3. Re-evaluate control against the current bound-token ownership state.
        return _hasBindingControl(binding, account);
    }

    function onERC721Received(address, address, uint256, bytes calldata) external pure returns (bytes4) {
        // 1. Return the standard receiver selector so safe ERC-721 transfers to the adapter succeed.
        return IERC721Receiver.onERC721Received.selector;
    }

    // -----------------------------------------------------------------
    // COUNTERFACTUAL FUNCTIONS
    // -----------------------------------------------------------------
    // Emit-only mirrors of the on-chain register surface. No SSTORE, no
    // ERC-8004 registry calls; gated only by current bound-token control.
    // Indexers consume the emitted events as soft-state claims (latest
    // event per `registrationHash` wins), enabling off-chain identities
    // that can later be promoted to on-chain registrations.
    // -----------------------------------------------------------------

    /// @notice Computes the canonical counterfactual `registrationHash` for the given external token,
    /// scoped to this chain and this adapter proxy. Mirrors the internal `_registrationHash`
    /// used by every counterfactual emitter. Useful for off-chain consumers that need to
    /// derive the hash without reimplementing the encoding rules.
    function registrationHash(TokenStandard standard, address tokenContract, uint256 tokenId)
        external
        view
        returns (bytes32)
    {
        return _registrationHash(standard, tokenContract, tokenId);
    }

    /// @inheritdoc IERC8004AdapterCounterfactual
    function counterfactualPayloadVersion() external pure returns (uint8) {
        return COUNTERFACTUAL_PAYLOAD_VERSION;
    }

    /// @notice Counterfactual registration: claim an identity for an external token without minting in the
    /// ERC-8004 registry and without persisting any adapter storage. The single source of truth is the
    /// emitted `CounterfactualAgentRegistered` event. The same controller may re-emit any number of times;
    /// indexers MUST resolve the latest event per `(tokenContract, tokenId)` as authoritative.
    function counterfactualRegister(
        TokenStandard standard,
        address tokenContract,
        uint256 tokenId,
        string calldata agentURI,
        IERC8004IdentityRegistry.MetadataEntry[] memory metadata
    ) public nonReentrant returns (bytes32 computedHash) {
        return _counterfactualRegisterImpl(standard, tokenContract, tokenId, agentURI, metadata);
    }

    /// @notice Convenience overload equivalent to `counterfactualRegister(...)` with an empty metadata array.
    function counterfactualRegister(
        TokenStandard standard,
        address tokenContract,
        uint256 tokenId,
        string calldata agentURI
    ) external nonReentrant returns (bytes32 computedHash) {
        return _counterfactualRegisterImpl(
            standard, tokenContract, tokenId, agentURI, new IERC8004IdentityRegistry.MetadataEntry[](0)
        );
    }

    function _counterfactualRegisterImpl(
        TokenStandard standard,
        address tokenContract,
        uint256 tokenId,
        string calldata agentURI,
        IERC8004IdentityRegistry.MetadataEntry[] memory metadata
    ) private returns (bytes32 computedHash) {
        // 1. Reject an unusable external token contract address and reject the registry itself so the
        //    revert taxonomy matches `register`.
        _requireValidTokenContract(tokenContract);

        // 2. Confirm the caller currently controls the token being claimed.
        _requireBindingControl(standard, tokenContract, tokenId, msg.sender);

        // 3. Reject user-supplied metadata entries that target reserved counterfactual records.
        _requireNoReservedCounterfactualKeys(metadata);

        // 4. Compute the deterministic registration hash used as the indexer key for this claim.
        computedHash = _registrationHash(standard, tokenContract, tokenId);

        // 5. Emit the counterfactual claim — the only on-chain record produced by this function.
        emit CounterfactualAgentRegistered(
            computedHash,
            tokenContract,
            tokenId,
            COUNTERFACTUAL_PAYLOAD_VERSION,
            standard,
            agentURI,
            metadata,
            msg.sender
        );
    }

    /// @notice Counterfactual agent URI update. No registry write, no SSTORE. The emitted event is the
    /// single source of truth; indexers MUST treat the latest event per token as authoritative.
    function counterfactualSetAgentURI(
        TokenStandard standard,
        address tokenContract,
        uint256 tokenId,
        string calldata newURI
    ) external nonReentrant {
        // 1. Reject an unusable external token contract address and reject the registry itself so the
        //    revert taxonomy matches `register`.
        _requireValidTokenContract(tokenContract);

        // 2. Confirm the caller currently controls the bound token.
        _requireBindingControl(standard, tokenContract, tokenId, msg.sender);

        // 3. Emit the counterfactual URI update — the only on-chain record produced by this function.
        emit CounterfactualAgentURISet(
            _registrationHash(standard, tokenContract, tokenId),
            tokenContract,
            tokenId,
            COUNTERFACTUAL_PAYLOAD_VERSION,
            newURI,
            msg.sender
        );
    }

    /// @notice Counterfactual single-key metadata write. No registry write, no SSTORE.
    function counterfactualSetMetadata(
        TokenStandard standard,
        address tokenContract,
        uint256 tokenId,
        string calldata metadataKey,
        bytes calldata metadataValue
    ) external nonReentrant {
        // 1. Reject an unusable external token contract address and reject the registry itself so the
        //    revert taxonomy matches `register`.
        _requireValidTokenContract(tokenContract);

        // 2. Confirm the caller currently controls the bound token.
        _requireBindingControl(standard, tokenContract, tokenId, msg.sender);

        // 3. Prevent callers from claiming reserved metadata slots in counterfactual events.
        //    Cache the key hash once: `metadataKey` is `calldata` but recomputing the hash twice in
        //    a hot path still spends a few hundred gas for no benefit.
        bytes32 keyHash = keccak256(bytes(metadataKey));
        if (keyHash == BINDING_METADATA_KEY_HASH || keyHash == CF_REGISTRATION_KEY_HASH) {
            revert ReservedMetadataKey(metadataKey);
        }

        // 4. Emit the counterfactual metadata write — the only on-chain record produced by this function.
        emit CounterfactualMetadataSet(
            _registrationHash(standard, tokenContract, tokenId),
            tokenContract,
            tokenId,
            COUNTERFACTUAL_PAYLOAD_VERSION,
            metadataKey,
            metadataValue,
            msg.sender
        );
    }

    /// @notice Counterfactual batch metadata write. No registry write, no SSTORE.
    function counterfactualSetMetadataBatch(
        TokenStandard standard,
        address tokenContract,
        uint256 tokenId,
        IERC8004IdentityRegistry.MetadataEntry[] calldata metadata
    ) external nonReentrant {
        // 1. Reject an unusable external token contract address and reject the registry itself so the
        //    revert taxonomy matches `register`.
        _requireValidTokenContract(tokenContract);

        // 2. Confirm the caller currently controls the bound token.
        _requireBindingControl(standard, tokenContract, tokenId, msg.sender);

        // 3. Prevent callers from claiming reserved metadata slots in counterfactual events.
        _requireNoReservedCounterfactualKeys(metadata);

        // 4. Emit the counterfactual batch — the only on-chain record produced by this function.
        emit CounterfactualMetadataBatchSet(
            _registrationHash(standard, tokenContract, tokenId),
            tokenContract,
            tokenId,
            COUNTERFACTUAL_PAYLOAD_VERSION,
            metadata,
            msg.sender
        );
    }

    /// @notice Counterfactual agent-wallet assignment. Deliberately accepts no signature / deadline because
    /// no ERC-8004 wallet binding is being created — the event is purely an off-chain claim, gated only by
    /// current bound-token control.
    function counterfactualSetAgentWallet(
        TokenStandard standard,
        address tokenContract,
        uint256 tokenId,
        address newWallet
    ) external nonReentrant {
        // 1. Reject an unusable external token contract address and reject the registry itself so the
        //    revert taxonomy matches `register`.
        _requireValidTokenContract(tokenContract);

        // 2. Confirm the caller currently controls the bound token.
        _requireBindingControl(standard, tokenContract, tokenId, msg.sender);

        // 3. Emit the counterfactual wallet assignment — the only on-chain record produced by this function.
        emit CounterfactualAgentWalletSet(
            _registrationHash(standard, tokenContract, tokenId),
            tokenContract,
            tokenId,
            COUNTERFACTUAL_PAYLOAD_VERSION,
            newWallet,
            msg.sender
        );
    }

    /// @notice Counterfactual agent-wallet clear. No registry write, no SSTORE.
    function counterfactualUnsetAgentWallet(TokenStandard standard, address tokenContract, uint256 tokenId)
        external
        nonReentrant
    {
        // 1. Reject an unusable external token contract address and reject the registry itself so the
        //    revert taxonomy matches `register`.
        _requireValidTokenContract(tokenContract);

        // 2. Confirm the caller currently controls the bound token.
        _requireBindingControl(standard, tokenContract, tokenId, msg.sender);

        // 3. Emit the counterfactual wallet clear — the only on-chain record produced by this function.
        emit CounterfactualAgentWalletUnset(
            _registrationHash(standard, tokenContract, tokenId),
            tokenContract,
            tokenId,
            COUNTERFACTUAL_PAYLOAD_VERSION,
            msg.sender
        );
    }

    function _authorizeUpgrade(address newImplementation) internal view override onlyOwner {
        // 1. Restrict upgrades to the adapter owner.
        // 2. Accept the implementation address through UUPS validation in the inherited logic.
        newImplementation;
    }

    /// @dev Reject `address(0)` and the ERC-8004 identity registry itself as `tokenContract`. Binding
    /// the registry would let `_hasBindingControl` resolve to the adapter post-bind, permanently
    /// locking the agent away from any external controller.
    function _requireValidTokenContract(address tokenContract) internal view {
        if (tokenContract == address(0)) {
            revert InvalidTokenContract();
        }
        if (tokenContract == address(identityRegistry)) {
            revert InvalidTokenContractIsRegistry();
        }
    }

    function _requireController(uint256 agentId, address account) internal view {
        // 1. Load the binding for the requested agent.
        Binding memory binding = _bindings[agentId];

        // 2. Reject unknown agents before checking token ownership state.
        if (binding.tokenContract == address(0)) {
            revert UnknownAgent(agentId);
        }

        // 3. Revert when the caller no longer controls the bound token.
        if (!_hasBindingControl(binding, account)) {
            revert NotController(account, agentId);
        }
    }

    /// @dev Reverts unless the adapter is approved to move `agentId` on the ERC-8004 registry,
    /// either by per-token `approve(adapter, agentId)` or operator-level `setApprovalForAll(adapter, true)`
    /// from `owner`. Casts the registry to `IERC721` locally to avoid widening the ERC-8004 metadata
    /// interface.
    function _requireAgentTransferApproval(uint256 agentId, address owner) internal view {
        IERC721 registry721 = IERC721(address(identityRegistry));
        if (registry721.getApproved(agentId) != address(this) && !registry721.isApprovedForAll(owner, address(this))) {
            revert AgentTransferNotApproved(agentId);
        }
    }

    function _requireBindingControl(TokenStandard standard, address tokenContract, uint256 tokenId, address account)
        internal
        view
    {
        // 1. Reuse the token-standard-specific control check before first registration.
        if (!_hasBindingControl(standard, tokenContract, tokenId, account)) {
            revert NotController(account, type(uint256).max);
        }
    }

    function _hasBindingControl(Binding memory binding, address account) internal view returns (bool) {
        return _hasBindingControl(binding.standard, binding.tokenContract, binding.tokenId, account);
    }

    function _hasBindingControl(TokenStandard standard, address tokenContract, uint256 tokenId, address account)
        internal
        view
        returns (bool)
    {
        // 1. ERC-721 control means current NFT ownership, or a valid delegate.xyz delegation from the
        //    current owner. Direct ownership is checked first so current owners never pay a registry call.
        if (standard == TokenStandard.ERC721) {
            address owner = IERC721(tokenContract).ownerOf(tokenId);
            if (account == owner) {
                return true;
            }
            return _isERC721Delegate(account, owner, tokenContract, tokenId);
        }

        // 2. ERC-1155 control means any positive balance for the bound id.
        //    No delegate.xyz check: the no-vault API cannot soundly map a delegation to a holder.
        if (standard == TokenStandard.ERC1155) {
            return IERC1155(tokenContract).balanceOf(account, tokenId) > 0;
        }

        // 3. ERC-6909 control also means any positive balance for the bound id.
        //    No delegate.xyz check: v2 has no ERC-6909 token-id delegation primitive.
        return IERC6909(tokenContract).balanceOf(account, tokenId) > 0;
    }

    /// @dev Consults the immutable delegate.xyz v2 registry for an ERC-721 delegation from the current
    /// `owner` (the vault) to `account` (the hot wallet). `checkDelegateForERC721` already folds in
    /// token-level, contract-level, and all-wallet delegations, so no separate calls are needed.
    /// Fails closed: if the registry has no code on this chain, only direct ownership authorizes.
    function _isERC721Delegate(address account, address owner, address tokenContract, uint256 tokenId)
        internal
        view
        returns (bool)
    {
        // 1. Fail closed to direct ownership when the canonical registry is absent on this chain.
        if (DELEGATE_REGISTRY.code.length == 0) {
            return false;
        }

        // 2. Accept either a `DELEGATE_RIGHTS`-scoped delegation or an empty/full delegation.
        return IDelegateRegistry(DELEGATE_REGISTRY).checkDelegateForERC721(
            account, owner, tokenContract, tokenId, DELEGATE_RIGHTS
        );
    }

    /// @dev NAME HAZARD: `_requireNotReservedBindingKey` (this one) vs `_requireNoReservedBindingKey`
    /// (below) differ only by "Not"/"No". This singular variant guards ONE key; the plural variant
    /// guards an array. Picking the wrong one still compiles — confirm the argument type when calling.
    function _requireNotReservedBindingKey(string calldata metadataKey) internal pure {
        // 1. Reject writes that target the canonical binding metadata slot.
        if (keccak256(bytes(metadataKey)) == BINDING_METADATA_KEY_HASH) {
            revert ReservedMetadataKey(metadataKey);
        }
    }

    /// @dev NAME HAZARD: `_requireNoReservedBindingKey` (this one) vs `_requireNotReservedBindingKey`
    /// (above) differ only by "No"/"Not". This plural variant guards an ARRAY; the singular variant
    /// guards one key. Picking the wrong one still compiles — confirm the argument type when calling.
    function _requireNoReservedBindingKey(IERC8004IdentityRegistry.MetadataEntry[] memory metadata) internal pure {
        // 1. Scan user-supplied metadata and reject any entry that targets the canonical binding metadata slot.
        uint256 length = metadata.length;
        for (uint256 i; i < length; ++i) {
            if (keccak256(bytes(metadata[i].metadataKey)) == BINDING_METADATA_KEY_HASH) {
                revert ReservedMetadataKey(metadata[i].metadataKey);
            }
        }
    }

    /// @dev Plural counterfactual-write variant: rejects any entry that targets either the canonical
    /// binding metadata key (`agent-binding`) OR the canonical-promotion key (`cf-registration`). The
    /// promotion key is reserved only on the counterfactual surface so an emitter cannot fabricate a
    /// promotion back-link before any canonical ERC-8004 mint has occurred.
    function _requireNoReservedCounterfactualKeys(IERC8004IdentityRegistry.MetadataEntry[] memory metadata)
        internal
        pure
    {
        uint256 length = metadata.length;
        for (uint256 i; i < length; ++i) {
            bytes32 keyHash = keccak256(bytes(metadata[i].metadataKey));
            if (keyHash == BINDING_METADATA_KEY_HASH || keyHash == CF_REGISTRATION_KEY_HASH) {
                revert ReservedMetadataKey(metadata[i].metadataKey);
            }
        }
    }

    function _registrationHash(TokenStandard standard, address tokenContract, uint256 tokenId)
        internal
        view
        returns (bytes32)
    {
        // 1. Bind the hash to the current chain, proxy address, declared standard, and external token
        //    coordinates so counterfactual claims cannot be replayed across chains, adapters, standards,
        //    or token identities.
        return keccak256(abi.encode(block.chainid, address(this), standard, tokenContract, tokenId));
    }
}
