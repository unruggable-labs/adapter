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
import {MessageHashUtils} from "@openzeppelin/contracts/utils/cryptography/MessageHashUtils.sol";
import {SignatureChecker} from "@openzeppelin/contracts/utils/cryptography/SignatureChecker.sol";
import {IDelegateRegistry} from "./interfaces/IDelegateRegistry.sol";
import {IERCAgentBindings} from "./interfaces/IERCAgentBindings.sol";
import {IERC8004AdapterCounterfactual} from "./interfaces/IERC8004AdapterCounterfactual.sol";
import {IERC8004AdapterCounterfactualPrimaryAgent} from "./interfaces/IERC8004AdapterCounterfactualPrimaryAgent.sol";
import {IERC8004AdapterPrimaryAgent} from "./interfaces/IERC8004AdapterPrimaryAgent.sol";
import {IERC8004AdapterRegistration} from "./interfaces/IERC8004AdapterRegistration.sol";
import {IERC8004IdentityRecord} from "./interfaces/IERC8004IdentityRecord.sol";
import {IERC8004IdentityRegistry} from "./interfaces/IERC8004IdentityRegistry.sol";

interface ISingleOwnerToken {
    function ownerOf(uint256 tokenId) external view returns (address);
}

interface IOwnableContract {
    function owner() external view returns (address);
}

