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
import {IERC8217} from "./interfaces/IERC8217.sol";
import {IERC8004AdapterAttestation} from "./interfaces/IERC8004AdapterAttestation.sol";
import {IERC8004AdapterCounterfactual} from "./interfaces/IERC8004AdapterCounterfactual.sol";
import {IInteroperableAddressView} from "./interfaces/IInteroperableAddressView.sol";
import {IERC8004AdapterRegistration} from "./interfaces/IERC8004AdapterRegistration.sol";
import {IERC8004IdentityRecord} from "./interfaces/IERC8004IdentityRecord.sol";
import {IERC8004IdentityRegistry} from "./interfaces/IERC8004IdentityRegistry.sol";

interface ISingleOwnerToken {
    function ownerOf(uint256 tokenId) external view returns (address);
}

interface IOwnableContract {
    function owner() external view returns (address);
}

/// @notice Lets an external NFT, account, or contract control an ERC-8004 identity record while this
/// proxy remains the on-chain owner of the identity token.
/// @custom:version 0.0.17
contract Adapter8004 is
    Initializable,
    OwnableUpgradeable,
    UUPSUpgradeable,
    ReentrancyGuard,
    IERC721Receiver,
    IERC8217,
    IERC8004IdentityRecord,
    IERC8004AdapterRegistration,
    IERC8004AdapterCounterfactual,
    IInteroperableAddressView,
    IERC8004AdapterAttestation
{
    /// @notice The one reserved metadata key, rejected on every caller-metadata write path so callers cannot forge it.
    string public constant BINDING_METADATA_KEY = "agent-binding";
    bytes32 private constant BINDING_METADATA_KEY_HASH = keccak256(bytes(BINDING_METADATA_KEY));

    /// @notice Canonical immutable delegate.xyz v2 registry, identical on Ethereum, Base, and Sepolia.
    /// Delegation is accepted for ERC-721, ERC-1155F, ERC-6909F, CONTRACT_OWNABLE and ACCOUNT.
    address public constant DELEGATE_REGISTRY = 0x00000000000000447e69651d841bD8D104Bed493;

    /// @notice A scope used for delegating Adapter8004 management; delegate.xyz also honors unscoped grants.
    bytes32 public constant DELEGATE_RIGHTS = keccak256("adapter8004.manage");

    /// @notice Thrown for a zero bound address, or a codeless one under any standard but `ACCOUNT`.
    error InvalidBoundAddress();
    /// @notice Thrown when `ownerOf` succeeds but does not return exactly one canonical address word.
    error InvalidOwnerOfResponse(address boundAddress, uint256 tokenId);
    /// @notice Thrown when a binding names the ERC-8004 registry itself, which would leave the agent uncontrollable.
    error BoundAddressIsRegistry();
    /// @notice Thrown when an `ACCOUNT`, `CONTRACT_OWNABLE` or `CONTRACT_ADMIN` call passes a nonzero `tokenId`.
    error NonZeroTokenIdForAccount(address boundAddress, uint256 tokenId);
    error ReservedMetadataKey(string metadataKey);
    error NotController(address account, uint256 agentId);
    error InvalidChainId();
    error UnknownAgent(uint256 agentId);
    /// @notice Thrown when an upgrade target carries a different ERC-8004 registry than this implementation.
    error RegistryMismatch();

    event AgentBound(
        uint256 indexed agentId,
        Standard indexed standard,
        address indexed boundAddress,
        uint256 tokenId,
        address registeredBy
    );

    event AgentURISet(uint256 indexed agentId, string newURI, address indexed updatedBy);
    event MetadataSet(uint256 indexed agentId, string metadataKey, bytes metadataValue, address indexed updatedBy);
    event AgentWalletSet(uint256 indexed agentId, address indexed newWallet, address indexed updatedBy);
    event AgentWalletUnset(uint256 indexed agentId, address indexed updatedBy);

    /// @notice The ERC-8004 registry every adapter write forwards into, fixed at construction.
    /// @dev Immutable since `0.0.17`, when it moved out of storage; that is why slot 0 is now dead.
    IERC8004IdentityRegistry public immutable identityRegistry;

    /// @dev **SLOT 0 IS DEAD, NEVER REUSE IT.** It held `identityRegistry` until `0.0.17` made that
    /// field immutable, so every live proxy still holds a real registry address here and anything
    /// declared into this slot would read that address as its initial value. Never remove this
    /// placeholder and never declare state before it. See `docs/fixtures/adapter-v014-storage-layout.md`.
    uint256 private __deadRegistrySlot;

    mapping(uint256 agentId => Binding binding) private _bindings;

    /// @notice Bakes the ERC-8004 registry into this implementation and locks it there.
    /// @custom:oz-upgrades-unsafe-allow constructor state-variable-immutable
    constructor(address identityRegistry_) {
        if (identityRegistry_ == address(0)) {
            revert InvalidBoundAddress();
        }
        identityRegistry = IERC8004IdentityRegistry(identityRegistry_);
        _disableInitializers();
    }

    /// @notice Initializes a newly deployed proxy; do not call during an upgrade of an existing one.
    function initialize(address initialOwner) external initializer {
        __Ownable_init(initialOwner);
    }

    /// @notice Registers an ERC-8004 identity bound to `boundAddress`, with initial metadata entries.
    function register(
        Standard standard,
        address boundAddress,
        uint256 tokenId,
        string calldata agentURI,
        IERC8004IdentityRegistry.MetadataEntry[] memory metadata
    ) public nonReentrant returns (uint256 agentId) {
        return _register(standard, boundAddress, tokenId, agentURI, metadata);
    }

    /// @notice Registers an ERC-8004 identity bound to `boundAddress`, with no initial metadata.
    function register(Standard standard, address boundAddress, uint256 tokenId, string calldata agentURI)
        external
        nonReentrant
        returns (uint256 agentId)
    {
        return _register(standard, boundAddress, tokenId, agentURI, new IERC8004IdentityRegistry.MetadataEntry[](0));
    }

    function _register(
        Standard standard,
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

    /// @notice Writes metadata entries for one agent in the order given, each emitting its own `MetadataSet`.
    function setMetadataBatch(uint256 agentId, IERC8004IdentityRegistry.MetadataEntry[] calldata metadata)
        external
        nonReentrant
    {
        // 1. Confirm the caller currently controls the bound token.
        _requireController(agentId, msg.sender);

        // 2. Prevent callers from forging the canonical binding record.
        _requireNoReservedBindingKey(metadata);

        // 3. Replay each write through the registry, emitting inside the loop so events stay in log order.
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

    /// @inheritdoc IERC8217
    function bindingOf(uint256 agentId) external view returns (Binding memory) {
        return _knownBinding(agentId);
    }

    /// @dev Loads a binding, reverting on unknown ids. A zero `boundAddress` is the unbound sentinel.
    function _knownBinding(uint256 agentId) private view returns (Binding memory binding) {
        binding = _bindings[agentId];
        if (binding.boundAddress == address(0)) {
            revert UnknownAgent(agentId);
        }
    }

    /// @notice Returns true when `account` currently controls `agentId`, and false for an unknown agent.
    function isController(uint256 agentId, address account) external view returns (bool) {
        // 1. Load the binding that defines who controls this agent.
        Binding memory binding = _bindings[agentId];

        // 2. Unknown agents do not have a controller.
        if (binding.boundAddress == address(0)) {
            return false;
        }

        // 3. Resolve control under the binding's standard, against current ownership.
        return _hasBindingControl(binding, account);
    }

    /// @notice Accepts ERC-721 transfers, which the adapter must do to hold the ERC-8004 identity tokens it registers.
    function onERC721Received(address, address, uint256, bytes calldata) external pure returns (bytes4) {
        // 1. Return the standard receiver selector so safe ERC-721 transfers to the adapter succeed.
        return IERC721Receiver.onERC721Received.selector;
    }

    // -----------------------------------------------------------------
    // COUNTERFACTUAL FUNCTIONS
    // -----------------------------------------------------------------
    // An alternative to full ERC-8004 registration that costs far less gas: these functions emit an
    // event and nothing else, so a claim is a log rather than a registry write and a storage slot.
    // The caller still proves the same authority the on-chain surface requires, plus the
    // ownerless-collection route documented below.
    //
    // An agent gets an identity without ever being registered, because its UBID derives from the
    // binding alone and `hashBinding` will compute it for anyone. Consumers key on that UBID, and a
    // later event supersedes an earlier claim rather than withdrawing it.
    // -----------------------------------------------------------------

    /// @notice Convenience helper that derives a UBID from user supplied arguments.
    function hashBinding(Standard standard, address boundAddress, uint256 tokenId) external view returns (bytes32) {
        return _bindingHash(standard, boundAddress, tokenId);
    }

    /// @inheritdoc IERC8217
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

    /// @notice Claims an identity for a bound address without registering it, returning the UBID claimed.
    function counterfactualRegister(
        Standard standard,
        address boundAddress,
        uint256 tokenId,
        string calldata agentURI,
        IERC8004IdentityRegistry.MetadataEntry[] memory metadata
    ) public nonReentrant returns (bytes32 bindingHash) {
        return _counterfactualRegisterImpl(standard, boundAddress, tokenId, agentURI, metadata);
    }

    /// @notice Claims an identity for a bound address without registering it, with no metadata entries.
    function counterfactualRegister(Standard standard, address boundAddress, uint256 tokenId, string calldata agentURI)
        external
        nonReentrant
        returns (bytes32 bindingHash)
    {
        return _counterfactualRegisterImpl(
            standard, boundAddress, tokenId, agentURI, new IERC8004IdentityRegistry.MetadataEntry[](0)
        );
    }

    function _counterfactualRegisterImpl(
        Standard standard,
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

        // 4. Compute the deterministic UBID used as the indexer key for this claim.
        bindingHash = _bindingHash(standard, boundAddress, tokenId);

        // 5. Emit the counterfactual claim, which is the only on-chain record this function produces.
        emit CounterfactualAgentRegistered(bindingHash, boundAddress, tokenId, standard, agentURI, metadata, msg.sender);
    }

    /// @inheritdoc IERC8004AdapterCounterfactual
    function counterfactualSetAgentURI(Standard standard, address boundAddress, uint256 tokenId, string calldata newURI)
        external
        nonReentrant
        returns (bytes32 bindingHash)
    {
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
        Standard standard,
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
        Standard standard,
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
    function counterfactualSetAgentWallet(Standard standard, address boundAddress, uint256 tokenId, address newWallet)
        external
        nonReentrant
        returns (bytes32 bindingHash)
    {
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
    function counterfactualSetAgentWalletAndUBID(Standard standard, address boundAddress, uint256 tokenId)
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

        // 4. Point the caller's own wallet back at this identity and return the derived identifier.
        bindingHash = _setWalletUBID(standard, boundAddress, tokenId);
    }

    /// @inheritdoc IERC8004AdapterCounterfactual
    function counterfactualUnsetAgentWallet(Standard standard, address boundAddress, uint256 tokenId)
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
    //  Wallet UBID (reverse resolution: wallet -> UBID)
    // -----------------------------------------------------------------

    /// @inheritdoc IERC8004AdapterCounterfactual
    function setWalletUBID(Standard standard, address boundAddress, uint256 tokenId)
        external
        returns (bytes32 bindingHash)
    {
        return _setWalletUBID(standard, boundAddress, tokenId);
    }

    /// @inheritdoc IERC8004AdapterCounterfactual
    function clearWalletUBID() external {
        emit WalletUBIDCleared(msg.sender, msg.sender);
    }

    /// @dev Validates `standard`, `boundAddress` and `tokenId` before hashing them, so this cannot name
    /// an identity no real binding could match. The claim is always for the immediate caller.
    function _setWalletUBID(Standard standard, address boundAddress, uint256 tokenId)
        private
        returns (bytes32 bindingHash)
    {
        // 1. Reject an unusable bound address.
        _requireValidBoundAddress(standard, boundAddress);

        // 2. Reject a nonzero token id under the three account standards.
        _requireCanonicalTokenId(standard, boundAddress, tokenId);

        // 3. Derive the UBID these arguments name.
        bindingHash = _bindingHash(standard, boundAddress, tokenId);

        // 4. Emit the designation, which is the only record this function produces.
        emit WalletUBIDSet(msg.sender, bindingHash, boundAddress, tokenId, standard, msg.sender);
    }

    // -----------------------------------------------------------------
    //  ATTESTATIONS
    // -----------------------------------------------------------------
    // Emit-only statements about counterfactual identities. The caller is always the attester, so a
    // controller attests by having the account itself make the call. Nothing here calls out to
    // another contract, so none of these need `nonReentrant`.
    //
    // An attestation's identifier covers the attester, the identity, the type, the block number,
    // `variant` and `data`, so in practice it is unique. The one way to repeat it is for the same
    // attester to make a byte-identical statement twice in the same block. An attester that needs
    // every statement to carry its own identifier can change `variant` to force a different one.
    //
    // Each `AttestationType` has a number, and that number goes into the hash that identifies an
    // attestation. Changing it would give every attestation already made under that type a different
    // identifier. The rule is on the enum in `IERC8004AdapterAttestation`, and what each type means is
    // in `docs/specs/attestation-type-registry-v1.md`.
    // -----------------------------------------------------------------

    /// @inheritdoc IERC8004AdapterAttestation
    function attest(AttestationType attestationType, bytes32 ubid, bytes32 variant, bytes calldata data) external {
        _attest(attestationType, ubid, variant, data);
    }

    /// @inheritdoc IERC8004AdapterAttestation
    function confirmAdditionalAccount(bytes32 ubid) external {
        // `msg.data[0:0]` is the empty `bytes calldata`. It keeps `_attest` on calldata for the
        // generic path, where a REVIEW payload would otherwise be copied to memory for no reason.
        _attest(AttestationType.CONFIRM_ACCOUNT, ubid, bytes32(0), msg.data[0:0]);
    }

    /// @inheritdoc IERC8004AdapterAttestation
    function revoke(bytes32 attestationId) external {
        _revoke(attestationId);
    }

    /// @dev The single attest path. Both guards reject uninitialized calldata rather than validating:
    /// a nonzero but meaningless `ubid` passes on purpose, since attesting to an identity before its
    /// first claim is a supported use.
    function _attest(AttestationType attestationType, bytes32 ubid, bytes32 variant, bytes calldata data) private {
        // 1. Reject the two uninitialized-input sentinels, so a forgotten field fails loudly rather
        //    than recording a statement of no stated type or against the zero identity.
        if (attestationType == AttestationType.UNSPECIFIED) revert AttestationTypeZero();
        if (ubid == bytes32(0)) revert AttestationTargetZero();

        // 2. Derive the identifier. `block.number` separates identical statements made in different
        //    blocks, `variant` does the same within one block, and the interoperable address binds the
        //    identifier to this adapter on this chain.
        bytes32 attestationId = keccak256(
            abi.encode(
                _interoperableAddress(address(this)), msg.sender, ubid, attestationType, block.number, variant, data
            )
        );

        // 3. Emit, which is the only record this function produces. The identifier is carried so
        //    callers never have to recompute it.
        emit Attested(msg.sender, attestationType, ubid, attestationId, variant, data);
    }

    /// @dev Checks nothing, deliberately. Revoking an identifier that was never attested is a harmless
    /// no-op, and whether a revocation counts is decided by indexers, since this contract stores
    /// nothing that would let it match an identifier back to its attester.
    function _revoke(bytes32 attestationId) private {
        emit AttestationRevoked(attestationId, msg.sender);
    }
    /// @dev Fail-closed `DEFAULT_ADMIN_ROLE` probe. The answer is read as a raw word rather than
    /// decoded as a `bool`, because decoding reverts on anything outside 0 and 1 and would let a
    /// non-conforming contract break the check instead of failing it. Missing or wrong-length grants
    /// nobody.
    function _hasDefaultAdminRole(address target, address account) private view returns (bool) {
        (bool ok, bytes memory ret) =
            target.staticcall(abi.encodeWithSignature("hasRole(bytes32,address)", bytes32(0), account));
        return ok && ret.length == 32 && abi.decode(ret, (uint256)) != 0;
    }

    /// @dev Runs against the outgoing implementation, so it can inspect the incoming one first. The
    /// registry is immutable and therefore in each implementation's own code, which is what lets this
    /// read the incoming value at all.
    function _authorizeUpgrade(address newImplementation) internal view override onlyOwner {
        // 1. Restrict upgrades to the adapter owner, enforced by the modifier.
        // 2. Refuse any implementation that would move the proxy to a different ERC-8004 registry.
        if (Adapter8004(newImplementation).identityRegistry() != identityRegistry) {
            revert RegistryMismatch();
        }
    }

    /// @dev Code is required under every standard but `ACCOUNT`, which never calls the address it
    /// names, so a contract can bind itself from its own constructor. Zero is rejected everywhere,
    /// since `_bindings` uses it as the unbound sentinel, and the registry is rejected because binding
    /// it would lock the agent away from any controller.
    function _requireValidBoundAddress(Standard standard, address boundAddress) internal view {
        if (boundAddress == address(0)) {
            revert InvalidBoundAddress();
        }
        if (standard != Standard.ACCOUNT && boundAddress.code.length == 0) {
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

    function _requireBindingControl(Standard standard, address boundAddress, uint256 tokenId, address account)
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

    /// @dev Two ways to pass: current control under the binding's standard, or the collection itself
    /// calling directly while `ownerOf(tokenId)` reports no owner, a window that reopens after a burn.
    /// Both compare the adapter's immediate caller, so a router or forwarder acts as itself.
    function _requireTokenAuthority(Standard standard, address boundAddress, uint256 tokenId, address account)
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

    /// @dev The three account standards name an address rather than a token within it, so `tokenId`
    /// must be 0. A nonzero id reverts rather than being coerced, which would hand back a binding and
    /// a UBID that do not match what the caller submitted.
    function _requireCanonicalTokenId(Standard standard, address boundAddress, uint256 tokenId) internal pure {
        if (_isAccountStandard(standard) && tokenId != 0) {
            revert NonZeroTokenIdForAccount(boundAddress, tokenId);
        }
    }

    /// @dev Probes `ownerOf` without assuming a particular nonexistent-token revert. A revert or a
    /// zero owner means no owner; any other successful shape fails closed.
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

    function _hasBindingControl(Standard standard, address boundAddress, uint256 tokenId, address account)
        internal
        view
        returns (bool)
    {
        // 1. `ACCOUNT` names the address itself, so the adapter asks it nothing: no `ownerOf`, no
        //    balance, no role. Its own authority is permanent, since no token can change hands, and it
        //    can also grant a hot wallet a wallet-wide delegation, read live and revocable.
        if (standard == Standard.ACCOUNT) {
            if (account == boundAddress) {
                return true;
            }
            return _isAccountDelegate(account, boundAddress);
        }

        // 2. `CONTRACT_OWNABLE` accepts the live `owner()` or a delegate of that owner. A zero owner
        //    grants nobody, so `renounceOwnership()` freezes the identity for good. The delegation is
        //    contract-scoped, since a token-scoped one covering id 0 would cover the whole contract.
        if (standard == Standard.CONTRACT_OWNABLE) {
            address contractOwner = _currentContractOwner(boundAddress);
            if (contractOwner == address(0)) {
                return false;
            }
            if (account == contractOwner) {
                return true;
            }
            return _isOwnerDelegate(account, contractOwner, boundAddress);
        }

        // 3. `CONTRACT_ADMIN` suits an AccessControl contract with no `owner()`. Any holder of
        //    `DEFAULT_ADMIN_ROLE` qualifies, read live, so revoking the role removes authority at once.
        //    No delegation: many addresses can hold a role and none can be named as the delegator.
        if (standard == Standard.CONTRACT_ADMIN) {
            return _hasDefaultAdminRole(boundAddress, account);
        }

        // 4. Single-owner standards mean current ownership, or a delegation from the current owner.
        //    Ownership is checked first so owners never pay for a registry call, and a zero owner
        //    grants nobody, so the delegation check always names a real delegator.
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
        if (standard == Standard.ERC1155) {
            return IERC1155(boundAddress).balanceOf(account, tokenId) > 0;
        }

        // 6. ERC-6909 control also means any positive balance for the bound id.
        //    No delegate.xyz check: v2 has no ERC-6909 token-id delegation primitive.
        return IERC6909(boundAddress).balanceOf(account, tokenId) > 0;
    }

    /// @dev The three standards that name a contract rather than a token within it. They share the
    /// canonical `tokenId == 0` coordinate and none of them is a single-owner token standard.
    function _isAccountStandard(Standard standard) internal pure returns (bool) {
        return
            standard == Standard.ACCOUNT || standard == Standard.CONTRACT_OWNABLE || standard == Standard.CONTRACT_ADMIN;
    }

    function _isSingleOwnerStandard(Standard standard) internal pure returns (bool) {
        return standard == Standard.ERC721 || standard == Standard.ERC1155F || standard == Standard.ERC6909F;
    }

    /// @dev Fail-closed `owner()` probe. Only one clean address word is accepted; anything else
    /// returns the zero address, which every caller reads as nobody.
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

    /// @dev Wallet-wide delegation from `boundAddress`. `checkDelegateForAll` is the right check
    /// because an `ACCOUNT` binding names the address acting as itself, not assets it holds inside a
    /// contract. Fails closed to the bound address alone when the registry has no code.
    function _isAccountDelegate(address account, address boundAddress) private view returns (bool) {
        if (DELEGATE_REGISTRY.code.length == 0) {
            return false;
        }

        return IDelegateRegistry(DELEGATE_REGISTRY).checkDelegateForAll(account, boundAddress, DELEGATE_RIGHTS);
    }

    /// @dev Contract-scoped delegation from the bound contract's current `owner`. Fails closed to
    /// direct authority when the registry has no code.
    function _isOwnerDelegate(address account, address owner, address boundAddress) private view returns (bool) {
        if (DELEGATE_REGISTRY.code.length == 0) {
            return false;
        }

        return
            IDelegateRegistry(DELEGATE_REGISTRY).checkDelegateForContract(account, owner, boundAddress, DELEGATE_RIGHTS);
    }

    /// @dev Token-scoped delegation from the current owner. `checkDelegateForERC721` already covers
    /// token, contract and wallet-wide grants. Fails closed to direct ownership when the registry has
    /// no code.
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

    /// @dev Rejects any entry targeting `agent-binding`, so a caller cannot forge the record this
    /// contract writes itself. Runs on every path that accepts caller metadata.
    function _requireNoReservedBindingKey(IERC8004IdentityRegistry.MetadataEntry[] memory metadata) internal pure {
        uint256 length = metadata.length;
        for (uint256 i; i < length; ++i) {
            if (keccak256(bytes(metadata[i].metadataKey)) == BINDING_METADATA_KEY_HASH) {
                revert ReservedMetadataKey(metadata[i].metadataKey);
            }
        }
    }

    function _bindingHash(Standard standard, address boundAddress, uint256 tokenId)
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

    /// @dev ERC-7930 v1 encoding, delegated to OpenZeppelin's `InteroperableAddress`. That library is
    /// `draft-` prefixed and promises no encoding stability, so a submodule bump that changed it would
    /// give every identity a different hash; read `testOpenZeppelinEncodingIsFrozen` before bumping.
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

    /// @dev Always `abi.encode`, never `abi.encodePacked`: the interoperable address is dynamic, and
    /// packing it would let a different address and standard pair hash to the same value.
    function _bindingHashFrom(
        bytes memory adapterInteroperableAddress,
        Standard standard,
        address boundAddress,
        uint256 tokenId
    ) internal pure returns (bytes32) {
        return keccak256(abi.encode(adapterInteroperableAddress, standard, boundAddress, tokenId));
    }
}
