// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

interface IERCAgentBindings {
    /// @dev **APPEND ONLY. NEVER RENUMBER, NEVER REORDER, NEVER REMOVE A MEMBER.** These numbers are
    /// identity-critical, not merely descriptive. The `uint8` of this enum sits in the preimage of
    /// every UBI, so renumbering a member silently re-keys every
    /// counterfactual identity claimed under it and every attestation and reverse pointer that names
    /// one. That is unrecoverable: nothing on chain records the old value, and the identities do not
    /// move with it. The numbers are also persisted inside each stored `Binding` and emitted in
    /// `AgentBound` and every counterfactual event, so a renumbering would reinterpret stored
    /// bindings and indexed history as well.
    ///
    /// Before this constraint existed the numbering was only event-critical, which tolerated
    /// renumbering with a re-index. It no longer does. Add new standards at the end.
    ///
    /// Values 0-4 name a token *within* a contract, so the binding coordinate is `(boundAddress,
    /// tokenId)`. The three account standards name an address itself: there is no token to
    /// identify, so the binding has exactly one canonical coordinate, `tokenId == 0`. They differ
    /// only in who is authorized, and no two of them overlap. `ACCOUNT` grants authority to the
    /// named address and nobody else. `CONTRACT_OWNABLE` grants it to the current canonical nonzero
    /// address returned by `owner()`, and to a delegate.xyz delegate of that owner, but not to the
    /// contract. `CONTRACT_ADMIN` grants it to any holder of the contract's `DEFAULT_ADMIN_ROLE`,
    /// which suits an AccessControl contract that exposes no `owner()`.
    ///
    /// `ACCOUNT` is the only standard that accepts an address with no runtime code, because it is
    /// the only one that never calls the address it names. `CONTRACT_OWNABLE` and `CONTRACT_ADMIN`
    /// require code, since `owner()` and `hasRole` must be callable, as do values 0-4, which
    /// need `ownerOf` or `balanceOf`. Under EIP-7702 an externally-owned account can carry code, so
    /// `ACCOUNT` authority is precisely whoever can cause a call to originate from that address,
    /// which is the key holder plus, if a delegation is installed, whoever can drive it. Installing
    /// a delegation after binding permanently widens that set, and on an immutable binding that
    /// cannot be undone.
    ///
    /// `ACCOUNT` and `CONTRACT_ADMIN` are offered no delegation route. For `ACCOUNT` the delegator
    /// would be the bound address itself, and an address delegating on its own behalf cannot revoke
    /// without the same executor it used to delegate. For `CONTRACT_ADMIN` there is no single
    /// delegator to name, since the role is a membership predicate that many addresses can satisfy
    /// and none can enumerate.
    /// @dev Identity-critical numbering: append only, never renumber or reorder. See the note above.
    enum TokenStandard {
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
        TokenStandard standard;
        address boundAddress;
        uint256 tokenId;
    }

    function bindingOf(uint256 agentId) external view returns (Binding memory);

    /// @notice Hashing a binding produces a uniform identifier for the bound object, unique to it
    /// and resolvable on any chain or entirely offchain. That identifier is the Universal Binding
    /// Identifier (UBI), derived as
    /// `keccak256(abi.encode(bindingContractInteroperableAddress, standard, boundAddress, tokenId))`.
    /// Because a binding is immutable, an agent's UBI holds unchanged for the life of the identity.
    /// Querying an id that carries no binding reverts `UnknownAgent`.
    /// @dev ERC-8217 mandates this function on this interface, which is why it sits beside
    /// `bindingOf`: that returns the `Binding`, this returns the hash of the same thing, and the
    /// pair explains itself without a reader having to look up an acronym first. The two names do
    /// different jobs on purpose. `bindingHash` names the mechanism and is what the code calls it;
    /// UBI names the value that mechanism produces and is what the ERC and the prose call it.
    function bindingHashOf(uint256 agentId) external view returns (bytes32);
}
