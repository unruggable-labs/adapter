// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

/// @notice Reads and writes an ERC-8004 agent identity record, covering metadata, URI, wallet, NFT
/// owner and token URI. Both the identity registry and `AdapterImplementation` expose this surface; the
/// adapter forwards to `identityRegistry()` after bound-token access checks (the registry typically
/// enforces NFT owner/approval).
///
/// Registration is separate and uses different signatures:
/// - Registry: `IERC8004IdentityRegistry.register(string agentURI, MetadataEntry[] metadata)`
/// - Adapter: `IERC8004AdapterRegistration.register(Standard, address token, uint256 id,
///   string agentURI, MetadataEntry[] metadata)`
interface IERC8004IdentityRecord {
    function setMetadata(uint256 agentId, string memory metadataKey, bytes memory metadataValue) external;

    function setAgentURI(uint256 agentId, string calldata newURI) external;

    function setAgentWallet(uint256 agentId, address newWallet, uint256 deadline, bytes calldata signature) external;

    function unsetAgentWallet(uint256 agentId) external;

    function getMetadata(uint256 agentId, string memory metadataKey) external view returns (bytes memory);

    function getAgentWallet(uint256 agentId) external view returns (address);

    function ownerOf(uint256 agentId) external view returns (address);

    function tokenURI(uint256 agentId) external view returns (string memory);
}
