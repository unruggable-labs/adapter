// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

interface IERC8217 {
    /// @dev **APPEND ONLY. NEVER RENUMBER, REORDER, OR REMOVE A MEMBER.** The `uint8` of this enum
    /// sits in the preimage of every binding hash, so renumbering silently re-keys every identity
    /// claimed under it and nothing on chain records the old value. Values 0-4 name a token within a
    /// contract; the three account standards name an address itself and pin `tokenId` to 0. Per
    /// standard authority rules are documented on `Adapter8004._hasBindingControl`.
    enum Standard {
        ERC721,
        ERC1155,
        ERC6909,
        ERC1155F,
        ERC6909F,
        ACCOUNT,
        CONTRACT_OWNABLE,
        CONTRACT_ADMIN
    }

    struct Binding {
        Standard standard;
        address boundAddress;
        uint256 tokenId;
    }

    /// @notice The stored `Binding` for `agentId`, reverting `UnknownAgent` when the id carries none.
    /// @dev ERC-8217 mandates this function on this interface.
    function bindingOf(uint256 agentId) external view returns (Binding memory);

    /// @notice The globally unique identifier of the bound object, called the Universal Binding
    /// Identifier (UBI) in the ERC, derived as
    /// `keccak256(abi.encode(bindingContractInteroperableAddress, standard, boundAddress, tokenId))`.
    /// A binding is immutable, so it holds for the life of the identity. Reverts `UnknownAgent` when
    /// the id carries no binding.
    /// @dev ERC-8217 mandates this function on this interface.
    function bindingHashOf(uint256 agentId) external view returns (bytes32);
}
