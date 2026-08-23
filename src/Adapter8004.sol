// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {IERC721Receiver} from "@openzeppelin/contracts/token/ERC721/IERC721Receiver.sol";
import {IERC1155} from "@openzeppelin/contracts/token/ERC1155/IERC1155.sol";
import {IERC6909} from "@openzeppelin/contracts/interfaces/IERC6909.sol";
import {InteroperableAddress} from "@openzeppelin/contracts/utils/draft-InteroperableAddress.sol";
import {ReentrancyGuard} from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import {Initializable} from "@openzeppelin/contracts-upgradeable/proxy/utils/Initializable.sol";
import {OwnableUpgradeable} from "@openzeppelin/contracts-upgradeable/access/OwnableUpgradeable.sol";
import {UUPSUpgradeable} from "@openzeppelin/contracts-upgradeable/proxy/utils/UUPSUpgradeable.sol";
import {IDelegateRegistry} from "./interfaces/IDelegateRegistry.sol";
import {IERCAgentBindings} from "./interfaces/IERCAgentBindings.sol";
import {IERC8004AdapterAttestation} from "./interfaces/IERC8004AdapterAttestation.sol";
import {IERC8004AdapterCounterfactual} from "./interfaces/IERC8004AdapterCounterfactual.sol";
import {IInteroperableAddressView} from "./interfaces/IInteroperableAddressView.sol";
import {IERC8004AdapterWalletUBI} from "./interfaces/IERC8004AdapterWalletUBI.sol";
import {IERC8004AdapterWalletAgentID} from "./interfaces/IERC8004AdapterWalletAgentID.sol";
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
/// @dev Regular storage runs from slot 1 to slot 3 and is append-only, with slot 0 dead and reserved
/// forever since `identityRegistry` became immutable, so a live proxy upgrades with empty
/// `upgradeToAndCall` data and no reinitializer. Counterfactual identities are keyed by
/// `keccak256(abi.encode(interoperableAddress(proxy), uint8 standard, boundAddress, tokenId))`, the
/// adapter address plus exactly the stored `Binding`, and a different preimage from the one live
/// proxies compute today, so upgrading one is a hard cutover for any indexer reading counterfactual
/// events, detailed in CHANGELOG.md. That envelope comes from OpenZeppelin's `draft-` prefixed
/// `InteroperableAddress`, which carries no encoding stability guarantee, so read
/// `testOpenZeppelinEncodingIsFrozen` before bumping the submodule.
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
    IInteroperableAddressView,
    IERC8004AdapterWalletAgentID,
    IERC8004AdapterWalletUBI,
    IERC8004AdapterAttestation
{
    /// @notice The one reserved metadata key, rejected on every write path that accepts caller
    /// metadata, because this contract writes it itself and an unreserved key would let a caller
    /// forge a record the adapter authors.
    /// @dev `cf-registration` was reserved here until `0.0.17` and deliberately is not any more: no
    /// path writes it so there is no authored record to forge, `bindingHashOf` derives an
    /// agent's identifier rather than storing it so it cannot be spoofed, and reserving one spelling
    /// stops nobody who can write `ubi` instead. Do not re-add it as a consistency fix.
    string public constant BINDING_METADATA_KEY = "agent-binding";
    bytes32 private constant BINDING_METADATA_KEY_HASH = keccak256(bytes(BINDING_METADATA_KEY));

    /// @notice Canonical immutable delegate.xyz v2 registry, identical on Ethereum, Base, and Sepolia.
    /// A delegated hot wallet authorized here can drive single-owner ERC-721/ERC-1155F/ERC-6909F
    /// bound agents while the token stays in cold storage. Authorization fails closed to direct
    /// ownership when the registry has no code.
    address public constant DELEGATE_REGISTRY = 0x00000000000000447e69651d841bD8D104Bed493;

    /// @notice Rights identifier a cold wallet delegates to scope a hot wallet to Adapter8004 management
    /// only. delegate.xyz v2 also accepts empty/full delegations when this nonzero rights value is checked.
    bytes32 public constant DELEGATE_RIGHTS = keccak256("adapter8004.manage");

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
    /// its UBI, and any pointer derived from it can never disagree with the id the
    /// caller submitted.
    error NonZeroTokenIdForAccount(address boundAddress, uint256 tokenId);
    error ReservedMetadataKey(string metadataKey);
    error NotController(address account, uint256 agentId);
    /// @notice Thrown when `setWalletAgentIDFor` / `clearWalletAgentIDFor` is called by an address that
    /// is neither the account itself, the account's `owner()` / `getOwner()`, nor a holder of its
    /// `DEFAULT_ADMIN_ROLE`.
    error NotAccountController(address account, address caller);
    /// @notice Thrown when a wallet agent id setter is passed `WALLET_AGENT_ID_UNSET` (all ones). That
    /// value is reserved as the "unset" sentinel: it complements to zero in storage and would be
    /// indistinguishable from a never-written entry. Clear via `clearWalletAgentID[For]` instead.
    error WalletAgentIDReserved(uint256 agentId);
    error WalletUBIReserved(bytes32 ubi);
    error InvalidChainId();
    error UnknownAgent(uint256 agentId);
    /// @notice Thrown when an upgrade target was constructed with a different ERC-8004 registry than
    /// the one this implementation carries. The registry is set once for the life of the proxy, so
    /// an upgrade that would move it is refused rather than silently repointing every future write.
    error RegistryMismatch();

    event AgentBound(
        uint256 indexed agentId,
        TokenStandard indexed standard,
        address indexed boundAddress,
        uint256 tokenId,
        address registeredBy
    );

    event AgentURISet(uint256 indexed agentId, string newURI, address indexed updatedBy);
    event MetadataSet(uint256 indexed agentId, string metadataKey, bytes metadataValue, address indexed updatedBy);
    event AgentWalletSet(uint256 indexed agentId, address indexed newWallet, address indexed updatedBy);
    event AgentWalletUnset(uint256 indexed agentId, address indexed updatedBy);

    /// @notice The ERC-8004 registry every adapter write forwards into, fixed at construction.
    /// @dev Immutable, so it lives in this implementation's own runtime code rather than in proxy
    /// storage. That is what lets `_authorizeUpgrade` read the incoming implementation's value
    /// directly and refuse an upgrade that would repoint the proxy. A storage variable could not be
    /// checked that way, because the same call on an implementation address reads its own uninitialized slot.
    IERC8004IdentityRegistry public immutable identityRegistry;

    /// @dev **SLOT 0 IS DEAD AND MUST NEVER BE REUSED.** It held `identityRegistry` until `0.0.17`
    /// and every live proxy has a real registry address written there. Making the field immutable
    /// freed the slot but not the bytes, so anything declared into it would read that address as its
    /// initial value. This placeholder exists solely to hold the slot down: regular storage begins
    /// at slot 1. Never remove it, never repurpose it, and never declare state before it.
    uint256 private __deadRegistrySlot;

    mapping(uint256 agentId => Binding binding) private _bindings;

    /// @notice Full-system unset sentinel. Agent id zero remains representable.
    uint256 public constant WALLET_AGENT_ID_UNSET = type(uint256).max;
    bytes32 public constant WALLET_UBI_UNSET = bytes32(type(uint256).max);

    /// @dev Reverse claims. These two mappings occupy regular slots 2 and 3, in the order declared
    /// here, and are append-only: never reorder, insert between them, or repurpose one. They begin
    /// empty on a proxy upgraded from the deployed baseline, which holds slots 0 and 1 only. Slot 0
    /// is the only reserved slot and it sits behind them, not ahead.
    mapping(address account => uint256 complementAgentId) private _walletAgentID;
    mapping(address account => bytes32 complementRegistrationHash) private _walletUBI;

    /// @notice Bakes the ERC-8004 registry into this implementation and locks it there.
    /// @dev Every implementation carries its own registry, so an upgrade that would move the proxy
    /// to a different one is refusable, which is what `_authorizeUpgrade` does. Deploying an
    /// implementation for an existing proxy therefore means passing that proxy's current registry.
    /// @custom:oz-upgrades-unsafe-allow constructor state-variable-immutable
    constructor(address identityRegistry_) {
        if (identityRegistry_ == address(0)) {
            revert InvalidBoundAddress();
        }
        identityRegistry = IERC8004IdentityRegistry(identityRegistry_);
        _disableInitializers();
    }

    /// @notice Initializes a newly deployed proxy.
    /// @dev Do not call during an upgrade of an existing proxy. The registry is no longer a
    /// parameter here, because it is fixed at construction. An active proxy already has its owner
    /// set and its bindings at slot 1, the two mappings at slots 2 and 3 are meant to begin empty,
    /// and there is no reinitializer, so an upgrade carries empty `upgradeToAndCall` data.
    function initialize(address initialOwner) external initializer {
        __Ownable_init(initialOwner);
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

        // 3. Reject user-supplied entries targeting the canonical binding record, which only this
        //    contract writes.
        _requireNoReservedBindingKey(metadata);

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

        // 2. Prevent callers from writing the canonical binding record, which only this contract
        //    writes, so a controller cannot forge it.
        if (keccak256(bytes(metadataKey)) == BINDING_METADATA_KEY_HASH) {
            revert ReservedMetadataKey(metadataKey);
        }

        // 3. Forward the metadata write into the ERC-8004 registry.
        identityRegistry.setMetadata(agentId, metadataKey, metadataValue);

        // 4. Emit the adapter-level metadata write after the forwarded registry call succeeds.
        emit MetadataSet(agentId, metadataKey, metadataValue, msg.sender);
    }

    /// @notice Write several metadata entries for one agent, in the order given. The caller must
    /// control the bound token, and no entry may target the reserved `agent-binding` key.
    /// @dev Each entry emits its own `MetadataSet`. There is no batch event, so a batch is
    /// indistinguishable from a run of individual writes.
    function setMetadataBatch(uint256 agentId, IERC8004IdentityRegistry.MetadataEntry[] calldata metadata)
        external
        nonReentrant
    {
        // 1. Confirm the caller currently controls the bound token.
        _requireController(agentId, msg.sender);

        // 2. Prevent callers from forging the canonical binding record.
        _requireNoReservedBindingKey(metadata);

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

    /// @notice Assign the agent wallet and point that wallet back at this agent in one call, closing
    /// a loop that otherwise takes two transactions by two parties. Authorization is exactly
    /// `setAgentWallet`'s: the caller proves control of the agent, and nothing is asked of the
    /// wallet, which already consented through the EIP-712 signature the registry verifies.
    /// @dev The `ID` suffix is the `uint256` agent id, where `counterfactualSetAgentWalletAndUBI`
    /// sets a `bytes32` UBI, so the two suffixes name the two kinds of identifier a wallet can hold.
    /// Verification is a read-time check that the forward and reverse records agree, so a reverse
    /// pointer written to an unwilling wallet produces no false positive and that wallet overwrites
    /// it with `setWalletAgentID`; it emits `AgentWalletSet` then `WalletAgentIDSet`, the same pair
    /// the separate calls emit, and overwrites any existing designation on `newWallet`.
    function setAgentWalletAndID(uint256 agentId, address newWallet, uint256 deadline, bytes calldata signature)
        external
        nonReentrant
    {
        // 1. Confirm the caller currently controls the bound token.
        _requireController(agentId, msg.sender);

        // 2. Forward the wallet assignment to ERC-8004, which enforces the wallet proof. A rejected
        //    signature reverts here, so the reverse pointer below is never written on its own.
        identityRegistry.setAgentWallet(agentId, newWallet, deadline, signature);

        // 3. Emit the adapter-level wallet assignment after the forwarded registry call succeeds.
        emit AgentWalletSet(agentId, newWallet, msg.sender);

        // 4. Point the wallet back at this agent, reusing the setter that carries the reserved-id
        //    guard and emits `WalletAgentIDSet`.
        _setWalletAgentID(newWallet, agentId);
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
        return _knownBinding(agentId);
    }

    /// @dev Loads a binding and rejects unknown agents, so every caller that needs a real binding
    /// agrees on what unknown means. A zero `boundAddress` is the unbound sentinel, which is why the
    /// zero address is refused at every write entry point.
    function _knownBinding(uint256 agentId) private view returns (Binding memory binding) {
        binding = _bindings[agentId];
        if (binding.boundAddress == address(0)) {
            revert UnknownAgent(agentId);
        }
    }

    /// @notice Whether `account` may act for `agentId` right now, the same check every adapter write
    /// performs.
    /// @dev Authority resolves live from the bound token on every call, so the answer can change in
    /// the same block a token transfers or a bound contract's `owner()` changes, and a consumer must
    /// treat it as uncacheable. `_hasBindingControl` carries the per-standard rules. A blanket
    /// delegate.xyz delegation, one naming no rights at all, is accepted, because the registry offers
    /// no way to ask for a scoped-only match.
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
    // Emit-only mirrors of the on-chain register surface, writing no adapter storage and making no
    // ERC-8004 registry calls, so a later event supersedes a claim rather than withdrawing it.
    // Authority matches the on-chain surface plus the ownerless-collection route documented below.
    // `IERC8004AdapterCounterfactual` states that consumers key on the UBI.
    // -----------------------------------------------------------------

    function bindingHashFor(TokenStandard standard, address boundAddress, uint256 tokenId)
        external
        view
        returns (bytes32)
    {
        return _bindingHash(standard, boundAddress, tokenId);
    }

    /// @inheritdoc IERCAgentBindings
    function bindingHashOf(uint256 agentId) external view returns (bytes32) {
        Binding memory binding = _knownBinding(agentId);
        return _bindingHash(binding.standard, binding.boundAddress, binding.tokenId);
    }

    /// @inheritdoc IInteroperableAddressView
    function interoperableAddress(address account) external view returns (bytes memory) {
        return _interoperableAddress(account);
    }

    /// @inheritdoc IInteroperableAddressView
    function chainIdentifier() external view returns (bytes memory) {
        return _chainIdentifier();
    }

    /// @inheritdoc IERC8004AdapterCounterfactual
    function counterfactualRegister(
        TokenStandard standard,
        address boundAddress,
        uint256 tokenId,
        string calldata agentURI,
        IERC8004IdentityRegistry.MetadataEntry[] memory metadata
    ) public nonReentrant returns (bytes32 bindingHash) {
        return _counterfactualRegisterImpl(standard, boundAddress, tokenId, agentURI, metadata);
    }

    /// @inheritdoc IERC8004AdapterCounterfactual
    function counterfactualRegister(
        TokenStandard standard,
        address boundAddress,
        uint256 tokenId,
        string calldata agentURI
    ) external nonReentrant returns (bytes32 bindingHash) {
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
    ) private returns (bytes32 bindingHash) {
        // 1. Reject an unusable bound address and reject the registry itself so the
        //    revert taxonomy matches `register`.
        _requireValidBoundAddress(standard, boundAddress);

        // 2. Confirm the caller is a current controller, or the directly calling single-owner token
        //    contract while `tokenId` has no current owner.
        _requireTokenAuthority(standard, boundAddress, tokenId, msg.sender);

        // 3. Reject user-supplied metadata entries that target reserved counterfactual records.
        _requireNoReservedBindingKey(metadata);

        // 4. Compute the deterministic UBI used as the indexer key for this claim.
        bindingHash = _bindingHash(standard, boundAddress, tokenId);

        // 5. Emit the counterfactual claim, which is the only on-chain record this function produces.
        emit CounterfactualAgentRegistered(bindingHash, boundAddress, tokenId, standard, agentURI, metadata, msg.sender);
    }

    /// @inheritdoc IERC8004AdapterCounterfactual
    function counterfactualSetAgentURI(
        TokenStandard standard,
        address boundAddress,
        uint256 tokenId,
        string calldata newURI
    ) external nonReentrant returns (bytes32 bindingHash) {
        // 1. Reject an unusable bound address and reject the registry itself so the
        //    revert taxonomy matches `register`.
        _requireValidBoundAddress(standard, boundAddress);

        // 2. Apply current-controller or ownerless collection authority.
        _requireTokenAuthority(standard, boundAddress, tokenId, msg.sender);

        // 3. Emit the URI update, which is the only on-chain record this function produces, and
        //    hand the identity back so the caller need not recompute it.
        bindingHash = _bindingHash(standard, boundAddress, tokenId);
        emit CounterfactualAgentURISet(bindingHash, boundAddress, tokenId, standard, newURI, msg.sender);
    }

    /// @inheritdoc IERC8004AdapterCounterfactual
    function counterfactualSetMetadata(
        TokenStandard standard,
        address boundAddress,
        uint256 tokenId,
        string calldata metadataKey,
        bytes calldata metadataValue
    ) external nonReentrant returns (bytes32 bindingHash) {
        // 1. Reject an unusable bound address and reject the registry itself so the
        //    revert taxonomy matches `register`.
        _requireValidBoundAddress(standard, boundAddress);

        // 2. Apply current-controller or ownerless collection authority.
        _requireTokenAuthority(standard, boundAddress, tokenId, msg.sender);

        // 3. Prevent callers from claiming reserved metadata slots in counterfactual events.
        if (keccak256(bytes(metadataKey)) == BINDING_METADATA_KEY_HASH) {
            revert ReservedMetadataKey(metadataKey);
        }

        // 4. Emit the metadata write, which is the only on-chain record this function produces, and
        //    hand the identity back so the caller need not recompute it.
        bindingHash = _bindingHash(standard, boundAddress, tokenId);
        emit CounterfactualMetadataSet(
            bindingHash, boundAddress, tokenId, standard, metadataKey, metadataValue, msg.sender
        );
    }

    /// @inheritdoc IERC8004AdapterCounterfactual
    function counterfactualSetMetadataBatch(
        TokenStandard standard,
        address boundAddress,
        uint256 tokenId,
        IERC8004IdentityRegistry.MetadataEntry[] calldata metadata
    ) external nonReentrant returns (bytes32 bindingHash) {
        // 1. Reject an unusable bound address and reject the registry itself so the
        //    revert taxonomy matches `register`.
        _requireValidBoundAddress(standard, boundAddress);

        // 2. Apply current-controller or ownerless collection authority.
        _requireTokenAuthority(standard, boundAddress, tokenId, msg.sender);

        // 3. Prevent callers from claiming reserved metadata slots in counterfactual events.
        _requireNoReservedBindingKey(metadata);

        // 4. Emit the batch, which is the only on-chain record this function produces, and hand the
        //    identity back so the caller need not recompute it. Every entry lands on this one
        //    identity, so one hash covers the whole batch.
        bindingHash = _bindingHash(standard, boundAddress, tokenId);
        emit CounterfactualMetadataBatchSet(bindingHash, boundAddress, tokenId, standard, metadata, msg.sender);
    }

    /// @inheritdoc IERC8004AdapterCounterfactual
    function counterfactualSetAgentWallet(
        TokenStandard standard,
        address boundAddress,
        uint256 tokenId,
        address newWallet
    ) external nonReentrant returns (bytes32 bindingHash) {
        // 1. Reject an unusable bound address and reject the registry itself so the
        //    revert taxonomy matches `register`.
        _requireValidBoundAddress(standard, boundAddress);

        // 2. Apply current-controller or ownerless collection authority.
        _requireTokenAuthority(standard, boundAddress, tokenId, msg.sender);

        // 3. Emit the wallet assignment, which is the only on-chain record this function produces,
        //    and hand the identity back so the caller need not recompute it.
        bindingHash = _bindingHash(standard, boundAddress, tokenId);
        emit CounterfactualAgentWalletSet(bindingHash, boundAddress, tokenId, standard, newWallet, msg.sender);
    }

    /// @inheritdoc IERC8004AdapterCounterfactual
    function counterfactualSetAgentWalletAndUBI(TokenStandard standard, address boundAddress, uint256 tokenId)
        external
        nonReentrant
        returns (bytes32 bindingHash)
    {
        // 1. Reject an unusable bound address and reject the registry itself so the
        //    revert taxonomy matches `register`.
        _requireValidBoundAddress(standard, boundAddress);

        // 2. Apply current-controller or ownerless collection authority.
        _requireTokenAuthority(standard, boundAddress, tokenId, msg.sender);

        // 3. Emit the wallet assignment, matching `counterfactualSetAgentWallet` exactly.
        emit CounterfactualAgentWalletSet(
            _bindingHash(standard, boundAddress, tokenId), boundAddress, tokenId, standard, msg.sender, msg.sender
        );

        // 4. Point the caller's wallet back at this identity, reusing the setter that carries the
        //    reserved-hash guard and emits `WalletUBISet`, and hand back the identity it
        //    derived so the caller does not recompute it.
        bindingHash = _setWalletUBI(msg.sender, standard, boundAddress, tokenId);
    }

    /// @inheritdoc IERC8004AdapterCounterfactual
    function counterfactualUnsetAgentWallet(TokenStandard standard, address boundAddress, uint256 tokenId)
        external
        nonReentrant
        returns (bytes32 bindingHash)
    {
        // 1. Reject an unusable bound address and reject the registry itself so the
        //    revert taxonomy matches `register`.
        _requireValidBoundAddress(standard, boundAddress);

        // 2. Apply current-controller or ownerless collection authority.
        _requireTokenAuthority(standard, boundAddress, tokenId, msg.sender);

        // 3. Emit the wallet clear, which is the only on-chain record this function produces, and
        //    hand the identity back so the caller need not recompute it.
        bindingHash = _bindingHash(standard, boundAddress, tokenId);
        emit CounterfactualAgentWalletUnset(bindingHash, boundAddress, tokenId, standard, msg.sender);
    }

    // -----------------------------------------------------------------
    //  Wallet agent id (reverse resolution: wallet -> registry agent id)
    // -----------------------------------------------------------------

    /// @notice Set the caller's own wallet agent id. The caller always controls itself, so no extra
    /// authorization is required. The id is strictly an ERC-8004 registry token id. To remove an id,
    /// call `clearWalletAgentID`; passing
    /// `WALLET_AGENT_ID_UNSET` (all ones) reverts `WalletAgentIDReserved` (it is the unset sentinel).
    function setWalletAgentID(uint256 agentId) external {
        _setWalletAgentID(msg.sender, agentId);
    }

    /// @notice Set the wallet agent id for `account`. Authorized when the caller is the account
    /// itself, the account's `owner()` / `getOwner()`, or a holder of its `DEFAULT_ADMIN_ROLE`. To
    /// remove an id, call `clearWalletAgentIDFor`. Reverts `WalletAgentIDReserved` for the all-ones id.
    function setWalletAgentIDFor(address account, uint256 agentId) external {
        if (!_controlsAccount(account, msg.sender)) revert NotAccountController(account, msg.sender);
        _setWalletAgentID(account, agentId);
    }

    /// @notice Clear the caller's own wallet agent id. Afterwards `walletAgentIDOf` returns
    /// `WALLET_AGENT_ID_UNSET`. Idempotent: clearing an already-unset account still emits
    /// `WalletAgentIDCleared`.
    function clearWalletAgentID() external {
        _clearWalletAgentID(msg.sender);
    }

    /// @notice Clear the wallet agent id for `account`, under the same authorization model as
    /// `setWalletAgentIDFor`. Reverts `NotAccountController` when the caller is not authorized.
    function clearWalletAgentIDFor(address account) external {
        if (!_controlsAccount(account, msg.sender)) revert NotAccountController(account, msg.sender);
        _clearWalletAgentID(account);
    }

    /// @notice Reverse-resolve a wallet to its agent id. Returns `WALLET_AGENT_ID_UNSET` (all
    /// ones) when the account has never set an id or has cleared it. Every real id, including agent
    /// id `0`, is returned as itself.
    function walletAgentIDOf(address account) external view returns (uint256) {
        uint256 stored = _walletAgentID[account];
        return stored == 0 ? WALLET_AGENT_ID_UNSET : ~stored;
    }

    function _setWalletAgentID(address account, uint256 agentId) private {
        if (agentId == type(uint256).max) revert WalletAgentIDReserved(agentId);
        _walletAgentID[account] = ~agentId;
        emit WalletAgentIDSet(account, agentId, msg.sender);
    }

    /// @dev Reset the account's complement slot to zero, which reads back as `WALLET_AGENT_ID_UNSET`,
    /// and emit `WalletAgentIDCleared`. `delete` restores the exact "unwritten == unset" invariant.
    function _clearWalletAgentID(address account) private {
        delete _walletAgentID[account];
        emit WalletAgentIDCleared(account, msg.sender);
    }

    // -----------------------------------------------------------------
    //  Wallet UBI (reverse resolution: wallet -> UBI)
    // -----------------------------------------------------------------

    function setWalletUBI(TokenStandard standard, address boundAddress, uint256 tokenId)
        external
        returns (bytes32 bindingHash)
    {
        return _setWalletUBI(msg.sender, standard, boundAddress, tokenId);
    }

    function setWalletUBIFor(address account, TokenStandard standard, address boundAddress, uint256 tokenId)
        external
        returns (bytes32 bindingHash)
    {
        if (!_controlsAccount(account, msg.sender)) revert NotAccountController(account, msg.sender);
        return _setWalletUBI(account, standard, boundAddress, tokenId);
    }

    function clearWalletUBI() external {
        _clearWalletUBI(msg.sender);
    }

    function clearWalletUBIFor(address account) external {
        if (!_controlsAccount(account, msg.sender)) revert NotAccountController(account, msg.sender);
        _clearWalletUBI(account);
    }

    function walletUBIOf(address account) external view returns (bytes32) {
        bytes32 stored = _walletUBI[account];
        return stored == bytes32(0) ? WALLET_UBI_UNSET : ~stored;
    }

    /// @dev Validates the coordinates before deriving from them, so this path cannot name an identity
    /// no forward claim could ever match. Authority is deliberately not checked, since a wallet
    /// pointing at an identity asserts nothing about that identity, but a coordinate the claim paths
    /// reject is one nothing can ever resolve to. Placed here rather than in the two entry points so
    /// a future caller stays covered.
    function _setWalletUBI(address account, TokenStandard standard, address boundAddress, uint256 tokenId)
        private
        returns (bytes32 bindingHash)
    {
        _requireValidBoundAddress(standard, boundAddress);
        _requireCanonicalTokenId(standard, boundAddress, tokenId);

        bindingHash = _bindingHash(standard, boundAddress, tokenId);
        if (bindingHash == bytes32(type(uint256).max)) {
            revert WalletUBIReserved(bindingHash);
        }
        _walletUBI[account] = ~bindingHash;
        emit WalletUBISet(account, bindingHash, boundAddress, tokenId, standard, msg.sender);
    }

    function _clearWalletUBI(address account) private {
        delete _walletUBI[account];
        emit WalletUBICleared(account, msg.sender);
    }

    // -----------------------------------------------------------------
    //  ATTESTATIONS
    // -----------------------------------------------------------------
    // Emit-only statements about counterfactual identities, so the layout still ends at slot 3. The
    // caller is always the attester, and a controller participates by causing the account itself to
    // call. These functions make no external call, so they carry no `nonReentrant`, and a test holds
    // them callable inside a guarded frame. `AttestationType` numbering is identity-critical because
    // the `uint8` sits in the identifier preimage, with the rule on the enum in
    // `IERC8004AdapterAttestation` and the semantics in
    // `docs/specs/attestation-type-registry-v1.md`.
    // -----------------------------------------------------------------

    /// @inheritdoc IERC8004AdapterAttestation
    function attest(AttestationType attestationType, bytes32 ubi, bytes32 variant, bytes calldata data) external {
        _attest(attestationType, ubi, variant, data);
    }

    /// @inheritdoc IERC8004AdapterAttestation
    function confirmAdditionalAccount(bytes32 ubi) external {
        // `msg.data[0:0]` is the empty `bytes calldata`. It keeps `_attest` on calldata for the
        // generic path, where a REVIEW payload would otherwise be copied to memory for no reason.
        _attest(AttestationType.CONFIRM_ACCOUNT, ubi, bytes32(0), msg.data[0:0]);
    }

    /// @inheritdoc IERC8004AdapterAttestation
    function revoke(bytes32 attestationId) external {
        _revoke(attestationId);
    }

    /// @dev The single attest path, so both guards live in exactly one place. Both are sentinel
    /// rules against default-initialized calldata, not validation: a nonzero garbage `ubi` passes on
    /// purpose, because attesting to an identity before its first counterfactual claim is emitted is
    /// a supported use and no set of "real" hashes exists to check against. Type validity needs no
    /// check at all now that the type is an enum, because the decoder enforces the range.
    function _attest(AttestationType attestationType, bytes32 ubi, bytes32 variant, bytes calldata data) private {
        // 1. Reject the two uninitialized-input sentinels, so a forgotten field fails loudly rather
        //    than recording a statement of no stated type or against the zero identity.
        if (attestationType == AttestationType.UNSPECIFIED) revert AttestationTypeZero();
        if (ubi == bytes32(0)) revert AttestationTargetZero();

        // 2. Derive the identifier. `block.number` keeps identical statements in different blocks
        //    distinct, so revoking one of a monitor's repeated pings erases that ping and leaves the
        //    rest of its history, and `variant` is the caller's opt-in within-block counterpart. The
        //    interoperable address binds the identifier to this adapter on this chain, exactly as
        //    the UBI binds.
        bytes32 attestationId = keccak256(
            abi.encode(
                _interoperableAddress(address(this)), msg.sender, ubi, attestationType, block.number, variant, data
            )
        );

        // 3. Emit, which is the only record this function produces. The identifier is carried so
        //    integrators never have to recompute it, and is derived rather than stored.
        emit Attested(msg.sender, attestationType, ubi, attestationId, variant, data);
    }

    /// @dev The single revoke path. It checks nothing, the zero identifier included, and that is a
    /// decision rather than an omission. An unset identifier field revokes a statement that was
    /// never made, which is a recorded no-op under projection rule three and harms nothing, whereas
    /// an unset type or target field would file a real statement in the wrong place. Whether a
    /// revocation counts at all is projection rule four, which an emit-only contract cannot check:
    /// it stores nothing that would let it invert an identifier back to its attester.
    function _revoke(bytes32 attestationId) private {
        emit AttestationRevoked(attestationId, msg.sender);
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

    /// @dev Fail-closed AccessControl probe for `DEFAULT_ADMIN_ROLE`, which is `bytes32(0)`, shared
    /// by the account-control check above and the `CONTRACT_ADMIN` standard so both agree on what
    /// holding the role means. The result is read as a raw word rather than decoded as a `bool`,
    /// because `abi.decode(ret, (bool))` reverts on a word outside `0` and `1` and would let a
    /// non-conforming contract break the check rather than fail it. Any non-zero word grants the
    /// role. A missing `hasRole`, or an answer of the wrong length, grants nobody.
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

    /// @dev `upgradeToAndCall` runs against the current implementation, so the outgoing one gets to
    /// inspect the incoming one before the switch. Because the registry is immutable it is baked
    /// into each implementation's runtime code, so calling the getter on the incoming address
    /// returns its own value rather than a proxy slot. That is what makes repointing refusable here.
    function _authorizeUpgrade(address newImplementation) internal view override onlyOwner {
        // 1. Restrict upgrades to the adapter owner, enforced by the modifier.
        // 2. Refuse any implementation that would move the proxy to a different ERC-8004 registry.
        if (Adapter8004(newImplementation).identityRegistry() != identityRegistry) {
            revert RegistryMismatch();
        }
    }

    /// @dev Validates the bound address. Runtime code is required under every standard except
    /// `ACCOUNT`, whose authority is the single comparison `account == boundAddress` and so never
    /// calls the address, which is what lets a contract bind itself as `ACCOUNT` from its own
    /// constructor. The zero address is rejected under every standard, because `_bindings` uses a
    /// zero `boundAddress` as its unbound sentinel. The identity registry is rejected because
    /// binding it would let `_hasBindingControl` resolve to the adapter post-bind and lock the agent
    /// away from any external controller.
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
        // 1. Load the binding, rejecting unknown agents before checking ownership state.
        Binding memory binding = _knownBinding(agentId);

        // 2. Revert when the caller no longer controls the bound token.
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
    /// the current-controller model, which for account-level bindings resolves the authority that
    /// standard defines, or temporary collection authority when the direct caller is the
    /// ERC-721/ERC-1155F/ERC-6909F token contract and `ownerOf(tokenId)` reports no current owner.
    /// That window reopens after a burn, since closing it would require historical-existence storage.
    /// Every mode compares the adapter's immediate EVM caller, so a router, forwarder or multicall
    /// that calls the adapter acts as itself. `delegatecall` into this contract is unsupported and
    /// dangerous, because it is a UUPS implementation with its own storage layout.
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

    /// @dev The three account-level standards name the address itself rather than a token within it,
    /// so each has exactly one canonical coordinate, `tokenId == 0`. Enforced in
    /// `_requireTokenAuthority`, which every write passes through, and again in
    /// `_requireBindingControl` so a future direct caller stays covered. A nonzero id reverts rather
    /// than being coerced, since coercion would hand the caller a binding and a UBI
    /// that do not match the id they submitted.
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
        // 1. An account-level binding names `boundAddress` itself, so the bound address is the sole
        //    controller and the adapter asks it nothing: `ownerOf` and both `balanceOf` shapes go
        //    unprobed, and `tokenId` is pinned to 0 at the choke points above. Whatever the address
        //    exposes, an `owner()`, a balance or a role, carries authority elsewhere rather than
        //    here, as do the adapter admin and any delegate.xyz delegate, which
        //    `testAccountGrantsNoDelegationRoute` pins. This authority is permanent, because there is
        //    no token whose ownership could change hands, so the bound address stays the controller
        //    of the agents it binds and its latest write to a mutable registry field wins. It sits
        //    outside `_isSingleOwnerStandard`, so it gets no ownerless-window probe.
        if (standard == TokenStandard.ACCOUNT) {
            return account == boundAddress;
        }

        // 2. `CONTRACT_OWNABLE` resolves the contract's live `owner()` and accepts that owner acting
        //    directly or a delegate of that owner, while the bound contract itself carries authority
        //    only under `ACCOUNT`. The owner probe is a fail-closed STATICCALL, so a revert, a
        //    wrong-length response, dirty upper bits or a zero owner grants nobody, which is why
        //    `renounceOwnership()` permanently freezes such an identity. Resolving live means a
        //    former owner's delegation stops conferring authority in the same transaction ownership
        //    moves. The delegation check is contract-scoped, because a contract binding pins
        //    `tokenId` to 0 and a token-scoped check would let a delegation covering token id 0
        //    confer authority over the whole contract.
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
        //    belongs to holders of `DEFAULT_ADMIN_ROLE`, read on every call, so revoking the role
        //    removes authority immediately. It matches `_controlsAccount`, which has always accepted
        //    an admin, closing an asymmetry where an admin could set a contract's wallet agent id but
        //    not manage an identity bound to it. Direct authority only: a role is a membership
        //    predicate that many addresses satisfy and none can enumerate, so there is no
        //    well-defined delegator for delegate.xyz to name.
        if (standard == TokenStandard.CONTRACT_ADMIN) {
            return _hasDefaultAdminRole(boundAddress, account);
        }

        // 4. Single-owner standards are the other three members of the owner-and-delegate pattern.
        //    Control means current token ownership, or a valid delegate.xyz delegation from the
        //    current owner. Direct ownership is checked first so current owners never incur a
        //    registry call. A zero owner short-circuits to nobody, matching `CONTRACT_OWNABLE`, so
        //    the delegation check always names a real delegator rather than resting on delegate.xyz
        //    refusing to record one from the zero address.
        if (_isSingleOwnerStandard(standard)) {
            address owner = ISingleOwnerToken(boundAddress).ownerOf(tokenId);
            if (owner == address(0)) {
                return false;
            }
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
    /// the contract reports no usable owner, which every caller reads as nobody, so the delegation
    /// check always runs with a real delegator.
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

    /// @dev Rejects any metadata entry targeting `agent-binding`, the canonical binding record that
    /// only this contract writes. Used on every adapter write path that accepts a metadata array,
    /// meaning `register`, `setMetadataBatch` and the counterfactual surface, so a caller cannot forge
    /// a record the adapter authors.
    function _requireNoReservedBindingKey(IERC8004IdentityRegistry.MetadataEntry[] memory metadata) internal pure {
        uint256 length = metadata.length;
        for (uint256 i; i < length; ++i) {
            if (keccak256(bytes(metadata[i].metadataKey)) == BINDING_METADATA_KEY_HASH) {
                revert ReservedMetadataKey(metadata[i].metadataKey);
            }
        }
    }

    function _bindingHash(TokenStandard standard, address boundAddress, uint256 tokenId)
        internal
        view
        virtual
        returns (bytes32)
    {
        return _bindingHashFrom(_interoperableAddress(address(this)), standard, boundAddress, tokenId);
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

    /// @dev ERC-7930 v1 encoding, delegated to OpenZeppelin's `InteroperableAddress`. The output is
    /// byte-identical to the encoders this contract carried before `0.0.17`, which are frozen as
    /// oracles in `test/Adapter8004.erc7930.t.sol`, and every published fixture vector is asserted
    /// against this path. The library's file is `draft-` prefixed and carries no encoding stability
    /// guarantee, so a submodule bump that changed it would re-key every identity; read the note on
    /// `testOpenZeppelinEncodingIsFrozen` first. The zero-chain-id rejection stays here because
    /// `block.chainid` never returns zero, so this contract refuses to mint an identity nothing could
    /// own.
    function _erc7930AddressFor(uint256 chainId, address account, bool includeAddress)
        private
        pure
        returns (bytes memory)
    {
        if (chainId == 0) revert InvalidChainId();
        return includeAddress
            ? InteroperableAddress.formatEvmV1(chainId, account)
            : InteroperableAddress.formatEvmV1(chainId);
    }

    /// @dev The canonical UBI is
    /// `keccak256(abi.encode(adapterInteroperableAddress, standard, boundAddress, tokenId))`, with
    /// `standard` encoded as the `TokenStandard` enum's `uint8`. Always `abi.encode`, never
    /// `abi.encodePacked`: the interoperable address is dynamic, and packing it would let a different
    /// (address, standard) pair produce the same preimage bytes.
    function _bindingHashFrom(
        bytes memory adapterInteroperableAddress,
        TokenStandard standard,
        address boundAddress,
        uint256 tokenId
    ) internal pure returns (bytes32) {
        return keccak256(abi.encode(adapterInteroperableAddress, standard, boundAddress, tokenId));
    }
}
