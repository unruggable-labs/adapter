// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

interface IERCAgentBindings {
    /// @dev Append-only. Values 0-4 are load-bearing: they are persisted inside every stored `Binding`
    /// and emitted in `AgentBound` / counterfactual events, so renumbering them would silently
    /// reinterpret existing bindings and indexed history. `ACCOUNT` is therefore value 5,
    /// `CONTRACT_OWNABLE` is appended as value 6, and `CONTRACT_ADMIN` as value 7.
    ///
    /// Values 0-4 name a token *within* a contract, so the binding coordinate is `(tokenContract,
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
    /// still require code, since `owner()` and `hasRole` must be callable, as do values 0-4, which
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
        address tokenContract;
        uint256 tokenId;
    }

    function bindingOf(uint256 agentId) external view returns (Binding memory);
}
