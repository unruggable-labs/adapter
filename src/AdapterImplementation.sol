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

/// @notice Lets a token holder, account, or contract controller manage an ERC-8004 identity.
/// The adapter proxy owns the identity token; the binding determines who can manage its record.
/// @custom:version 0.0.17
contract AdapterImplementation is
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
    /// @notice Metadata key reserved for the adapter's address. Callers cannot write this key.
    string public constant BINDING_METADATA_KEY = "agent-binding";
    bytes32 private constant BINDING_METADATA_KEY_HASH = keccak256(bytes(BINDING_METADATA_KEY));

    /// @notice The delegate.xyz v2 registry address used to check delegations.
    /// Delegation is accepted for ERC-721, ERC-1155F, ERC-6909F, CONTRACT_OWNABLE and ACCOUNT.
    address public constant DELEGATE_REGISTRY = 0x00000000000000447e69651d841bD8D104Bed493;

    /// @notice The delegation permission for managing adapter identities. Unscoped grants also qualify.
    bytes32 public constant DELEGATE_RIGHTS = keccak256("adapter8004.manage");

    /// @notice The bound address is zero, or has no deployed code under a standard other than `ACCOUNT`.
    error InvalidBoundAddress();
    /// @notice `ownerOf` returned data that is not a 32-byte word with its upper 12 bytes set to zero.
    error InvalidOwnerOfResponse(address boundAddress, uint256 tokenId);
    /// @notice The ERC-8004 registry cannot be used as the bound address.
    error BoundAddressIsRegistry();
    /// @notice `tokenId` must be zero for `ACCOUNT`, `CONTRACT_OWNABLE`, and `CONTRACT_ADMIN`.
    error NonZeroTokenIdForAccount(address boundAddress, uint256 tokenId);
    error ReservedMetadataKey(string metadataKey);
    error NotController(address account, uint256 agentId);
    error InvalidChainId();

    event AgentURISet(uint256 indexed agentId, string newURI, address indexed updatedBy);
    event MetadataSet(uint256 indexed agentId, string metadataKey, bytes metadataValue, address indexed updatedBy);
    event AgentWalletSet(uint256 indexed agentId, address indexed newWallet, address indexed updatedBy);
    event AgentWalletUnset(uint256 indexed agentId, address indexed updatedBy);

    /// @notice The ERC-8004 registry used for registered identities, set when this implementation is deployed.
    /// @dev Stored in implementation code, not proxy storage. Slot 0 remains reserved for older versions.
    IERC8004IdentityRegistry public immutable identityRegistry;

    /// @dev Reserve slot 0 because deployed proxies store the old registry address there.
    /// Do not remove or reuse this field, or insert storage fields before it. Doing so would change
    /// how existing proxy storage is read. See `docs/fixtures/adapter-v014-storage-layout.md`.
    uint256 private __deadRegistrySlot;

    mapping(uint256 agentId => Binding binding) private _bindings;

    /// @notice Sets this implementation's registry and disables initialization on the implementation itself.
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
        // 1. Reject zero and the registry address. Require deployed code except for ACCOUNT.
        _requireValidBoundAddress(standard, boundAddress);

        // 2. Require the caller to be authorized under the selected binding standard.
        //    Exception: for ERC721, ERC1155F, or ERC6909F, allow the bound token contract
        //    itself to call when ownerOf(tokenId) reverts or returns address(0).
        _requireTokenAuthority(standard, boundAddress, tokenId, msg.sender);

        // 3. Reject metadata entries using the reserved agent-binding key.
        _requireNoReservedBindingKey(metadata);

        // 4. Register the identity with the adapter as its owner.
        //    Use the simpler registry overload when there are no metadata entries.
        if (metadata.length == 0) {
            agentId = identityRegistry.register(agentURI);
        } else {
            agentId = identityRegistry.register(agentURI, metadata);
        }

        // 5. Store the standard, bound address, and token ID for this agent.
        _bindings[agentId] = Binding({standard: standard, boundAddress: boundAddress, tokenId: tokenId});

        // 6. Store the adapter's 20-byte address under agent-binding, as required by ERC-8217.
        identityRegistry.setMetadata(agentId, BINDING_METADATA_KEY, abi.encodePacked(address(this)));

        // 7. Clear the default ERC-8004 wallet because registration set it to the adapter.
        identityRegistry.unsetAgentWallet(agentId);

        // 8. Emit the binding details for indexers.
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
        // 1. Revert if the agent is unknown or the caller does not control its binding.
        _requireController(agentId, msg.sender);

        // 2. Update the URI in the registry.
        identityRegistry.setAgentURI(agentId, newURI);

        // 3. Emit the successful URI update and its caller.
        emit AgentURISet(agentId, newURI, msg.sender);
    }

    function setMetadata(uint256 agentId, string memory metadataKey, bytes memory metadataValue)
        external
        nonReentrant
    {
        // 1. Revert if the agent is unknown or the caller does not control its binding.
        _requireController(agentId, msg.sender);

        // 2. Reject the reserved agent-binding key.
        if (keccak256(bytes(metadataKey)) == BINDING_METADATA_KEY_HASH) {
            revert ReservedMetadataKey(metadataKey);
        }

        // 3. Update the metadata in the registry.
        identityRegistry.setMetadata(agentId, metadataKey, metadataValue);

        // 4. Emit the successful metadata update and its caller.
        emit MetadataSet(agentId, metadataKey, metadataValue, msg.sender);
    }

    /// @notice Writes metadata entries in order and emits `MetadataSet` for each entry.
    function setMetadataBatch(uint256 agentId, IERC8004IdentityRegistry.MetadataEntry[] calldata metadata)
        external
        nonReentrant
    {
        // 1. Revert if the agent is unknown or the caller does not control its binding.
        _requireController(agentId, msg.sender);

        // 2. Reject any entry using the reserved agent-binding key.
        _requireNoReservedBindingKey(metadata);

        // 3. Write each entry to the registry and emit its update before processing the next entry.
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
        // 1. Revert if the agent is unknown or the caller does not control its binding.
        _requireController(agentId, msg.sender);

        // 2. Ask the registry to verify the wallet signature and set the wallet.
        identityRegistry.setAgentWallet(agentId, newWallet, deadline, signature);

        // 3. Emit the successful wallet assignment and its caller.
        emit AgentWalletSet(agentId, newWallet, msg.sender);
    }

    function unsetAgentWallet(uint256 agentId) external nonReentrant {
        // 1. Revert if the agent is unknown or the caller does not control its binding.
        _requireController(agentId, msg.sender);

        // 2. Clear the wallet in the registry.
        identityRegistry.unsetAgentWallet(agentId);

        // 3. Emit the successful wallet clear and its caller.
        emit AgentWalletUnset(agentId, msg.sender);
    }

    /// @inheritdoc IERC8217
    function bindingOf(uint256 agentId) external view returns (Binding memory) {
        return _knownBinding(agentId);
    }

    /// @dev Returns the stored binding. Reverts with UnknownAgent if its bound address is zero.
    function _knownBinding(uint256 agentId) private view returns (Binding memory binding) {
        binding = _bindings[agentId];
        if (binding.boundAddress == address(0)) {
            revert UnknownAgent(agentId);
        }
    }

    /// @notice Returns whether `account` currently controls `agentId`. Returns false for an unknown agent.
    /// @dev External ownership, balance, or delegation checks can revert; this is not guaranteed to return a bool.
    function isController(uint256 agentId, address account) external view returns (bool) {
        // 1. Load the binding that defines who controls this agent.
        Binding memory binding = _bindings[agentId];

        // 2. Unknown agents do not have a controller.
        if (binding.boundAddress == address(0)) {
            return false;
        }

        // 3. Check the account's current authority under the binding's standard.
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
    // These functions record identity claims and updates in events. They do not register an
    // ERC-8004 agent or store a binding. They use the same authority checks as register.
    //
    // The UBID identifies the claim without requiring registration. Indexers use it to group events
    // and apply later updates to the same identity.
    // -----------------------------------------------------------------

    /// @notice Computes a UBID from the supplied binding fields without validating them or checking authority.
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
        // 1. Reject zero and the registry address. Require deployed code except for ACCOUNT.
        _requireValidBoundAddress(standard, boundAddress);

        // 2. Require the caller to be authorized under the selected binding standard.
        //    Exception: for ERC721, ERC1155F, or ERC6909F, allow the bound token contract
        //    itself to call when ownerOf(tokenId) reverts or returns address(0).
        _requireTokenAuthority(standard, boundAddress, tokenId, msg.sender);

        // 3. Reject metadata entries using the reserved agent-binding key.
        _requireNoReservedBindingKey(metadata);

        // 4. Compute the claim's UBID.
        bindingHash = _bindingHash(standard, boundAddress, tokenId);

        // 5. Emit the claim without writing to storage or the registry.
        emit CounterfactualAgentRegistered(bindingHash, boundAddress, tokenId, standard, agentURI, metadata, msg.sender);
    }

    /// @inheritdoc IERC8004AdapterCounterfactual
    function counterfactualSetAgentURI(Standard standard, address boundAddress, uint256 tokenId, string calldata newURI)
        external
        nonReentrant
        returns (bytes32 bindingHash)
    {
        // 1. Reject zero and the registry address. Require deployed code except for ACCOUNT.
        _requireValidBoundAddress(standard, boundAddress);

        // 2. Require the caller to be authorized under the selected binding standard.
        //    Exception: for ERC721, ERC1155F, or ERC6909F, allow the bound token contract
        //    itself to call when ownerOf(tokenId) reverts or returns address(0).
        _requireTokenAuthority(standard, boundAddress, tokenId, msg.sender);

        // 3. Compute the UBID to return and emit the URI update.
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
        // 1. Reject zero and the registry address. Require deployed code except for ACCOUNT.
        _requireValidBoundAddress(standard, boundAddress);

        // 2. Require the caller to be authorized under the selected binding standard.
        //    Exception: for ERC721, ERC1155F, or ERC6909F, allow the bound token contract
        //    itself to call when ownerOf(tokenId) reverts or returns address(0).
        _requireTokenAuthority(standard, boundAddress, tokenId, msg.sender);

        // 3. Reject the reserved agent-binding key in caller-supplied metadata.
        if (keccak256(bytes(metadataKey)) == BINDING_METADATA_KEY_HASH) {
            revert ReservedMetadataKey(metadataKey);
        }

        // 4. Compute the UBID to return and emit the metadata update.
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
        // 1. Reject zero and the registry address. Require deployed code except for ACCOUNT.
        _requireValidBoundAddress(standard, boundAddress);

        // 2. Require the caller to be authorized under the selected binding standard.
        //    Exception: for ERC721, ERC1155F, or ERC6909F, allow the bound token contract
        //    itself to call when ownerOf(tokenId) reverts or returns address(0).
        _requireTokenAuthority(standard, boundAddress, tokenId, msg.sender);

        // 3. Reject the reserved agent-binding key in caller-supplied metadata.
        _requireNoReservedBindingKey(metadata);

        // 4. Compute the UBID to return and emit all entries in one event for that identity.
        bindingHash = _bindingHash(standard, boundAddress, tokenId);
        emit CounterfactualMetadataBatchSet(bindingHash, boundAddress, tokenId, standard, metadata, msg.sender);
    }

    /// @inheritdoc IERC8004AdapterCounterfactual
    function counterfactualSetAgentWallet(Standard standard, address boundAddress, uint256 tokenId, address newWallet)
        external
        nonReentrant
        returns (bytes32 bindingHash)
    {
        // 1. Reject zero and the registry address. Require deployed code except for ACCOUNT.
        _requireValidBoundAddress(standard, boundAddress);

        // 2. Require the caller to be authorized under the selected binding standard.
        //    Exception: for ERC721, ERC1155F, or ERC6909F, allow the bound token contract
        //    itself to call when ownerOf(tokenId) reverts or returns address(0).
        _requireTokenAuthority(standard, boundAddress, tokenId, msg.sender);

        // 3. Compute the UBID to return and emit the wallet assignment. No wallet signature is checked here.
        bindingHash = _bindingHash(standard, boundAddress, tokenId);
        emit CounterfactualAgentWalletSet(bindingHash, boundAddress, tokenId, standard, newWallet, msg.sender);
    }

    /// @inheritdoc IERC8004AdapterCounterfactual
    function counterfactualSetAgentWalletAndUBID(Standard standard, address boundAddress, uint256 tokenId)
        external
        nonReentrant
        returns (bytes32 bindingHash)
    {
        // 1. Reject zero and the registry address. Require deployed code except for ACCOUNT.
        _requireValidBoundAddress(standard, boundAddress);

        // 2. Require the caller to be authorized under the selected binding standard.
        //    Exception: for ERC721, ERC1155F, or ERC6909F, allow the bound token contract
        //    itself to call when ownerOf(tokenId) reverts or returns address(0).
        _requireTokenAuthority(standard, boundAddress, tokenId, msg.sender);

        // 3. Emit the caller as this identity's wallet.
        emit CounterfactualAgentWalletSet(
            _bindingHash(standard, boundAddress, tokenId), boundAddress, tokenId, standard, msg.sender, msg.sender
        );

        // 4. Emit the caller's reverse claim to this UBID and return the UBID.
        bindingHash = _setWalletUBID(standard, boundAddress, tokenId);
    }

    /// @inheritdoc IERC8004AdapterCounterfactual
    function counterfactualUnsetAgentWallet(Standard standard, address boundAddress, uint256 tokenId)
        external
        nonReentrant
        returns (bytes32 bindingHash)
    {
        // 1. Reject zero and the registry address. Require deployed code except for ACCOUNT.
        _requireValidBoundAddress(standard, boundAddress);

        // 2. Require the caller to be authorized under the selected binding standard.
        //    Exception: for ERC721, ERC1155F, or ERC6909F, allow the bound token contract
        //    itself to call when ownerOf(tokenId) reverts or returns address(0).
        _requireTokenAuthority(standard, boundAddress, tokenId, msg.sender);

        // 3. Compute the UBID to return and emit the wallet clear.
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

    /// @dev Validates the binding address and token ID, then emits the caller's wallet-to-UBID claim.
    /// Does not require the caller to control the identity, or require the identity to be registered.
    function _setWalletUBID(Standard standard, address boundAddress, uint256 tokenId)
        private
        returns (bytes32 bindingHash)
    {
        // 1. Reject zero and the registry address. Require deployed code except for ACCOUNT.
        _requireValidBoundAddress(standard, boundAddress);

        // 2. Revert if tokenId is not 0 for ACCOUNT, CONTRACT_OWNABLE, or CONTRACT_ADMIN.
        _requireCanonicalTokenId(standard, boundAddress, tokenId);

        // 3. Compute the UBID from the binding fields.
        bindingHash = _bindingHash(standard, boundAddress, tokenId);

        // 4. Emit the caller's claim. No wallet mapping is stored.
        emit WalletUBIDSet(msg.sender, bindingHash, boundAddress, tokenId, standard, msg.sender);
    }

    // -----------------------------------------------------------------
    //  ATTESTATIONS
    // -----------------------------------------------------------------
    // Attestations and revocations are recorded only in events. The immediate caller is the attester;
    // a smart wallet must make the call itself to attest under its own address. These functions make
    // no external calls and do not use nonReentrant.
    //
    // Identical attestations from the same caller in the same block have the same ID. Change variant
    // to give repeated statements different IDs. A different block number also changes the ID.
    //
    // Attestation type numbers are part of the ID hash. Do not renumber existing types.
    // See IERC8004AdapterAttestation and docs/specs/attestation-type-registry-v1.md.
    // -----------------------------------------------------------------

    /// @inheritdoc IERC8004AdapterAttestation
    function attest(AttestationType attestationType, bytes32 ubid, bytes32 variant, bytes calldata data) external {
        _attest(attestationType, ubid, variant, data);
    }

    /// @inheritdoc IERC8004AdapterAttestation
    function confirmAdditionalAccount(bytes32 ubid) external {
        // Pass an empty calldata slice so _attest can accept data without a memory copy.
        _attest(AttestationType.CONFIRM_ACCOUNT, ubid, bytes32(0), msg.data[0:0]);
    }

    /// @inheritdoc IERC8004AdapterAttestation
    function revoke(bytes32 attestationId) external {
        _revoke(attestationId);
    }

    /// @dev Emits an attestation from the caller. Rejects type UNSPECIFIED and UBID zero.
    /// Any other UBID is accepted, even if it has never been claimed or registered.
    function _attest(AttestationType attestationType, bytes32 ubid, bytes32 variant, bytes calldata data) private {
        // 1. Reject an unspecified type or a zero UBID.
        if (attestationType == AttestationType.UNSPECIFIED) revert AttestationTypeZero();
        if (ubid == bytes32(0)) revert AttestationTargetZero();

        // 2. Hash the adapter address and chain, caller, UBID, type, block number, variant, and data.
        bytes32 attestationId = keccak256(
            abi.encode(
                _interoperableAddress(address(this)), msg.sender, ubid, attestationType, block.number, variant, data
            )
        );

        // 3. Emit the attestation and its ID. No attestation is stored.
        emit Attested(msg.sender, attestationType, ubid, attestationId, variant, data);
    }

    /// @dev Emits a revocation request without checking the ID. Indexers must verify that the caller
    /// made the original attestation and ignore requests for unknown IDs or another attester's IDs.
    function _revoke(bytes32 attestationId) private {
        emit AttestationRevoked(attestationId, msg.sender);
    }

    /// @dev Returns whether target reports that account holds DEFAULT_ADMIN_ROLE (role zero).
    /// Accepts only a successful 32-byte response equal to 1. Other values and failed calls return false.
    /// Decode as an integer so invalid boolean values do not cause a decoding revert.
    function _hasDefaultAdminRole(address target, address account) private view returns (bool) {
        (bool ok, bytes memory ret) =
            target.staticcall(abi.encodeWithSignature("hasRole(bytes32,address)", bytes32(0), account));
        return ok && ret.length == 32 && abi.decode(ret, (uint256)) == 1;
    }

    /// @dev Only the adapter owner can authorize an upgrade. This function does not check the new registry.
    /// Operators must keep identityRegistry unchanged: a different registry can reuse agent IDs and
    /// cause _register to overwrite existing bindings. Add protection against those overwrites before
    /// allowing a registry change. See audit finding G2-01.
    function _authorizeUpgrade(address newImplementation) internal view override onlyOwner {}

    /// @dev Rejects zero and the registry address. All standards except ACCOUNT require deployed code.
    /// ACCOUNT does not call boundAddress, so it also accepts EOAs and contracts still in construction.
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
        // 1. Load the binding or revert with UnknownAgent.
        Binding memory binding = _knownBinding(agentId);

        // 2. Revert unless account currently controls this binding.
        if (!_hasBindingControl(binding, account)) {
            revert NotController(account, agentId);
        }
    }

    function _requireBindingControl(Standard standard, address boundAddress, uint256 tokenId, address account)
        internal
        view
    {
        // 1. Revert if tokenId is not 0 for ACCOUNT, CONTRACT_OWNABLE, or CONTRACT_ADMIN.
        _requireCanonicalTokenId(standard, boundAddress, tokenId);

        // 2. Revert unless account controls the binding. Use max uint256 because no agent ID is supplied.
        if (!_hasBindingControl(standard, boundAddress, tokenId, account)) {
            revert NotController(account, type(uint256).max);
        }
    }

    /// @dev Requires `account` to control the binding, or to be the token contract itself when a
    /// single-owner token has no current owner. Callers pass the adapter's `msg.sender` as `account`.
    function _requireTokenAuthority(Standard standard, address boundAddress, uint256 tokenId, address account)
        internal
        view
    {
        // 1. Revert if tokenId is not 0 for ACCOUNT, CONTRACT_OWNABLE, or CONTRACT_ADMIN.
        _requireCanonicalTokenId(standard, boundAddress, tokenId);

        // 2. Allow the token contract itself to act for an ERC721, ERC1155F, or ERC6909F token
        //    when ownerOf(tokenId) reverts or returns address(0), including after a burn.
        if (account == boundAddress && _isSingleOwnerStandard(standard) && _hasNoCurrentOwner(boundAddress, tokenId)) {
            return;
        }

        // 3. Otherwise, revert unless account controls the binding under the selected standard.
        _requireBindingControl(standard, boundAddress, tokenId, account);
    }

    /// @dev Requires tokenId zero for ACCOUNT, CONTRACT_OWNABLE, and CONTRACT_ADMIN.
    /// These standards identify the address itself, not a token. Other standards allow any token ID.
    function _requireCanonicalTokenId(Standard standard, address boundAddress, uint256 tokenId) internal pure {
        if (_isAccountStandard(standard) && tokenId != 0) {
            revert NonZeroTokenIdForAccount(boundAddress, tokenId);
        }
    }

    /// @dev Returns true if ownerOf reverts or returns address(0), and false for a valid nonzero owner.
    /// Reverts if a successful response is not exactly 32 bytes or has nonzero bits above the address.
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
        // 1. ACCOUNT: allow the bound address itself or its current wallet-wide delegate.
        //    Do not call ownerOf, owner, balanceOf, or hasRole on the bound address.
        if (standard == Standard.ACCOUNT) {
            if (account == boundAddress) {
                return true;
            }
            return _isAccountDelegate(account, boundAddress);
        }

        // 2. CONTRACT_OWNABLE: allow the current owner or its delegate for this contract.
        //    A zero or invalid owner response grants nobody authority. Contract-self calls get no special access.
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

        // 3. CONTRACT_ADMIN: require current membership in DEFAULT_ADMIN_ROLE.
        //    Do not check delegation or grant special access to the bound contract itself.
        if (standard == Standard.CONTRACT_ADMIN) {
            return _hasDefaultAdminRole(boundAddress, account);
        }

        // 4. ERC721, ERC1155F, ERC6909F: allow the current owner or its delegate for this token.
        //    A zero owner grants nobody authority. A reverted ownerOf call also reverts this check.
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

        // 5. ERC1155: require a positive balance of this token ID. No delegation is checked.
        if (standard == Standard.ERC1155) {
            return IERC1155(boundAddress).balanceOf(account, tokenId) > 0;
        }

        // 6. ERC6909: require a positive balance of this token ID. No delegation is checked.
        return IERC6909(boundAddress).balanceOf(account, tokenId) > 0;
    }

    /// @dev Returns true for ACCOUNT, CONTRACT_OWNABLE, and CONTRACT_ADMIN, which require tokenId zero.
    function _isAccountStandard(Standard standard) internal pure returns (bool) {
        return
            standard == Standard.ACCOUNT || standard == Standard.CONTRACT_OWNABLE || standard == Standard.CONTRACT_ADMIN;
    }

    /// @dev Returns true for ERC721, ERC1155F, and ERC6909F, which use ownerOf to find a token's owner.
    function _isSingleOwnerStandard(Standard standard) internal pure returns (bool) {
        return standard == Standard.ERC721 || standard == Standard.ERC1155F || standard == Standard.ERC6909F;
    }

    /// @dev Returns owner() if the response is a 32-byte word with its upper 12 bytes set to zero.
    /// Returns address(0) if the call fails or the response is malformed; this grants nobody authority.
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

    /// @dev Checks whether boundAddress granted account wallet-wide delegation for DELEGATE_RIGHTS.
    /// Unscoped grants also qualify. Returns false if the delegation registry has no code.
    function _isAccountDelegate(address account, address boundAddress) private view returns (bool) {
        if (DELEGATE_REGISTRY.code.length == 0) {
            return false;
        }

        return IDelegateRegistry(DELEGATE_REGISTRY).checkDelegateForAll(account, boundAddress, DELEGATE_RIGHTS);
    }

    /// @dev Checks whether owner delegated this contract to account. Contract-wide and wallet-wide
    /// grants qualify for DELEGATE_RIGHTS or unscoped rights. Returns false if the registry has no code.
    function _isOwnerDelegate(address account, address owner, address boundAddress) private view returns (bool) {
        if (DELEGATE_REGISTRY.code.length == 0) {
            return false;
        }

        return
            IDelegateRegistry(DELEGATE_REGISTRY).checkDelegateForContract(account, owner, boundAddress, DELEGATE_RIGHTS);
    }

    /// @dev Checks whether owner delegated this token to account. Token, contract, and wallet-wide
    /// grants qualify for DELEGATE_RIGHTS or unscoped rights.
    function _isERC721Delegate(address account, address owner, address boundAddress, uint256 tokenId)
        internal
        view
        returns (bool)
    {
        // 1. Return false if the delegation registry has no deployed code.
        if (DELEGATE_REGISTRY.code.length == 0) {
            return false;
        }

        // 2. Ask the registry whether the delegation covers this token and DELEGATE_RIGHTS.
        return IDelegateRegistry(DELEGATE_REGISTRY).checkDelegateForERC721(
            account, owner, boundAddress, tokenId, DELEGATE_RIGHTS
        );
    }

    /// @dev Reverts if any metadata entry uses the reserved agent-binding key.
    function _requireNoReservedBindingKey(IERC8004IdentityRegistry.MetadataEntry[] memory metadata) internal pure {
        uint256 length = metadata.length;
        for (uint256 i; i < length; ++i) {
            if (keccak256(bytes(metadata[i].metadataKey)) == BINDING_METADATA_KEY_HASH) {
                revert ReservedMetadataKey(metadata[i].metadataKey);
            }
        }
    }

    /// @dev Computes the UBID using this adapter's address and chain plus the supplied binding fields.
    function _bindingHash(Standard standard, address boundAddress, uint256 tokenId)
        internal
        view
        virtual
        returns (bytes32)
    {
        return _bindingHashFrom(_interoperableAddress(address(this)), standard, boundAddress, tokenId);
    }

    /// @dev Encodes the current chain ID as an ERC-7930 v1 chain identifier, without an address.
    function _chainIdentifier() internal view virtual returns (bytes memory identifier) {
        return _chainIdentifierFor(block.chainid);
    }

    /// @dev Encodes the current chain ID and account's 20-byte address as an ERC-7930 v1 address.
    function _interoperableAddress(address account) internal view virtual returns (bytes memory identifier) {
        return _interoperableAddressFor(block.chainid, account);
    }

    /// @dev Encodes the supplied chain ID without an account address.
    function _chainIdentifierFor(uint256 chainId) internal pure returns (bytes memory identifier) {
        return _erc7930AddressFor(chainId, address(0), false);
    }

    /// @dev Encodes the supplied chain ID and account address.
    function _interoperableAddressFor(uint256 chainId, address account)
        internal
        pure
        returns (bytes memory identifier)
    {
        return _erc7930AddressFor(chainId, account, true);
    }

    /// @dev Encodes a nonzero chain ID, optionally including the account address, using OpenZeppelin.
    /// Encoding changes would change UBIDs and attestation IDs. Run testOpenZeppelinEncodingIsFrozen
    /// before updating the draft-InteroperableAddress dependency.
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

    /// @dev Hashes the adapter's chain-qualified address, standard, bound address, and token ID.
    /// Keep abi.encode: changing the encoding would change existing UBIDs.
    function _bindingHashFrom(
        bytes memory adapterInteroperableAddress,
        Standard standard,
        address boundAddress,
        uint256 tokenId
    ) internal pure returns (bytes32) {
        return keccak256(abi.encode(adapterInteroperableAddress, standard, boundAddress, tokenId));
    }
}