/// @notice Upgrade target for the active Adapter8004 proxies.
/// @dev The production upgrade baseline is the implementation currently selected by each proxy,
/// not the unreleased 0.0.9-0.0.13 source history. The active Mainnet/Base and Sepolia
/// implementations both use regular slots 0 (`identityRegistry`) and 1 (`_bindings`) only.
/// v0.0.14 appends its three primary-agent mappings directly at slots 2-4. A direct production
/// upgrade requires no migration or reinitializer and must use empty `upgradeToAndCall` data.
/// Sepolia's live delegate.xyz constants and authorization behavior are retained by this
/// implementation.
///
/// v0.0.15 folds a `bytes32 extraData` discriminator into the counterfactual registration hash and
/// emits it on every counterfactual event. It is declared as a `constant`, so the storage layout is
/// unchanged.
///
/// This is a breaking change. Every `registrationHash` changes and every counterfactual topic0
/// moves, so it must be treated as a hard cutover. Document the cutover block, move the indexer to
/// the new ABI, and reindex before upgrading a proxy. Only counterfactual identities and the
/// `_primaryCounterfactualAgent` pointers are keyed by this hash, so `Binding` rows and full
/// ERC-8004 registrations are unaffected. It is also the only such break, because everything that
/// hashes with `extraData == bytes32(0)` will hash identically from here on.
/// @custom:version 0.0.15
contract Adapter8004 is
    Initializable,
    OwnableUpgradeable,
    UUPSUpgradeable,
    ReentrancyGuard,
    IERC721Receiver,
    IERCAgentBindings,
    IERC8004IdentityRecord,
    IERC8004AdapterRegistration,
    IERC8004AdapterCounterfactual,
    IERC8004AdapterPrimaryAgent,
    IERC8004AdapterCounterfactualPrimaryAgent
{
    string public constant BINDING_METADATA_KEY = "agent-binding";
    bytes32 private constant BINDING_METADATA_KEY_HASH = keccak256(bytes(BINDING_METADATA_KEY));

    /// @notice Reserved canonical-promotion metadata key. A write that targets this key would let a
    /// caller fabricate a promotion back-link, so it has no legitimate caller-supplied writer. The
    /// reservation is enforced on every write path that accepts caller metadata: all counterfactual
    /// writes, and the canonical setters `register`, `setMetadata`, and `setMetadataBatch`.
    string public constant CF_REGISTRATION_KEY = "cf-registration";
    bytes32 private constant CF_REGISTRATION_KEY_HASH = keccak256(bytes(CF_REGISTRATION_KEY));

    /// @notice Canonical immutable delegate.xyz v2 registry, identical on Ethereum, Base, and Sepolia.
    /// A delegated hot wallet authorized here can drive single-owner ERC-721/ERC-1155F/ERC-6909F
    /// bound agents while the token stays in cold storage. Authorization fails closed to direct
    /// ownership when the registry has no code.
    address public constant DELEGATE_REGISTRY = 0x00000000000000447e69651d841bD8D104Bed493;

    /// @notice Rights identifier a cold wallet delegates to scope a hot wallet to Adapter8004 management
    /// only. delegate.xyz v2 also accepts empty/full delegations when this nonzero rights value is checked.
    bytes32 public constant DELEGATE_RIGHTS = keccak256("adapter8004.manage");

    /// @notice Identity discriminator folded into every counterfactual `registrationHash` and
    /// emitted on every counterfactual event. It is reserved rather than used, and is zero in this
    /// implementation.
    ///
    /// It exists so that a later implementation can separate tokens that share a
    /// `(tokenContract, tokenId)`, such as a contract with classes of ids where Class A id 1 and
    /// Class B id 1 are different tokens. The proxy is UUPS, so that implementation may compute
    /// this value however it needs to. Fixing the preimage shape here is what allows it to do so
    /// without breaking any identity again.
    ///
    /// @dev Never introduce a non-zero value for a pair that hashed with zero, as it re-keys a live identity.
    bytes32 private constant COUNTERFACTUAL_EXTRA_DATA = bytes32(0);

    /// @notice Stateless EIP-712 domain for the signed primary-agent surface. The domain name
    /// identifies the adapter (not the underlying ERC-8004 registry); the separator is computed
    /// inline from `block.chainid` and `address(this)` so no storage slot or cached separator is
    /// introduced and the contract stays storage-layout neutral across upgrades.
    bytes32 private constant EIP712_DOMAIN_TYPEHASH =
        keccak256("EIP712Domain(string name,string version,uint256 chainId,address verifyingContract)");
    string private constant EIP712_NAME = "Adapter8004";
    string private constant EIP712_VERSION = "1";

    /// @notice Upper bound on how far in the future a signed primary-agent `deadline` may sit. A
    /// short lifetime bounds replay exposure for relayer-submitted reverse-pointer updates.
    uint256 private constant MAX_PRIMARY_AGENT_SIGNATURE_LIFETIME = 30 minutes;

    /// @notice EIP-712 typehashes for the gasless (account-self) full-system primary-agent surface.
    /// The signed payloads embed the operation's on-chain nonce and a bounded `deadline`;
    /// the `nonce` is deliberately not a calldata argument.
    bytes32 private constant SET_PRIMARY_AGENT_TYPEHASH =
        keccak256("SetPrimary8004Agent(address account,uint256 agentId,uint256 nonce,uint256 deadline)");
    bytes32 private constant CLEAR_PRIMARY_AGENT_TYPEHASH =
        keccak256("ClearPrimary8004Agent(address account,uint256 nonce,uint256 deadline)");

    error InvalidTokenContract();
    /// @notice Thrown when a single-owner token's `ownerOf(tokenId)` call succeeds but does not
    /// return exactly one canonical ABI-encoded address word. Malformed success responses fail
    /// closed rather than opening the ownerless collection-authority window.
    error InvalidOwnerOfResponse(address tokenContract, uint256 tokenId);
    /// @notice Thrown when a binding attempts to set `tokenContract` to the ERC-8004 identity registry
    /// itself. Permitted-and-then-bound, the agent would be permanently uncontrollable because
    /// `ownerOf(tokenId)` on the registry resolves to the adapter post-bind, locking the only path
    /// through `_hasBindingControl`.
    error InvalidTokenContractIsRegistry();
    /// @notice Thrown by any `CONTRACT` or `CONTRACT_OWNABLE` adapter operation called with a nonzero `tokenId` —
    /// registration, `bindExisting`, and the emit-only counterfactual calls alike, since all of them
    /// pass through the same authority choke points. A contract-level binding names the contract
    /// itself rather than a token within it, so it has exactly one canonical coordinate, `tokenId ==
    /// 0`. The nonzero id is rejected rather than coerced so the caller's binding or emitted claim,
    /// its `registrationHash`, and any pointer derived from it can never disagree with the id the
    /// caller submitted.
    error NonZeroTokenIdForContract(address tokenContract, uint256 tokenId);
    error ReservedMetadataKey(string metadataKey);
    error NotController(address account, uint256 agentId);
    /// @notice Thrown when `setPrimaryAgentFor` / `clearPrimaryAgentFor` is called by an address that
    /// is neither the account itself, the account's `owner()` / `getOwner()`, nor a holder of its
    /// `DEFAULT_ADMIN_ROLE`.
    error NotAccountController(address account, address caller);
    /// @notice Thrown when a primary-agent setter is passed `PRIMARY_AGENT_UNSET` (all ones). That
    /// value is reserved as the "unset" sentinel: it complements to zero in storage and would be
    /// indistinguishable from a never-written entry. Clear via `clearPrimaryAgent[For]` instead.
    error PrimaryAgentIdReserved(uint256 agentId);
    error PrimaryCounterfactualAgentHashReserved(bytes32 registrationHash);
    error InvalidChainId();
    error UnknownAgent(uint256 agentId);
    /// @notice Thrown when an agent that already carries a binding is offered for binding again.
    /// Bindings are immutable and there is deliberately no revoke or unbind API: to move on, register
    /// a fresh ERC-8004 identity. One external token may back any number of agents.
    error AlreadyBound(uint256 agentId);
    error NotAgentOwner(uint256 agentId, address owner);
    error AgentTransferNotApproved(uint256 agentId);

    /// @notice Thrown when the current block timestamp is past a signed primary-agent `deadline`.
    error SignatureExpired(uint256 deadline);
    /// @notice Thrown when a signed primary-agent `deadline` is more than
    /// `MAX_PRIMARY_AGENT_SIGNATURE_LIFETIME` seconds in the future.
    error SignatureDeadlineTooFar(uint256 deadline);
    /// @notice Thrown when an account signature fails EOA and ERC-1271 verification for the digest.
    /// This covers a wrong signer, tampered payload, stale nonce, or wrong operation type.
    error InvalidSignature();

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

    /// @notice Full-system unset sentinel. Agent id zero remains representable.
    uint256 public constant PRIMARY_AGENT_UNSET = type(uint256).max;
    bytes32 public constant PRIMARY_COUNTERFACTUAL_AGENT_UNSET = bytes32(type(uint256).max);

    /// @dev Active v0.0.14 reverse claims and full-system nonces. These three mappings are
    /// append-only regular slots 2 through 4 and begin empty after a direct upgrade from either active deployed
    /// implementation. Unreleased 0.0.9-0.0.13 layouts are not production compatibility
    /// baselines and therefore consume no reserved slots.
    mapping(address account => uint256 complementAgentId) private _primaryAgent;
    mapping(address account => bytes32 complementRegistrationHash) private _primaryCounterfactualAgent;
    mapping(address account => uint256 nonce) private _primaryAgentNonces;

    /// @custom:oz-upgrades-unsafe-allow constructor
    constructor() {
        _disableInitializers();
    }

    /// @notice Initializes a newly deployed proxy.
    /// @dev Do not call during an upgrade of an existing proxy. Active proxies already have slots
    /// 0 and 1 initialized; v0.0.14 adds only empty mappings and has no reinitializer.
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
        return _register(standard, tokenContract, tokenId, agentURI, metadata);
    }

    function register(TokenStandard standard, address tokenContract, uint256 tokenId, string calldata agentURI)
        external
        nonReentrant
        returns (uint256 agentId)
    {
        return _register(standard, tokenContract, tokenId, agentURI, new IERC8004IdentityRegistry.MetadataEntry[](0));
    }

    /// @notice Caller-paid convenience wrapper: register a new adapter-managed ERC-8004 agent bound to
    /// the caller's external token, then record that new `agentId` as the caller's own primary agent —
    /// in one transaction, with no signature or relayer. Equivalent to `register(...)` (no-metadata
    /// overload) immediately followed by the caller calling `setPrimaryAgent(agentId)`
    /// themselves: identical control/auth (the caller must control the token), identical `AgentBound`
    /// event and returned `agentId`, plus the standard `PrimaryAgentSet(caller, agentId,
    /// caller)`. No new storage, authorization, or event families. Caller-scoped everywhere: a
    /// `CONTRACT` binding records the primary for the bound contract; a `CONTRACT_OWNABLE` binding
    /// records it for whichever authorized account made this call.
    function registerAndSetPrimary(
        TokenStandard standard,
        address tokenContract,
        uint256 tokenId,
        string calldata agentURI
    ) external nonReentrant returns (uint256 agentId) {
        // 1. Run the canonical register body (shared with `register`); reverts identically when the
        //    caller does not control the token.
        agentId = _register(standard, tokenContract, tokenId, agentURI, new IERC8004IdentityRegistry.MetadataEntry[](0));

        // 2. Record the freshly minted agent as the caller's own primary agent through the shared
        //    helper (keeps the all-ones `PrimaryAgentIdReserved` guard; a fresh incremental id is small).
        _setPrimaryAgent(msg.sender, agentId);
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

        // 4. Require external binding control under the existing authority model: single-owner
        //    standards use ownerOf plus delegate.xyz, plain ERC-1155/ERC-6909 use balance, `CONTRACT`
        //    requires the bound contract itself, and `CONTRACT_OWNABLE` also accepts its current owner.
        //    The authorized caller must also own the agent (step 3) and approve the adapter (step 5).
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

    function _register(
        TokenStandard standard,
        address tokenContract,
        uint256 tokenId,
        string calldata agentURI,
        IERC8004IdentityRegistry.MetadataEntry[] memory metadata
    ) private returns (uint256 agentId) {
        // 1. Reject an unusable external token contract address, and reject the registry itself
        //    (binding to the registry would lock the agent permanently post-register).
        _requireValidTokenContract(tokenContract);

        // 2. Confirm the caller currently controls the token being bound, or is the directly
        //    calling single-owner collection while the id has no current owner.
        _requireTokenAuthority(standard, tokenContract, tokenId, msg.sender);

        // 3. Reject user-supplied metadata entries that target reserved keys: the canonical
        //    binding record (agent-binding) and cf-registration, which no register path writes.
        _requireNoReservedCounterfactualKeys(metadata);

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

        // 2. Prevent callers from writing reserved metadata: the canonical binding record
        //    (agent-binding) and the canonical-promotion key (cf-registration). No adapter
        //    code path writes either legitimately, so neither is a valid controller write.
        bytes32 keyHash = keccak256(bytes(metadataKey));
        if (keyHash == BINDING_METADATA_KEY_HASH || keyHash == CF_REGISTRATION_KEY_HASH) {
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

        // 2. Prevent callers from writing reserved metadata (agent-binding and cf-registration).
        _requireNoReservedCounterfactualKeys(metadata);

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
    // ERC-8004 registry calls; gated by current bound-token control, the temporary
    // direct ownerless-collection authority documented below, or a contract binding's
    // value-5 contract-self / value-6 contract-self-or-current-owner authority at `tokenId 0`.
    // There is no whole-claim tombstone: a claim can only be superseded by a later
    // event, and unsetting the wallet clears that field alone.
    // Indexers consume the emitted events as soft-state claims (latest
    // event per `registrationHash` wins), enabling off-chain identities
    // that can later be promoted to on-chain registrations.
    //
    // The identity is the `registrationHash` and nothing else. Each token
    // has exactly one identity, but `(tokenContract, tokenId)` is not
    // considered a unique identifier, because one contract may have more
    // than one set of ids. `extraData` is what separates those tokens.
    // Consumers must key on `registrationHash`, never on the token pair.
    // -----------------------------------------------------------------

    /// @notice Computes the canonical counterfactual `registrationHash` for the given external token,
    /// scoped to this chain and this adapter proxy. Mirrors the internal `_registrationHash`
    /// used by every counterfactual emitter. Useful for off-chain consumers that need to
    /// derive the hash without reimplementing the encoding rules.
    function registrationHash(address tokenContract, uint256 tokenId) external view returns (bytes32) {
        return _registrationHash(tokenContract, tokenId);
    }

    /// @inheritdoc IERC8004AdapterCounterfactual
    function interoperableAddress(address account) external view returns (bytes memory) {
        return _interoperableAddress(account);
    }

    /// @inheritdoc IERC8004AdapterCounterfactual
    function chainIdentifier() external view returns (bytes memory) {
        return _chainIdentifier();
    }

    /// @notice Counterfactual registration: claim an identity for an external token without minting in the
    /// ERC-8004 registry and without persisting any adapter storage. Authorized for a current controller,
    /// or for the directly calling token contract while an ERC-721/ERC-1155F/ERC-6909F id has no current
    /// owner. The same authority may re-emit any number of times; indexers MUST resolve the latest event
    /// per `registrationHash` as authoritative, not per `(tokenContract, tokenId)`, which is not
    /// considered a unique identifier. Collection-authorized events use `emitter = tokenContract`.
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

        // 2. Confirm the caller is a current controller, or the directly calling single-owner token
        //    contract while `tokenId` has no current owner.
        _requireTokenAuthority(standard, tokenContract, tokenId, msg.sender);

        // 3. Reject user-supplied metadata entries that target reserved counterfactual records.
        _requireNoReservedCounterfactualKeys(metadata);

        // 4. Compute the deterministic registration hash used as the indexer key for this claim.
        computedHash = _registrationHash(tokenContract, tokenId);

        // 5. Emit the counterfactual claim — the only on-chain record produced by this function.
        emit CounterfactualAgentRegistered(
            computedHash, tokenContract, tokenId, COUNTERFACTUAL_EXTRA_DATA, standard, agentURI, metadata, msg.sender
        );
    }

    /// @notice Counterfactual agent URI update. No registry write, no SSTORE. A current controller
    /// may call, as may the directly calling token contract while a supported single-owner id has no
    /// current owner. The emitted event is the single source of truth; indexers MUST treat the latest
    /// event per `registrationHash` as authoritative, not per `(tokenContract, tokenId)`, which is
    /// not considered a unique identifier.
    function counterfactualSetAgentURI(
        TokenStandard standard,
        address tokenContract,
        uint256 tokenId,
        string calldata newURI
    ) external nonReentrant {
        // 1. Reject an unusable external token contract address and reject the registry itself so the
        //    revert taxonomy matches `register`.
        _requireValidTokenContract(tokenContract);

        // 2. Apply current-controller or ownerless collection authority.
        _requireTokenAuthority(standard, tokenContract, tokenId, msg.sender);

        // 3. Emit the counterfactual URI update — the only on-chain record produced by this function.
        emit CounterfactualAgentURISet(
            _registrationHash(tokenContract, tokenId),
            tokenContract,
            tokenId,
            COUNTERFACTUAL_EXTRA_DATA,
            newURI,
            msg.sender
        );
    }

    /// @notice Counterfactual single-key metadata write. No registry write, no SSTORE. Accepts
    /// current-controller authority or direct ownerless collection authority for supported
    /// single-owner standards.
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

        // 2. Apply current-controller or ownerless collection authority.
        _requireTokenAuthority(standard, tokenContract, tokenId, msg.sender);

        // 3. Prevent callers from claiming reserved metadata slots in counterfactual events.
        //    Cache the key hash once: `metadataKey` is `calldata` but recomputing the hash twice in
        //    a hot path still spends a few hundred gas for no benefit.
        bytes32 keyHash = keccak256(bytes(metadataKey));
        if (keyHash == BINDING_METADATA_KEY_HASH || keyHash == CF_REGISTRATION_KEY_HASH) {
            revert ReservedMetadataKey(metadataKey);
        }

        // 4. Emit the counterfactual metadata write — the only on-chain record produced by this function.
        emit CounterfactualMetadataSet(
            _registrationHash(tokenContract, tokenId),
            tokenContract,
            tokenId,
            COUNTERFACTUAL_EXTRA_DATA,
            metadataKey,
            metadataValue,
            msg.sender
        );
    }

    /// @notice Counterfactual batch metadata write. No registry write, no SSTORE. Accepts
    /// current-controller authority or direct ownerless collection authority for supported
    /// single-owner standards.
    function counterfactualSetMetadataBatch(
        TokenStandard standard,
        address tokenContract,
        uint256 tokenId,
        IERC8004IdentityRegistry.MetadataEntry[] calldata metadata
    ) external nonReentrant {
        // 1. Reject an unusable external token contract address and reject the registry itself so the
        //    revert taxonomy matches `register`.
        _requireValidTokenContract(tokenContract);

        // 2. Apply current-controller or ownerless collection authority.
        _requireTokenAuthority(standard, tokenContract, tokenId, msg.sender);

        // 3. Prevent callers from claiming reserved metadata slots in counterfactual events.
        _requireNoReservedCounterfactualKeys(metadata);

        // 4. Emit the counterfactual batch — the only on-chain record produced by this function.
        emit CounterfactualMetadataBatchSet(
            _registrationHash(tokenContract, tokenId),
            tokenContract,
            tokenId,
            COUNTERFACTUAL_EXTRA_DATA,
            metadata,
            msg.sender
        );
    }

    /// @notice Counterfactual agent-wallet assignment. Deliberately accepts no signature because no
    /// ERC-8004 wallet binding is being created — the event is purely an off-chain claim, gated by
    /// current-controller authority or direct ownerless collection authority for supported
    /// single-owner standards.
    function counterfactualSetAgentWallet(
        TokenStandard standard,
        address tokenContract,
        uint256 tokenId,
        address newWallet
    ) external nonReentrant {
        // 1. Reject an unusable external token contract address and reject the registry itself so the
        //    revert taxonomy matches `register`.
        _requireValidTokenContract(tokenContract);

        // 2. Apply current-controller or ownerless collection authority.
        _requireTokenAuthority(standard, tokenContract, tokenId, msg.sender);

        // 3. Emit the counterfactual wallet assignment — the only on-chain record produced by this function.
        emit CounterfactualAgentWalletSet(
            _registrationHash(tokenContract, tokenId),
            tokenContract,
            tokenId,
            COUNTERFACTUAL_EXTRA_DATA,
            newWallet,
            msg.sender
        );
    }

    /// @notice Counterfactual agent-wallet clear. No registry write, no SSTORE. Accepts
    /// current-controller authority or direct ownerless collection authority for supported
    /// single-owner standards.
    function counterfactualUnsetAgentWallet(TokenStandard standard, address tokenContract, uint256 tokenId)
        external
        nonReentrant
    {
        // 1. Reject an unusable external token contract address and reject the registry itself so the
        //    revert taxonomy matches `register`.
        _requireValidTokenContract(tokenContract);

        // 2. Apply current-controller or ownerless collection authority.
        _requireTokenAuthority(standard, tokenContract, tokenId, msg.sender);

        // 3. Emit the counterfactual wallet clear — the only on-chain record produced by this function.
        emit CounterfactualAgentWalletUnset(
            _registrationHash(tokenContract, tokenId), tokenContract, tokenId, COUNTERFACTUAL_EXTRA_DATA, msg.sender
        );
    }

    // -----------------------------------------------------------------
    //  Full ERC-8004 primary agent (reverse resolution: address -> registry agent id)
    // -----------------------------------------------------------------

    /// @notice Set the caller's own primary agent id. The caller always controls itself, so no extra
    /// authorization is required. The id is strictly an ERC-8004 registry token id. To remove an id,
    /// call `clearPrimaryAgent`; passing
    /// `PRIMARY_AGENT_UNSET` (all ones) reverts `PrimaryAgentIdReserved` (it is the unset sentinel).
    function setPrimaryAgent(uint256 agentId) external {
        _setPrimaryAgent(msg.sender, agentId);
    }

    /// @notice Set the primary agent id for `account`. Authorized when the caller is the account
    /// itself, the account's `owner()` / `getOwner()`, or a holder of its `DEFAULT_ADMIN_ROLE`. To
    /// remove an id, call `clearPrimaryAgentFor`. Reverts `PrimaryAgentIdReserved` for the all-ones id.
    function setPrimaryAgentFor(address account, uint256 agentId) external {
        if (!_controlsAccount(account, msg.sender)) revert NotAccountController(account, msg.sender);
        _setPrimaryAgent(account, agentId);
    }

    /// @notice Clear the caller's own primary agent id. Afterwards `primaryAgentOf` returns
    /// `PRIMARY_AGENT_UNSET`. Idempotent: clearing an already-unset account still emits
    /// `PrimaryAgentCleared`.
    function clearPrimaryAgent() external {
        _clearPrimaryAgent(msg.sender);
    }

    /// @notice Clear the primary agent id for `account`, under the same authorization model as
    /// `setPrimaryAgentFor`. Reverts `NotAccountController` when the caller is not authorized.
    function clearPrimaryAgentFor(address account) external {
        if (!_controlsAccount(account, msg.sender)) revert NotAccountController(account, msg.sender);
        _clearPrimaryAgent(account);
    }

    /// @notice Reverse-resolve an address to its primary agent id. Returns `PRIMARY_AGENT_UNSET` (all
    /// ones) when the account has never set an id or has cleared it. Every real id — including agent
    /// id `0` — is returned as itself.
    function primaryAgentOf(address account) external view returns (uint256) {
        uint256 stored = _primaryAgent[account];
        return stored == 0 ? PRIMARY_AGENT_UNSET : ~stored;
    }

    function _setPrimaryAgent(address account, uint256 agentId) private {
        if (agentId == type(uint256).max) revert PrimaryAgentIdReserved(agentId);
        _primaryAgent[account] = ~agentId;
        emit PrimaryAgentSet(account, agentId, msg.sender);
    }

    /// @dev Reset the account's complement slot to zero — which reads back as `PRIMARY_AGENT_UNSET` —
    /// and emit `PrimaryAgentCleared`. `delete` restores the exact "unwritten == unset" invariant.
    function _clearPrimaryAgent(address account) private {
        delete _primaryAgent[account];
        emit PrimaryAgentCleared(account, msg.sender);
    }

    // -----------------------------------------------------------------
    //  Counterfactual primary agent (reverse resolution: address -> registration hash)
    // -----------------------------------------------------------------

    function setPrimaryCounterfactualAgent(address tokenContract, uint256 tokenId)
        external
        returns (bytes32 computedHash)
    {
        return _setPrimaryCounterfactualAgent(msg.sender, tokenContract, tokenId);
    }

    function setPrimaryCounterfactualAgentFor(address account, address tokenContract, uint256 tokenId)
        external
        returns (bytes32 computedHash)
    {
        if (!_controlsAccount(account, msg.sender)) revert NotAccountController(account, msg.sender);
        return _setPrimaryCounterfactualAgent(account, tokenContract, tokenId);
    }

    function clearPrimaryCounterfactualAgent() external {
        _clearPrimaryCounterfactualAgent(msg.sender);
    }

    function clearPrimaryCounterfactualAgentFor(address account) external {
        if (!_controlsAccount(account, msg.sender)) revert NotAccountController(account, msg.sender);
        _clearPrimaryCounterfactualAgent(account);
    }

    function primaryCounterfactualAgentOf(address account) external view returns (bytes32) {
        bytes32 stored = _primaryCounterfactualAgent[account];
        return stored == bytes32(0) ? PRIMARY_COUNTERFACTUAL_AGENT_UNSET : ~stored;
    }

    function _setPrimaryCounterfactualAgent(address account, address tokenContract, uint256 tokenId)
        private
        returns (bytes32 computedHash)
    {
        computedHash = _registrationHash(tokenContract, tokenId);
        if (computedHash == bytes32(type(uint256).max)) {
            revert PrimaryCounterfactualAgentHashReserved(computedHash);
        }
        _primaryCounterfactualAgent[account] = ~computedHash;
        emit PrimaryCounterfactualAgentSet(
            account, computedHash, tokenContract, tokenId, COUNTERFACTUAL_EXTRA_DATA, msg.sender
        );
    }

    function _clearPrimaryCounterfactualAgent(address account) private {
        delete _primaryCounterfactualAgent[account];
        emit PrimaryCounterfactualAgentCleared(account, msg.sender);
    }

    // -----------------------------------------------------------------
    //  Signed (gasless, account-self) primary agent surface
    // -----------------------------------------------------------------

    /// @notice Set `account`'s primary agent id from an EIP-712 signature by `account` itself, so any
    /// relayer can submit it (gasless UX). Strictly account-self: the signature is validated against
    /// `account` via `SignatureChecker` (EOA or the account's ERC-1271 policy); there is deliberately
    /// no owner/admin/controller signature route here (that authority stays on the paid
    /// `setPrimaryAgentFor`). The `nonce` is not a calldata argument — the signed payload embeds the
    /// current `primaryAgentNonces(account)`, read on-chain immediately before verification. Reverts
    /// `SignatureDeadlineTooFar` / `SignatureExpired` on deadline bounds and `InvalidSignature` on a bad
    /// or stale signature; `agentId == PRIMARY_AGENT_UNSET` reverts `PrimaryAgentIdReserved` and `0` is a
    /// valid id. Emits the legacy `PrimaryAgentSet(account, agentId, msg.sender=relayer)` then
    /// `PrimaryAgentSetWithSig(account, agentId, relayer, nonce)`.
    function setPrimaryAgentWithSig(address account, uint256 agentId, uint256 deadline, bytes calldata signature)
        external
    {
        // 1. Enforce the bounded, unexpired deadline.
        _requirePrimaryAgentDeadline(deadline);

        // 2. Load the canonical current nonce and build the operation-specific digest over it.
        uint256 nonce = _primaryAgentNonces[account];
        bytes32 structHash = keccak256(abi.encode(SET_PRIMARY_AGENT_TYPEHASH, account, agentId, nonce, deadline));

        // 3. Require a valid account signature (EOA or ERC-1271) over that exact digest.
        _verifyPrimaryAgentSig(account, structHash, signature);

        // 4. Consume the nonce exactly once (before the pointer write; any later revert rolls it back).
        _primaryAgentNonces[account] = nonce + 1;

        // 5. Perform the shared storage op (keeps the all-ones rejection and agent-id-zero rules).
        _setPrimaryAgent(account, agentId);

        // 6. Emit the signed-path audit event with the nonce consumed in step 2.
        emit PrimaryAgentSetWithSig(account, agentId, msg.sender, nonce);
    }

    /// @notice Clear `account`'s primary agent id from an EIP-712 signature by `account` itself. Same
    /// account-self authorization, full-system nonce stream, and deadline bounds as `setPrimaryAgentWithSig`,
    /// so a signed clear supersedes an earlier signed set (and vice versa). Afterwards `primaryAgentOf`
    /// returns `PRIMARY_AGENT_UNSET`. Emits the legacy `PrimaryAgentCleared(account, relayer)` then
    /// `PrimaryAgentClearedWithSig(account, relayer, nonce)`.
    function clearPrimaryAgentWithSig(address account, uint256 deadline, bytes calldata signature) external {
        // 1. Enforce the bounded, unexpired deadline.
        _requirePrimaryAgentDeadline(deadline);

        // 2. Load the canonical current nonce and build the clear digest over it.
        uint256 nonce = _primaryAgentNonces[account];
        bytes32 structHash = keccak256(abi.encode(CLEAR_PRIMARY_AGENT_TYPEHASH, account, nonce, deadline));

        // 3. Require a valid account signature (EOA or ERC-1271) over that exact digest.
        _verifyPrimaryAgentSig(account, structHash, signature);

        // 4. Consume the nonce exactly once.
        _primaryAgentNonces[account] = nonce + 1;

        // 5. Clear the pointer through the shared helper.
        _clearPrimaryAgent(account);

        // 6. Emit the signed-path audit event with the nonce consumed in step 2.
        emit PrimaryAgentClearedWithSig(account, msg.sender, nonce);
    }

    function primaryAgentNonces(address account) external view returns (uint256) {
        return _primaryAgentNonces[account];
    }

    /// @dev Reject a signed primary-agent `deadline` that is beyond the lifetime cap or already past.
    /// A deadline equal to `block.timestamp` is still valid for that block, matching the counterfactual
    /// convention.
    function _requirePrimaryAgentDeadline(uint256 deadline) private view {
        if (deadline > block.timestamp + MAX_PRIMARY_AGENT_SIGNATURE_LIFETIME) revert SignatureDeadlineTooFar(deadline);
        if (block.timestamp > deadline) revert SignatureExpired(deadline);
    }

    /// @dev Verify `account`'s EIP-712 signature (EOA or ERC-1271) over `structHash` bound to the live
    /// domain separator. Reverts `InvalidSignature` on failure. Strictly validates against `account`.
    function _verifyPrimaryAgentSig(address account, bytes32 structHash, bytes calldata signature) private view {
        if (
            !SignatureChecker.isValidSignatureNow(
                account, MessageHashUtils.toTypedDataHash(_domainSeparator(), structHash), signature
            )
        ) {
            revert InvalidSignature();
        }
    }

    /// @dev True when `caller` controls `account`: the account itself, its `owner()` / `getOwner()`,
    /// or a `DEFAULT_ADMIN_ROLE` (`0x00`) holder. Contract checks are best-effort static calls that
    /// tolerate accounts (including EOAs) that do not implement them; the low-level path avoids
    /// reverting on non-conforming return data. A contract that misreports its controller can only
    /// affect its own mapping entry, so the checks are account-scoped and safe.
    function _controlsAccount(address account, address caller) private view returns (bool) {
        if (caller == account) return true;

        // Ownable: owner(), then getOwner() as a fallback.
        if (_staticReturnsAddress(account, abi.encodeWithSignature("owner()"), caller)) return true;
        if (_staticReturnsAddress(account, abi.encodeWithSignature("getOwner()"), caller)) return true;

        // AccessControl: DEFAULT_ADMIN_ROLE (0x00). Decode as a raw word so a dirty (non 0/1) bool
        // cannot revert; any non-zero result is treated as "has role".
        (bool ok, bytes memory ret) =
            account.staticcall(abi.encodeWithSignature("hasRole(bytes32,address)", bytes32(0), caller));
        if (ok && ret.length == 32 && abi.decode(ret, (uint256)) != 0) return true;

        return false;
    }

    /// @dev Static-call `account` with `callData` and return true iff it yields exactly a clean
    /// 32-byte address word equal to `expected`. Malformed return data (wrong length, or dirty high
    /// bits that would make `abi.decode(_, (address))` revert) is treated as no match rather than
    /// propagating, so a non-conforming or hostile account cannot brick or grief the control check.
    function _staticReturnsAddress(address account, bytes memory callData, address expected)
        private
        view
        returns (bool)
    {
        (bool ok, bytes memory ret) = account.staticcall(callData);
        if (!ok || ret.length != 32) return false;
        uint256 word = abi.decode(ret, (uint256));
        return word <= type(uint160).max && address(uint160(word)) == expected;
    }

    function _authorizeUpgrade(address newImplementation) internal view override onlyOwner {
        // 1. Restrict upgrades to the adapter owner.
        // 2. Accept the implementation address through UUPS validation in the inherited logic.
        newImplementation;
    }

    /// @dev Reject an address without deployed code and the ERC-8004 identity registry itself as
    /// `tokenContract`. Runtime code is required so an EOA cannot masquerade as an ownerless
    /// collection. Calls from a token contract constructor are unsupported because its runtime code
    /// is not installed yet. Binding the registry would let `_hasBindingControl` resolve to the
    /// adapter post-bind, permanently locking the agent away from any external controller.
    function _requireValidTokenContract(address tokenContract) internal view {
        if (tokenContract.code.length == 0) {
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
        // 1. Pin contract-level bindings to the canonical id 0 in the same call that decides control,
        //    so no write path can reach storage or an event with a nonzero contract-binding id.
        _requireCanonicalTokenId(standard, tokenContract, tokenId);

        // 2. Reuse the token-standard-specific control check before first registration.
        if (!_hasBindingControl(standard, tokenContract, tokenId, account)) {
            revert NotController(account, type(uint256).max);
        }
    }

    /// @dev Authorizes registration and every unsigned counterfactual write through one of two modes:
    /// (1) the existing current-controller model — which for contract bindings always includes the
    /// bound contract itself — or (2) temporary collection authority when the direct caller is
    /// the ERC-721/ERC-1155F/ERC-6909F token contract and `ownerOf(tokenId)` reports no current owner.
    /// The latter window reopens after a burn if `ownerOf` again reverts or returns zero; preventing
    /// that would require historical-existence storage.
    ///
    /// Every mode compares the adapter's immediate EVM caller against `tokenContract`, so a router,
    /// forwarder, or multicall that calls the adapter itself cannot stand in for the bound contract.
    /// An external owner or governance address may still drive this by calling an entry point on the
    /// bound contract that makes the outbound adapter call. `delegatecall` into this contract is
    /// unsupported and dangerous: it is a UUPS implementation with its own storage layout.
    /// For a `CONTRACT` binding that also means the permanent authority is worth nothing without a
    /// repeatable outbound path: a contract that cannot call out cannot bind at all (constructor
    /// calls are rejected), and one with a single post-deployment hook binds once and then freezes.
    function _requireTokenAuthority(TokenStandard standard, address tokenContract, uint256 tokenId, address account)
        internal
        view
    {
        // 1. Pin contract-level bindings to the canonical id 0 before any authority branch is taken,
        //    so the ownerless window cannot be entered and no emit-only path can escape the check.
        _requireCanonicalTokenId(standard, tokenContract, tokenId);

        // 2. Temporary single-owner collection authority, then the shared current-control chain.
        if (account == tokenContract && _isSingleOwnerStandard(standard) && _hasNoCurrentOwner(tokenContract, tokenId))
        {
            return;
        }
        _requireBindingControl(standard, tokenContract, tokenId, account);
    }

    /// @dev `CONTRACT` and `CONTRACT_OWNABLE` name the contract itself rather than a token within it, so each has
    /// exactly one canonical coordinate: `tokenId == 0`. Enforced at both authority choke points
    /// (`_requireTokenAuthority` and `_requireBindingControl`) so every write and control decision for
    /// a contract-level binding sees the same id. Reverts rather than coercing a nonzero id to `0`:
    /// silent coercion would hand the caller a binding and a `registrationHash` that do not match the
    /// id they submitted. No-op for every other standard.
    function _requireCanonicalTokenId(TokenStandard standard, address tokenContract, uint256 tokenId) internal pure {
        if ((standard == TokenStandard.CONTRACT || standard == TokenStandard.CONTRACT_OWNABLE) && tokenId != 0) {
            revert NonZeroTokenIdForContract(tokenContract, tokenId);
        }
    }

    /// @dev Probes `ownerOf` without assuming a universal nonexistent-token revert selector.
    /// Revert and canonical zero mean no current owner; canonical nonzero means owned. A successful
    /// response of any other shape fails closed.
    function _hasNoCurrentOwner(address tokenContract, uint256 tokenId) private view returns (bool) {
        (bool success, bytes memory result) =
            tokenContract.staticcall(abi.encodeCall(ISingleOwnerToken.ownerOf, (tokenId)));
        if (!success) {
            return true;
        }
        if (result.length != 32) {
            revert InvalidOwnerOfResponse(tokenContract, tokenId);
        }

        uint256 ownerWord;
        assembly ("memory-safe") {
            ownerWord := mload(add(result, 0x20))
        }
        if (ownerWord >> 160 != 0) {
            revert InvalidOwnerOfResponse(tokenContract, tokenId);
        }
        return address(uint160(ownerWord)) == address(0);
    }

    function _hasBindingControl(Binding memory binding, address account) internal view returns (bool) {
        return _hasBindingControl(binding.standard, binding.tokenContract, binding.tokenId, account);
    }

    function _hasBindingControl(TokenStandard standard, address tokenContract, uint256 tokenId, address account)
        internal
        view
        returns (bool)
    {
        // 1. A contract-level binding names `tokenContract` itself rather than a token within it, so
        //    the bound contract is the controller and nobody else is. There is no per-token owner or
        //    holder to resolve, and the adapter asks the contract nothing: `ownerOf` and both
        //    `balanceOf` shapes are never probed on this branch, and `tokenId` is not consulted (it is
        //    pinned to 0 at the choke points above). Anything the contract exposes itself — an
        //    `owner()`, a token balance, a role — carries no authority here, and neither does the
        //    adapter admin.
        //    Unlike the transient single-owner collection window in `_requireTokenAuthority` — which
        //    closes as soon as the id is minted and can reopen on burn — this authority never closes:
        //    there is no token whose ownership could change hands, so the bound contract is the
        //    permanent controller of the agents it binds, before and after binding, and its latest
        //    write to a mutable registry field wins. Deliberately not part of
        //    `_isSingleOwnerStandard`, so it gets no ownerless-window probe and no delegate.xyz
        //    ERC-721 delegation route. (An ERC-20 binding its own contract-level identity through
        //    `CONTRACT` is the motivating example, but nothing here is specific to tokens.)
        if (standard == TokenStandard.CONTRACT) {
            return account == tokenContract;
        }

        // 2. The explicit ownable contract model retains contract-self authority and additionally
        //    follows the contract's live `owner()`. The probe is a fail-closed STATICCALL: a revert,
        //    wrong-length response, dirty upper bits, or zero owner grants no external authority.
        //    This standard remains outside the single-owner token set, so it gets neither an
        //    ownerless-collection window nor delegate.xyz authority.
        if (standard == TokenStandard.CONTRACT_OWNABLE) {
            return account == tokenContract || _isCurrentContractOwner(tokenContract, account);
        }

        // 3. Single-owner standards mean current token ownership, or a valid delegate.xyz ERC-721-style
        //    delegation from the current owner. Direct ownership is checked first so current owners
        //    never pay a registry call.
        if (_isSingleOwnerStandard(standard)) {
            address owner = ISingleOwnerToken(tokenContract).ownerOf(tokenId);
            if (account == owner) {
                return true;
            }
            return _isERC721Delegate(account, owner, tokenContract, tokenId);
        }

        // 4. ERC-1155 control means any positive balance for the bound id.
        //    No delegate.xyz check: the no-vault API cannot soundly map a delegation to a holder.
        if (standard == TokenStandard.ERC1155) {
            return IERC1155(tokenContract).balanceOf(account, tokenId) > 0;
        }

        // 5. ERC-6909 control also means any positive balance for the bound id.
        //    No delegate.xyz check: v2 has no ERC-6909 token-id delegation primitive.
        return IERC6909(tokenContract).balanceOf(account, tokenId) > 0;
    }

    function _isSingleOwnerStandard(TokenStandard standard) internal pure returns (bool) {
        return
            standard == TokenStandard.ERC721 || standard == TokenStandard.ERC1155F || standard == TokenStandard.ERC6909F;
    }

    /// @dev Fail-closed EIP-173 owner probe for the opt-in `CONTRACT_OWNABLE` standard. The typed
    /// interface pins `owner()` as `view`, and the low-level `staticcall` makes that read-only at the
    /// EVM level. Only exactly one clean ABI address word is accepted. A zero owner never matches,
    /// including when `account` is also zero.
    function _isCurrentContractOwner(address tokenContract, address account) private view returns (bool) {
        (bool success, bytes memory result) = tokenContract.staticcall(abi.encodeCall(IOwnableContract.owner, ()));
        if (!success || result.length != 32) {
            return false;
        }

        uint256 ownerWord;
        assembly ("memory-safe") {
            ownerWord := mload(add(result, 0x20))
        }
        if (ownerWord >> 160 != 0) {
            return false;
        }

        address currentOwner = address(uint160(ownerWord));
        return currentOwner != address(0) && account == currentOwner;
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

    /// @dev Rejects any metadata entry that targets a reserved key: the canonical binding record
    /// (`agent-binding`) or the canonical-promotion key (`cf-registration`). Used on every adapter
    /// write path that accepts a metadata array (register and the counterfactual surface). No adapter
    /// path writes either key legitimately, so an emitter cannot fabricate a binding record or a
    /// promotion back-link.
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

    function _registrationHash(address tokenContract, uint256 tokenId) internal view virtual returns (bytes32) {
        return _registrationHashFor(_interoperableAddress(address(this)), tokenContract, tokenId);
    }

    /// @dev ERC-7930 v1 Chain Identifier using the CAIP-350 `eip155` profile:
    /// version(0x0001) || ChainType(0x0000) || referenceLength || shortest non-empty
    /// big-endian block.chainid || addressLength(0x00).
    function _chainIdentifier() internal view virtual returns (bytes memory identifier) {
        return _chainIdentifierFor(block.chainid);
    }

    /// @dev Full ERC-7930 v1 Interoperable Address using the local CAIP-350 `eip155` chain reference
    /// and the raw 20-byte EVM address.
    function _interoperableAddress(address account) internal view virtual returns (bytes memory identifier) {
        return _interoperableAddressFor(block.chainid, account);
    }

    function _chainIdentifierFor(uint256 chainId) internal pure returns (bytes memory identifier) {
        return _erc7930AddressFor(chainId, address(0), false);
    }

    function _interoperableAddressFor(uint256 chainId, address account)
        internal
        pure
        returns (bytes memory identifier)
    {
        return _erc7930AddressFor(chainId, account, true);
    }

    function _erc7930AddressFor(uint256 chainId, address account, bool includeAddress)
        private
        pure
        returns (bytes memory identifier)
    {
        if (chainId == 0) revert InvalidChainId();

        uint256 referenceLength;
        uint256 remaining = chainId;
        while (remaining != 0) {
            ++referenceLength;
            remaining >>= 8;
        }

        identifier = new bytes(referenceLength + 6 + (includeAddress ? 20 : 0));
        identifier[1] = 0x01;
        identifier[4] = bytes1(uint8(referenceLength));
        for (uint256 i; i < referenceLength; ++i) {
            identifier[5 + referenceLength - 1 - i] = bytes1(uint8(chainId >> (i * 8)));
        }
        if (includeAddress) {
            identifier[5 + referenceLength] = 0x14;
            bytes20 rawAddress = bytes20(account);
            for (uint256 i; i < 20; ++i) {
                identifier[6 + referenceLength + i] = rawAddress[i];
            }
        }
        // Otherwise the final byte remains zero: ERC-7930 AddressLength == 0.
    }

    /// @dev The canonical counterfactual identity is
    /// `keccak256(abi.encode(adapterInteroperableAddress, tokenContract, tokenId, extraData))`.
    function _registrationHashFor(bytes memory adapterInteroperableAddress, address tokenContract, uint256 tokenId)
        internal
        pure
        returns (bytes32)
    {
        return keccak256(abi.encode(adapterInteroperableAddress, tokenContract, tokenId, COUNTERFACTUAL_EXTRA_DATA));
    }

    /// @dev Stateless EIP-712 domain separator for the signed primary-agent surface. Computed inline
    /// from constants, `block.chainid`, and `address(this)`; never cached, so no storage is added and
    /// cross-chain / cross-adapter replay is blocked by `chainId` and `verifyingContract`.
    function _domainSeparator() internal view returns (bytes32) {
        return keccak256(
            abi.encode(
                EIP712_DOMAIN_TYPEHASH,
                keccak256(bytes(EIP712_NAME)),
                keccak256(bytes(EIP712_VERSION)),
                block.chainid,
                address(this)
            )
        );
    }
}
