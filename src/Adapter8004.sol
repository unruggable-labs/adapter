// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

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
/// @dev Storage layout, which is what an upgrade reviewer should check first. Regular slot 0 is
/// `identityRegistry` and slot 1 is `_bindings`; both are carried from the deployed baseline, which
/// uses those two slots and nothing else. Slots 2 through 4 hold the three primary-agent mappings.
/// The layout is append-only: add new state after slot 4, and never reorder, insert or repurpose an
/// existing slot. No slots are reserved and there is no storage gap, so nothing is set aside to
/// consume. Upgrading a live proxy needs no migration and no reinitializer, and must use empty
/// `upgradeToAndCall` data.
///
/// Counterfactual identities are keyed by a `registrationHash` over the ERC-7930 interoperable
/// address of this proxy, the `TokenStandard` as its `uint8`, the bound address, the token id, and a
/// `bytes32 extraData` discriminator. `extraData` is a `constant` fixed at `bytes32(0)`, so it
/// occupies no storage, and every triple that hashes with zero hashes identically from here on.
/// Because the standard is in the preimage, one `(boundAddress, tokenId)` claimed under two
/// standards is two identities rather than one, so a claimant's history can never land on another
/// claimant's identity. That preimage does not match the one a live proxy computes today, so
/// upgrading one is a hard cutover for any indexer consuming counterfactual events: move it to this
/// ABI and reindex before upgrading. `Binding` rows and full ERC-8004 registrations are not keyed by
/// this hash and are unaffected. See CHANGELOG.md for the cutover detail and for anything this
/// implementation changed relative to a deployed one.
/// @custom:version 0.0.17
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

    /// @notice Reserved metadata key. Nothing writes it today, including this contract.
    ///
    /// It is held open for a possible future flow that records which counterfactual claim an
    /// on-chain registration was promoted from. That flow does not exist and may never be built.
    /// The key is reserved regardless, so that if it ever is, no caller has already written a false
    /// provenance claim under it. Every write path that accepts caller metadata rejects this key:
    /// all counterfactual writes, and the canonical `register`, `setMetadata` and `setMetadataBatch`.
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
    /// `(boundAddress, tokenId)`, such as a contract with classes of ids where Class A id 1 and
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

    /// @notice Thrown when the address a binding names is unusable: the zero address under any
    /// standard, or an address with no runtime code under any standard except `ACCOUNT`.
    error InvalidBoundAddress();
    /// @notice Thrown when a single-owner token's `ownerOf(tokenId)` call succeeds but does not
    /// return exactly one canonical ABI-encoded address word. Malformed success responses fail
    /// closed rather than opening the ownerless collection-authority window.
    error InvalidOwnerOfResponse(address boundAddress, uint256 tokenId);
    /// @notice Thrown when a binding attempts to set `boundAddress` to the ERC-8004 identity registry
    /// itself. Permitted-and-then-bound, the agent would be permanently uncontrollable because
    /// `ownerOf(tokenId)` on the registry resolves to the adapter post-bind, locking the only path
    /// through `_hasBindingControl`.
    error BoundAddressIsRegistry();
    /// @notice Thrown by any `ACCOUNT`, `CONTRACT_OWNABLE` or `CONTRACT_ADMIN` operation called with a nonzero
    /// `tokenId`. This covers registration and the emit-only counterfactual calls
    /// alike, since all of them pass through the same authority choke points. An account-level binding names the address
    /// itself rather than a token within it, so it has exactly one canonical coordinate, `tokenId ==
    /// 0`. The nonzero id is rejected rather than coerced so the caller's binding or emitted claim,
    /// its `registrationHash`, and any pointer derived from it can never disagree with the id the
    /// caller submitted.
    error NonZeroTokenIdForAccount(address boundAddress, uint256 tokenId);
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
        address indexed boundAddress,
        uint256 tokenId,
        address registeredBy
    );

    event IdentityRegistryUpdated(
        address indexed previousRegistry, address indexed newRegistry, address indexed updatedBy
    );

    event AgentURISet(uint256 indexed agentId, string newURI, address indexed updatedBy);
    event MetadataSet(uint256 indexed agentId, string metadataKey, bytes metadataValue, address indexed updatedBy);
    event AgentWalletSet(uint256 indexed agentId, address indexed newWallet, address indexed updatedBy);
    event AgentWalletUnset(uint256 indexed agentId, address indexed updatedBy);

    IERC8004IdentityRegistry public identityRegistry;

    mapping(uint256 agentId => Binding binding) private _bindings;

    /// @notice Full-system unset sentinel. Agent id zero remains representable.
    uint256 public constant PRIMARY_AGENT_UNSET = type(uint256).max;
    bytes32 public constant PRIMARY_COUNTERFACTUAL_AGENT_UNSET = bytes32(type(uint256).max);

    /// @dev Reverse claims and full-system nonces. These three mappings occupy regular slots 2 through
    /// 4, in the order declared here, and are append-only: never reorder, insert between them, or
    /// repurpose one. They begin empty on a proxy upgraded from the deployed baseline, which holds
    /// slots 0 and 1 only. No slots are reserved ahead of them.
    mapping(address account => uint256 complementAgentId) private _primaryAgent;
    mapping(address account => bytes32 complementRegistrationHash) private _primaryCounterfactualAgent;
    mapping(address account => uint256 nonce) private _primaryAgentNonces;

    /// @custom:oz-upgrades-unsafe-allow constructor
    constructor() {
        _disableInitializers();
    }

    /// @notice Initializes a newly deployed proxy.
    /// @dev Do not call during an upgrade of an existing proxy. An active proxy already has slots 0
    /// and 1 initialized, the mappings at slots 2 through 4 are meant to begin empty, and there is no
    /// reinitializer, so an upgrade carries empty `upgradeToAndCall` data instead of calling this.
    function initialize(address identityRegistry_, address initialOwner) external initializer {
        // 1. Reject an unusable registry target before any state is initialized.
        if (identityRegistry_ == address(0)) {
            revert InvalidBoundAddress();
        }

        // 2. Set the adapter admin who controls upgrades and registry repointing.
        __Ownable_init(initialOwner);

        // 3. Store the initial ERC-8004 registry the adapter will forward into.
        identityRegistry = IERC8004IdentityRegistry(identityRegistry_);
    }

    /// @notice Repoint the ERC-8004 registry that every adapter write forwards into. Owner only.
    /// @dev This is the highest-impact administrative action on the contract. Existing bindings are
    /// untouched, but they name agent ids that only mean anything in the old registry, so every
    /// already-bound agent resolves against a registry that may not know it. Point this at a registry
    /// that does not hold the existing identities and the bound agents become unreachable through the
    /// adapter. Emits `IdentityRegistryUpdated`.
    function setIdentityRegistry(address newIdentityRegistry) external onlyOwner nonReentrant {
        // 1. Reject an unusable registry target.
        if (newIdentityRegistry == address(0)) {
            revert InvalidBoundAddress();
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
        address boundAddress,
        uint256 tokenId,
        string calldata agentURI,
        IERC8004IdentityRegistry.MetadataEntry[] memory metadata
    ) public nonReentrant returns (uint256 agentId) {
        return _register(standard, boundAddress, tokenId, agentURI, metadata);
    }

    function register(TokenStandard standard, address boundAddress, uint256 tokenId, string calldata agentURI)
        external
        nonReentrant
        returns (uint256 agentId)
    {
        return _register(standard, boundAddress, tokenId, agentURI, new IERC8004IdentityRegistry.MetadataEntry[](0));
    }

    function _register(
        TokenStandard standard,
        address boundAddress,
        uint256 tokenId,
        string calldata agentURI,
        IERC8004IdentityRegistry.MetadataEntry[] memory metadata
    ) private returns (uint256 agentId) {
        // 1. Reject an unusable bound address, and reject the registry itself
        //    (binding to the registry would lock the agent permanently post-register).
        _requireValidBoundAddress(standard, boundAddress);

        // 2. Confirm the caller currently controls the token being bound, or is the directly
        //    calling single-owner collection while the id has no current owner.
        _requireTokenAuthority(standard, boundAddress, tokenId, msg.sender);

        // 3. Reject user-supplied metadata entries that target reserved keys: the canonical
        //    binding record (agent-binding) and cf-registration, which no register path writes.
        _requireNoReservedCounterfactualKeys(metadata);

        // 4. Register the ERC-8004 identity so the adapter becomes the registry owner.
        //    Skip the metadata-array overload when there is nothing to write, which saves the
        //    empty-array calldata + memory copy on the registry side.
        if (metadata.length == 0) {
            agentId = identityRegistry.register(agentURI);
        } else {
            agentId = identityRegistry.register(agentURI, metadata);
        }

        // 5. Persist the immutable link from the ERC-8004 agent to the bound address.
        _bindings[agentId] = Binding({standard: standard, boundAddress: boundAddress, tokenId: tokenId});

        // 6. Write the canonical binding metadata (binding contract address only; ERC-8217).
        identityRegistry.setMetadata(agentId, BINDING_METADATA_KEY, abi.encodePacked(address(this)));

        // 7. Clear the default ERC-8004 wallet because registration set it to the adapter.
        identityRegistry.unsetAgentWallet(agentId);

        // 8. Emit the final binding record for off-chain discovery.
        emit AgentBound(agentId, standard, boundAddress, tokenId, msg.sender);
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
        //    (agent-binding), which only this contract writes, and cf-registration, which
        //    nothing writes today. Neither is a valid controller write.
        bytes32 keyHash = keccak256(bytes(metadataKey));
        if (keyHash == BINDING_METADATA_KEY_HASH || keyHash == CF_REGISTRATION_KEY_HASH) {
            revert ReservedMetadataKey(metadataKey);
        }

        // 3. Forward the metadata write into the ERC-8004 registry.
        identityRegistry.setMetadata(agentId, metadataKey, metadataValue);

        // 4. Emit the adapter-level metadata write after the forwarded registry call succeeds.
        emit MetadataSet(agentId, metadataKey, metadataValue, msg.sender);
    }

    /// @notice Write several metadata entries for one agent, in the order given. The caller must
    /// control the bound token, and no entry may target the reserved `agent-binding` or
    /// `cf-registration` keys.
    /// @dev Each entry emits its own `MetadataSet`. There is no batch event, so a batch is
    /// indistinguishable from a run of individual writes.
    function setMetadataBatch(uint256 agentId, IERC8004IdentityRegistry.MetadataEntry[] calldata metadata)
        external
        nonReentrant
    {
        // 1. Confirm the caller currently controls the bound token.
        _requireController(agentId, msg.sender);

        // 2. Prevent callers from writing reserved metadata (agent-binding and cf-registration).
        _requireNoReservedCounterfactualKeys(metadata);

        // 3. Replay each write through the ERC-8004 registry. The emit sits inside the loop rather
        //    than after it so each adapter event lands next to the registry write it describes,
        //    which is what an indexer applying events in log order depends on.
        uint256 length = metadata.length;
        for (uint256 i; i < length; ++i) {
            identityRegistry.setMetadata(agentId, metadata[i].metadataKey, metadata[i].metadataValue);
            emit MetadataSet(agentId, metadata[i].metadataKey, metadata[i].metadataValue, msg.sender);
        }
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
        if (binding.boundAddress == address(0)) {
            revert UnknownAgent(agentId);
        }

        // 3. Return the immutable token binding.
        return binding;
    }

    /// @notice Whether `account` may act for `agentId` right now. This is the same check every
    /// adapter write performs.
    /// @dev Authority is resolved live from the bound token on every call and is never stored, so the
    /// answer can change in the same block that a token transfers or a bound contract's `owner()`
    /// changes. A consumer must not cache it. `_hasBindingControl` carries the per-standard rules.
    ///
    /// A blanket delegate.xyz delegation, one naming no rights at all, is accepted even though the
    /// owner never named `adapter8004.manage`. The registry offers no way to ask for a scoped-only
    /// match, so this cannot be narrowed on-chain.
    function isController(uint256 agentId, address account) external view returns (bool) {
        // 1. Load the binding that defines who controls this agent.
        Binding memory binding = _bindings[agentId];

        // 2. Unknown agents do not have a controller.
        if (binding.boundAddress == address(0)) {
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
    // Emit-only mirrors of the on-chain register surface. They write nothing to adapter storage and
    // make no ERC-8004 registry calls, so a claim can never be withdrawn, only superseded by a later
    // event. Authority matches the on-chain surface, plus the temporary
    // ownerless-collection route documented below. `IERC8004AdapterCounterfactual` states the rule
    // that consumers must key on `registrationHash` rather than on `(boundAddress, tokenId)`.
    // -----------------------------------------------------------------

    function registrationHash(TokenStandard standard, address boundAddress, uint256 tokenId)
        external
        view
        returns (bytes32)
    {
        return _registrationHash(standard, boundAddress, tokenId);
    }

    /// @inheritdoc IERC8004AdapterCounterfactual
    function interoperableAddress(address account) external view returns (bytes memory) {
        return _interoperableAddress(account);
    }

    /// @inheritdoc IERC8004AdapterCounterfactual
    function chainIdentifier() external view returns (bytes memory) {
        return _chainIdentifier();
    }

    /// @notice Announce an identity claim for a bound address. The claim lives entirely in the event
    /// log. A current controller may call this, as may a collection calling directly while one of its
    /// ERC-721, ERC-1155F or ERC-6909F ids has no current owner. The same authority may re-emit any
    /// number of times. Collection-authorized events set `emitter = boundAddress`.
    function counterfactualRegister(
        TokenStandard standard,
        address boundAddress,
        uint256 tokenId,
        string calldata agentURI,
        IERC8004IdentityRegistry.MetadataEntry[] memory metadata
    ) public nonReentrant returns (bytes32 computedHash) {
        return _counterfactualRegisterImpl(standard, boundAddress, tokenId, agentURI, metadata);
    }

    /// @notice Convenience overload equivalent to `counterfactualRegister(...)` with an empty metadata array.
    function counterfactualRegister(
        TokenStandard standard,
        address boundAddress,
        uint256 tokenId,
        string calldata agentURI
    ) external nonReentrant returns (bytes32 computedHash) {
        return _counterfactualRegisterImpl(
            standard, boundAddress, tokenId, agentURI, new IERC8004IdentityRegistry.MetadataEntry[](0)
        );
    }

    function _counterfactualRegisterImpl(
        TokenStandard standard,
        address boundAddress,
        uint256 tokenId,
        string calldata agentURI,
        IERC8004IdentityRegistry.MetadataEntry[] memory metadata
    ) private returns (bytes32 computedHash) {
        // 1. Reject an unusable bound address and reject the registry itself so the
        //    revert taxonomy matches `register`.
        _requireValidBoundAddress(standard, boundAddress);

        // 2. Confirm the caller is a current controller, or the directly calling single-owner token
        //    contract while `tokenId` has no current owner.
        _requireTokenAuthority(standard, boundAddress, tokenId, msg.sender);

        // 3. Reject user-supplied metadata entries that target reserved counterfactual records.
        _requireNoReservedCounterfactualKeys(metadata);

        // 4. Compute the deterministic registration hash used as the indexer key for this claim.
        computedHash = _registrationHash(standard, boundAddress, tokenId);

        // 5. Emit the counterfactual claim, which is the only on-chain record this function produces.
        emit CounterfactualAgentRegistered(
            computedHash, boundAddress, tokenId, COUNTERFACTUAL_EXTRA_DATA, standard, agentURI, metadata, msg.sender
        );
    }

    /// @notice Update the agent URI for a counterfactual identity. The update lives entirely in the
    /// event log. A current controller may call this, as may a collection calling directly while a
    /// supported single-owner id has no current owner.
    function counterfactualSetAgentURI(
        TokenStandard standard,
        address boundAddress,
        uint256 tokenId,
        string calldata newURI
    ) external nonReentrant {
        // 1. Reject an unusable bound address and reject the registry itself so the
        //    revert taxonomy matches `register`.
        _requireValidBoundAddress(standard, boundAddress);

        // 2. Apply current-controller or ownerless collection authority.
        _requireTokenAuthority(standard, boundAddress, tokenId, msg.sender);

        // 3. Emit the URI update, which is the only on-chain record this function produces.
        emit CounterfactualAgentURISet(
            _registrationHash(standard, boundAddress, tokenId),
            boundAddress,
            tokenId,
            COUNTERFACTUAL_EXTRA_DATA,
            standard,
            newURI,
            msg.sender
        );
    }

    /// @notice Records one metadata entry for a counterfactual identity. The entry is carried only by
    /// the emitted event, so nothing is written to the ERC-8004 registry or to adapter storage. A
    /// current controller may call it, as may the token contract itself while a supported
    /// single-owner id has no current owner.
    function counterfactualSetMetadata(
        TokenStandard standard,
        address boundAddress,
        uint256 tokenId,
        string calldata metadataKey,
        bytes calldata metadataValue
    ) external nonReentrant {
        // 1. Reject an unusable bound address and reject the registry itself so the
        //    revert taxonomy matches `register`.
        _requireValidBoundAddress(standard, boundAddress);

        // 2. Apply current-controller or ownerless collection authority.
        _requireTokenAuthority(standard, boundAddress, tokenId, msg.sender);

        // 3. Prevent callers from claiming reserved metadata slots in counterfactual events.
        //    Cache the key hash once: `metadataKey` is `calldata` but recomputing the hash twice in
        //    a hot path still spends a few hundred gas for no benefit.
        bytes32 keyHash = keccak256(bytes(metadataKey));
        if (keyHash == BINDING_METADATA_KEY_HASH || keyHash == CF_REGISTRATION_KEY_HASH) {
            revert ReservedMetadataKey(metadataKey);
        }

        // 4. Emit the metadata write, which is the only on-chain record this function produces.
        emit CounterfactualMetadataSet(
            _registrationHash(standard, boundAddress, tokenId),
            boundAddress,
            tokenId,
            COUNTERFACTUAL_EXTRA_DATA,
            standard,
            metadataKey,
            metadataValue,
            msg.sender
        );
    }

    /// @notice Records several metadata entries for a counterfactual identity in one event. The
    /// entries are carried only by that event, so nothing is written to the ERC-8004 registry or to
    /// adapter storage. A current controller may call it, as may the token contract itself while a
    /// supported single-owner id has no current owner.
    function counterfactualSetMetadataBatch(
        TokenStandard standard,
        address boundAddress,
        uint256 tokenId,
        IERC8004IdentityRegistry.MetadataEntry[] calldata metadata
    ) external nonReentrant {
        // 1. Reject an unusable bound address and reject the registry itself so the
        //    revert taxonomy matches `register`.
        _requireValidBoundAddress(standard, boundAddress);

        // 2. Apply current-controller or ownerless collection authority.
        _requireTokenAuthority(standard, boundAddress, tokenId, msg.sender);

        // 3. Prevent callers from claiming reserved metadata slots in counterfactual events.
        _requireNoReservedCounterfactualKeys(metadata);

        // 4. Emit the batch, which is the only on-chain record this function produces.
        emit CounterfactualMetadataBatchSet(
            _registrationHash(standard, boundAddress, tokenId),
            boundAddress,
            tokenId,
            COUNTERFACTUAL_EXTRA_DATA,
            standard,
            metadata,
            msg.sender
        );
    }

    /// @notice Assigns the agent wallet for a counterfactual identity. It deliberately accepts no
    /// signature, because no ERC-8004 wallet binding is created and the event is only an off-chain
    /// claim. A current controller may call it, as may the token contract itself while a supported
    /// single-owner id has no current owner.
    function counterfactualSetAgentWallet(
        TokenStandard standard,
        address boundAddress,
        uint256 tokenId,
        address newWallet
    ) external nonReentrant {
        // 1. Reject an unusable bound address and reject the registry itself so the
        //    revert taxonomy matches `register`.
        _requireValidBoundAddress(standard, boundAddress);

        // 2. Apply current-controller or ownerless collection authority.
        _requireTokenAuthority(standard, boundAddress, tokenId, msg.sender);

        // 3. Emit the wallet assignment, which is the only on-chain record this function produces.
        emit CounterfactualAgentWalletSet(
            _registrationHash(standard, boundAddress, tokenId),
            boundAddress,
            tokenId,
            COUNTERFACTUAL_EXTRA_DATA,
            standard,
            newWallet,
            msg.sender
        );
    }

    /// @notice Clears the agent wallet on a counterfactual identity. The clear is carried only by the
    /// emitted event, so nothing is written to the ERC-8004 registry or to adapter storage. A current
    /// controller may call it, as may the token contract itself while a supported single-owner id has
    /// no current owner.
    function counterfactualUnsetAgentWallet(TokenStandard standard, address boundAddress, uint256 tokenId)
        external
        nonReentrant
    {
        // 1. Reject an unusable bound address and reject the registry itself so the
        //    revert taxonomy matches `register`.
        _requireValidBoundAddress(standard, boundAddress);

        // 2. Apply current-controller or ownerless collection authority.
        _requireTokenAuthority(standard, boundAddress, tokenId, msg.sender);

        // 3. Emit the wallet clear, which is the only on-chain record this function produces.
        emit CounterfactualAgentWalletUnset(
            _registrationHash(standard, boundAddress, tokenId),
            boundAddress,
            tokenId,
            COUNTERFACTUAL_EXTRA_DATA,
            standard,
            msg.sender
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
    /// ones) when the account has never set an id or has cleared it. Every real id, including agent
    /// id `0`, is returned as itself.
    function primaryAgentOf(address account) external view returns (uint256) {
        uint256 stored = _primaryAgent[account];
        return stored == 0 ? PRIMARY_AGENT_UNSET : ~stored;
    }

    function _setPrimaryAgent(address account, uint256 agentId) private {
        if (agentId == type(uint256).max) revert PrimaryAgentIdReserved(agentId);
        _primaryAgent[account] = ~agentId;
        emit PrimaryAgentSet(account, agentId, msg.sender);
    }

    /// @dev Reset the account's complement slot to zero, which reads back as `PRIMARY_AGENT_UNSET`,
    /// and emit `PrimaryAgentCleared`. `delete` restores the exact "unwritten == unset" invariant.
    function _clearPrimaryAgent(address account) private {
        delete _primaryAgent[account];
        emit PrimaryAgentCleared(account, msg.sender);
    }

    // -----------------------------------------------------------------
    //  Counterfactual primary agent (reverse resolution: address -> registration hash)
    // -----------------------------------------------------------------

    function setPrimaryCounterfactualAgent(TokenStandard standard, address boundAddress, uint256 tokenId)
        external
        returns (bytes32 computedHash)
    {
        return _setPrimaryCounterfactualAgent(msg.sender, standard, boundAddress, tokenId);
    }

    function setPrimaryCounterfactualAgentFor(
        address account,
        TokenStandard standard,
        address boundAddress,
        uint256 tokenId
    ) external returns (bytes32 computedHash) {
        if (!_controlsAccount(account, msg.sender)) revert NotAccountController(account, msg.sender);
        return _setPrimaryCounterfactualAgent(account, standard, boundAddress, tokenId);
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

    function _setPrimaryCounterfactualAgent(
        address account,
        TokenStandard standard,
        address boundAddress,
        uint256 tokenId
    ) private returns (bytes32 computedHash) {
        computedHash = _registrationHash(standard, boundAddress, tokenId);
        if (computedHash == bytes32(type(uint256).max)) {
            revert PrimaryCounterfactualAgentHashReserved(computedHash);
        }
        _primaryCounterfactualAgent[account] = ~computedHash;
        emit PrimaryCounterfactualAgentSet(
            account, computedHash, boundAddress, tokenId, COUNTERFACTUAL_EXTRA_DATA, standard, msg.sender
        );
    }

    function _clearPrimaryCounterfactualAgent(address account) private {
        delete _primaryCounterfactualAgent[account];
        emit PrimaryCounterfactualAgentCleared(account, msg.sender);
    }

    // -----------------------------------------------------------------
    //  Signed (gasless, account-self) primary agent surface
    // -----------------------------------------------------------------

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

        // AccessControl: DEFAULT_ADMIN_ROLE.
        return _hasDefaultAdminRole(account, caller);
    }

    /// @dev Fail-closed AccessControl probe for `DEFAULT_ADMIN_ROLE`, which is `bytes32(0)`. Shared by
    /// the account-control check above and the `CONTRACT_ADMIN` binding standard, so both agree on
    /// what holding the role means.
    ///
    /// The result is decoded as a raw word rather than as a `bool` because a contract may return a
    /// value outside `0` and `1` for a `bool` return. `abi.decode(ret, (bool))` reverts on such a
    /// value, which would let a non-conforming contract break the authority check rather than simply
    /// fail it. Any non-zero word is treated as holding the role. A contract that does not implement
    /// `hasRole` at all, or answers with the wrong length, grants nobody.
    function _hasDefaultAdminRole(address target, address account) private view returns (bool) {
        (bool ok, bytes memory ret) =
            target.staticcall(abi.encodeWithSignature("hasRole(bytes32,address)", bytes32(0), account));
        return ok && ret.length == 32 && abi.decode(ret, (uint256)) != 0;
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

    /// @dev Validates the bound address for a given standard. Two rules, with different scopes.
    ///
    /// The runtime-code requirement applies to every standard except `ACCOUNT`. The seven that need
    /// it all call into the bound address: `ownerOf` or `balanceOf` for the token standards,
    /// `owner()` for `CONTRACT_OWNABLE`, and `hasRole` for `CONTRACT_ADMIN`. Every one of those
    /// probes already fails closed against a code-less address, because a staticcall to an address
    /// with no code succeeds and returns nothing, and each probe rejects a response that is not
    /// exactly 32 bytes. So this check produces a precise error early rather than standing as the
    /// only thing preventing an EOA from masquerading as a collection. For those seven it also means
    /// calls from the bound contract's constructor stay unsupported, since runtime code is not
    /// installed yet. `ACCOUNT` is the exception: a contract binding itself as `ACCOUNT` from its own
    /// constructor now succeeds, because `msg.sender` is already its final address and no code test
    /// stands in the way.
    ///
    /// `ACCOUNT` is exempt because it never calls the bound address. Its authority is the single
    /// comparison `account == boundAddress`, which is well defined whether or not the address has
    /// code, so there is nothing for a code test to protect. Requiring code there would not even
    /// select for EOAs: under EIP-7702 a delegated EOA carries a 23-byte designator and passes,
    /// while the same address before or after that delegation does not.
    ///
    /// The zero address is rejected under every standard, `ACCOUNT` included. `_bindings` uses a
    /// zero `boundAddress` as its unbound sentinel, so a zero binding would be indistinguishable
    /// from no binding and would make `bindingOf` and `UnknownAgent` lie. Nothing could authorize it
    /// in any case, since `msg.sender` is never the zero address.
    ///
    /// The registry rejection applies to every standard. Binding the registry would let
    /// `_hasBindingControl` resolve to the adapter post-bind, permanently locking the agent away
    /// from any external controller.
    function _requireValidBoundAddress(TokenStandard standard, address boundAddress) internal view {
        if (boundAddress == address(0)) {
            revert InvalidBoundAddress();
        }
        if (standard != TokenStandard.ACCOUNT && boundAddress.code.length == 0) {
            revert InvalidBoundAddress();
        }
        if (boundAddress == address(identityRegistry)) {
            revert BoundAddressIsRegistry();
        }
    }

    function _requireController(uint256 agentId, address account) internal view {
        // 1. Load the binding for the requested agent.
        Binding memory binding = _bindings[agentId];

        // 2. Reject unknown agents before checking token ownership state.
        if (binding.boundAddress == address(0)) {
            revert UnknownAgent(agentId);
        }

        // 3. Revert when the caller no longer controls the bound token.
        if (!_hasBindingControl(binding, account)) {
            revert NotController(account, agentId);
        }
    }

    function _requireBindingControl(TokenStandard standard, address boundAddress, uint256 tokenId, address account)
        internal
        view
    {
        // 1. Pin account-level bindings to the canonical id 0 in the same call that decides control,
        //    so no write path can reach storage or an event with a nonzero contract-binding id.
        _requireCanonicalTokenId(standard, boundAddress, tokenId);

        // 2. Reuse the token-standard-specific control check before first registration.
        if (!_hasBindingControl(standard, boundAddress, tokenId, account)) {
            revert NotController(account, type(uint256).max);
        }
    }

    /// @dev Authorizes registration and every unsigned counterfactual write through one of two modes:
    /// (1) the existing current-controller model, which for account-level bindings resolves the authority
    /// that standard defines, or (2) temporary collection authority when the direct caller is
    /// the ERC-721/ERC-1155F/ERC-6909F token contract and `ownerOf(tokenId)` reports no current owner.
    /// The latter window reopens after a burn if `ownerOf` again reverts or returns zero; preventing
    /// that would require historical-existence storage.
    ///
    /// Every mode compares the adapter's immediate EVM caller against `boundAddress`, so a router,
    /// forwarder, or multicall that calls the adapter itself cannot stand in for the bound address.
    /// An external owner or governance address may still drive this by calling an entry point on the
    /// bound contract that makes the outbound adapter call. `delegatecall` into this contract is
    /// unsupported and dangerous: it is a UUPS implementation with its own storage layout.
    /// For an `ACCOUNT` binding held by a contract that also means the permanent authority is worth
    /// nothing without a repeatable outbound path: a contract that cannot call out cannot bind at all,
    /// and one with a single hook binds once and then freezes. That hook may be the constructor, since
    /// `ACCOUNT` applies no code test. An externally owned account has no such constraint, because
    /// sending a transaction is itself the outbound path.
    function _requireTokenAuthority(TokenStandard standard, address boundAddress, uint256 tokenId, address account)
        internal
        view
    {
        // 1. Pin account-level bindings to the canonical id 0 before any authority branch is taken,
        //    so the ownerless window cannot be entered and no emit-only path can escape the check.
        _requireCanonicalTokenId(standard, boundAddress, tokenId);

        // 2. Temporary single-owner collection authority, then the shared current-control chain.
        if (account == boundAddress && _isSingleOwnerStandard(standard) && _hasNoCurrentOwner(boundAddress, tokenId)) {
            return;
        }
        _requireBindingControl(standard, boundAddress, tokenId, account);
    }

    /// @dev The three account-level standards name the address itself rather than a token within it, so
    /// each has exactly one canonical coordinate: `tokenId == 0`. Enforced in `_requireTokenAuthority`,
    /// which every write passes through, and again in `_requireBindingControl`. The second is now
    /// defence in depth rather than a distinct gate, because every path into `_requireBindingControl`
    /// arrives via `_requireTokenAuthority`, which has already checked. It is kept so a future direct
    /// caller cannot bypass the rule. Reverts rather than coercing a nonzero id to `0`:
    /// silent coercion would hand the caller a binding and a `registrationHash` that do not match the
    /// id they submitted. No-op for every other standard.
    function _requireCanonicalTokenId(TokenStandard standard, address boundAddress, uint256 tokenId) internal pure {
        if (_isAccountStandard(standard) && tokenId != 0) {
            revert NonZeroTokenIdForAccount(boundAddress, tokenId);
        }
    }

    /// @dev Probes `ownerOf` without assuming a universal nonexistent-token revert selector.
    /// Revert and canonical zero mean no current owner; canonical nonzero means owned. A successful
    /// response of any other shape fails closed.
    function _hasNoCurrentOwner(address boundAddress, uint256 tokenId) private view returns (bool) {
        (bool success, bytes memory result) =
            boundAddress.staticcall(abi.encodeCall(ISingleOwnerToken.ownerOf, (tokenId)));
        if (!success) {
            return true;
        }
        if (result.length != 32) {
            revert InvalidOwnerOfResponse(boundAddress, tokenId);
        }

        uint256 ownerWord;
        assembly ("memory-safe") {
            ownerWord := mload(add(result, 0x20))
        }
        if (ownerWord >> 160 != 0) {
            revert InvalidOwnerOfResponse(boundAddress, tokenId);
        }
        return address(uint160(ownerWord)) == address(0);
    }

    function _hasBindingControl(Binding memory binding, address account) internal view returns (bool) {
        return _hasBindingControl(binding.standard, binding.boundAddress, binding.tokenId, account);
    }

    function _hasBindingControl(TokenStandard standard, address boundAddress, uint256 tokenId, address account)
        internal
        view
        returns (bool)
    {
        // 1. An account-level binding names `boundAddress` itself rather than a token within it, so
        //    the bound address is the controller and nobody else is. There is no per-token owner or
        //    holder to resolve, and the adapter asks the address nothing: `ownerOf` and both
        //    `balanceOf` shapes are never probed on this branch, and `tokenId` is not consulted (it is
        //    pinned to 0 at the choke points above). Anything the bound address exposes itself, whether
        //    an `owner()`, a token balance or a role, carries no authority here, and neither does the
        //    adapter admin. Nor does a delegate.xyz delegate of the bound address, which is pinned by
        //    `testAccountGrantsNoDelegationRoute`.
        //    The transient single-owner collection window in `_requireTokenAuthority` closes as soon
        //    as the id is minted and can reopen on burn. This authority never closes:
        //    there is no token whose ownership could change hands, so the bound address is the
        //    permanent controller of the agents it binds, before and after binding, and its latest
        //    write to a mutable registry field wins. Deliberately not part of
        //    `_isSingleOwnerStandard`, so it gets no ownerless-window probe.
        //    It is also the one standard with an identifiable controller that is offered no
        //    delegation route. Delegation is offered where the delegator is an ordinary account,
        //    which is what delegate.xyz is built for. A contract delegating on its own behalf cannot
        //    revoke without the same executor it used to delegate, so a single governance action
        //    could grant authority that nobody can later withdraw. Bind `CONTRACT_OWNABLE` instead
        //    if delegation is wanted, where the delegator is the owner account.
        //    (An ERC-20 binding its own contract-level identity through `ACCOUNT` is the motivating
        //    example, but nothing here is specific to tokens.)
        if (standard == TokenStandard.ACCOUNT) {
            return account == boundAddress;
        }

        // 2. `CONTRACT_OWNABLE` is the fourth member of the owner-and-delegate pattern described at
        //    step 4. It resolves the contract's live `owner()` and accepts either that owner acting
        //    directly or a delegate of that owner. The bound contract itself has no authority here,
        //    which is what separates this standard from `ACCOUNT`. Self-authority would be an
        //    escalation route around the owner, because any contract with a generic call mechanism,
        //    an upgradeable implementation or an inducible callback could seize its own identity
        //    without the owner acting. A contract that wants to control its own identity should bind
        //    as `ACCOUNT`, which is step 1.
        //    The owner probe is a fail-closed STATICCALL, so a revert, a wrong-length response, dirty
        //    upper bits or a zero owner resolves to no owner and grants nobody. That is why
        //    `renounceOwnership()` permanently freezes a `CONTRACT_OWNABLE` identity: with no owner
        //    there is nobody left to authorize, and renouncing ownership means giving up control.
        //    Resolving live means a former owner's delegation stops conferring authority in the same
        //    transaction that ownership moves.
        //    The delegation check is contract-scoped rather than token-scoped. A contract binding
        //    pins `tokenId` to 0, where it exists only as an input to the counterfactual hash and
        //    never as a reference to a token. A token-scoped check would therefore test a delegation
        //    against something that does not exist, and for a bound contract that is also an NFT
        //    collection it would let a delegation covering token id 0 confer authority over the whole
        //    contract. `checkDelegateForContract` still cascades up to wallet-level delegations,
        //    which is the case this wants.
        //    This standard remains outside the single-owner token set, so it gets no
        //    ownerless-collection window.
        if (standard == TokenStandard.CONTRACT_OWNABLE) {
            address contractOwner = _currentContractOwner(boundAddress);
            if (contractOwner == address(0)) {
                return false;
            }
            if (account == contractOwner) {
                return true;
            }
            return _isOwnerDelegate(account, contractOwner, boundAddress);
        }

        // 3. `CONTRACT_ADMIN` suits an AccessControl contract that exposes no `owner()`. Authority
        //    belongs to holders of `DEFAULT_ADMIN_ROLE` and to nobody else, including the bound
        //    contract itself, for the same reason given at step 2. The role is read on every call, so
        //    revoking it removes authority immediately.
        //    This closes an asymmetry the contract already had. `_controlsAccount`, which gates the
        //    primary-agent surface, has always accepted a `DEFAULT_ADMIN_ROLE` holder, so an admin
        //    could set that contract's primary agent while being unable to manage an identity bound
        //    to it.
        //    It is deliberately not a member of the owner-and-delegate pattern at step 2 and step 4.
        //    Delegation there means resolving one owner and then asking the registry about that
        //    owner. A role is a membership predicate that many addresses can satisfy and none can
        //    enumerate, so there is no well-defined delegator to name. Direct authority only, by
        //    design rather than by omission.
        if (standard == TokenStandard.CONTRACT_ADMIN) {
            return _hasDefaultAdminRole(boundAddress, account);
        }

        // 4. Single-owner standards are the other three members of the owner-and-delegate pattern.
        //    Control means current token ownership, or a valid delegate.xyz delegation from the
        //    current owner. Direct ownership is checked first so current owners never incur a
        //    registry call.
        if (_isSingleOwnerStandard(standard)) {
            address owner = ISingleOwnerToken(boundAddress).ownerOf(tokenId);
            if (account == owner) {
                return true;
            }
            return _isERC721Delegate(account, owner, boundAddress, tokenId);
        }

        // 5. ERC-1155 control means any positive balance for the bound id.
        //    No delegate.xyz check: the no-vault API cannot soundly map a delegation to a holder.
        if (standard == TokenStandard.ERC1155) {
            return IERC1155(boundAddress).balanceOf(account, tokenId) > 0;
        }

        // 6. ERC-6909 control also means any positive balance for the bound id.
        //    No delegate.xyz check: v2 has no ERC-6909 token-id delegation primitive.
        return IERC6909(boundAddress).balanceOf(account, tokenId) > 0;
    }

    /// @dev The three standards that name a contract rather than a token within it. They share the
    /// canonical `tokenId == 0` coordinate and none of them is a single-owner token standard.
    function _isAccountStandard(TokenStandard standard) internal pure returns (bool) {
        return standard == TokenStandard.ACCOUNT || standard == TokenStandard.CONTRACT_OWNABLE
            || standard == TokenStandard.CONTRACT_ADMIN;
    }

    function _isSingleOwnerStandard(TokenStandard standard) internal pure returns (bool) {
        return
            standard == TokenStandard.ERC721 || standard == TokenStandard.ERC1155F || standard == TokenStandard.ERC6909F;
    }

    /// @dev Fail-closed EIP-173 owner probe for the opt-in `CONTRACT_OWNABLE` standard. The typed
    /// interface pins `owner()` as `view`, and the low-level `staticcall` makes that read-only at the
    /// EVM level. Only exactly one clean ABI address word is accepted. Returns the zero address when
    /// the contract reports no usable owner, which every caller must read as nobody rather than as an
    /// owner of zero. In particular the delegation check must never run with a zero delegator, since
    /// that would ask the registry about an account nobody controls.
    function _currentContractOwner(address boundAddress) private view returns (address) {
        (bool success, bytes memory result) = boundAddress.staticcall(abi.encodeCall(IOwnableContract.owner, ()));
        if (!success || result.length != 32) {
            return address(0);
        }

        uint256 ownerWord;
        assembly ("memory-safe") {
            ownerWord := mload(add(result, 0x20))
        }
        if (ownerWord >> 160 != 0) {
            return address(0);
        }

        return address(uint160(ownerWord));
    }

    /// @dev Consults the delegate.xyz v2 registry for a contract-scoped delegation from the bound
    /// contract's current `owner` to `account`. Fails closed in the same way as the token-scoped
    /// check: if the registry has no code on this chain, only direct authority applies.
    function _isOwnerDelegate(address account, address owner, address boundAddress) private view returns (bool) {
        if (DELEGATE_REGISTRY.code.length == 0) {
            return false;
        }

        return
            IDelegateRegistry(DELEGATE_REGISTRY).checkDelegateForContract(account, owner, boundAddress, DELEGATE_RIGHTS);
    }

    /// @dev Consults the immutable delegate.xyz v2 registry for an ERC-721 delegation from the current
    /// `owner` (the vault) to `account` (the hot wallet). `checkDelegateForERC721` already folds in
    /// token-level, contract-level, and all-wallet delegations, so no separate calls are needed.
    /// Fails closed: if the registry has no code on this chain, only direct ownership authorizes.
    function _isERC721Delegate(address account, address owner, address boundAddress, uint256 tokenId)
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
            account, owner, boundAddress, tokenId, DELEGATE_RIGHTS
        );
    }

    /// @dev Rejects any metadata entry targeting a reserved key, either the canonical binding record
    /// (`agent-binding`, which only this contract writes) or `cf-registration` (which nothing writes
    /// today). Used on every adapter write path that accepts a metadata array, meaning `register` and
    /// the counterfactual surface, so a caller cannot forge a binding record or a provenance claim.
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

    function _registrationHash(TokenStandard standard, address boundAddress, uint256 tokenId)
        internal
        view
        virtual
        returns (bytes32)
    {
        return _registrationHashFor(_interoperableAddress(address(this)), standard, boundAddress, tokenId);
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
    /// `keccak256(abi.encode(adapterInteroperableAddress, standard, boundAddress, tokenId, extraData))`,
    /// with `standard` encoded as the `TokenStandard` enum's `uint8`. Always `abi.encode`, never
    /// `abi.encodePacked`: the interoperable address is dynamic, and packing it would let a different
    /// (address, standard) pair produce the same preimage bytes.
    function _registrationHashFor(
        bytes memory adapterInteroperableAddress,
        TokenStandard standard,
        address boundAddress,
        uint256 tokenId
    ) internal pure returns (bytes32) {
        return keccak256(
            abi.encode(adapterInteroperableAddress, standard, boundAddress, tokenId, COUNTERFACTUAL_EXTRA_DATA)
        );
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
