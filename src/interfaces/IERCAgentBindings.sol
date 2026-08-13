// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

interface IERCAgentBindings {
    /// @dev Append-only. Values 0-4 are load-bearing: they are persisted inside every stored `Binding`
    /// and emitted in `AgentBound` / counterfactual events, so renumbering them would silently
    /// reinterpret existing bindings and indexed history. `CONTRACT` is therefore value 5 and
    /// `CONTRACT_OWNABLE` is appended as value 6.
    ///
    /// Values 0-4 name a token *within* a contract, so the binding coordinate is `(tokenContract,
    /// tokenId)`. Both contract standards name the contract itself: there is no token to identify,
    /// so the binding has exactly one canonical coordinate, `tokenId == 0`. `CONTRACT` grants
    /// authority only to the contract itself. `CONTRACT_OWNABLE` additionally grants authority to
    /// the current canonical nonzero address returned by `owner()`, and to a delegate.xyz delegate of
    /// that owner. `CONTRACT_ADMIN` instead grants authority to any holder of the contract's
    /// `DEFAULT_ADMIN_ROLE`, which suits an AccessControl contract that exposes no `owner()`.
    /// `CONTRACT` and `CONTRACT_ADMIN` are offered no delegation route. For `CONTRACT` a contract
    /// delegating on its own behalf cannot revoke without the same executor it used to delegate. For
    /// `CONTRACT_ADMIN` there is no single delegator to name, since the role is a membership
    /// predicate that many addresses can satisfy and none can enumerate.
    enum TokenStandard {
        ERC721,
        ERC1155,
        ERC6909,
        ERC1155F,
        ERC6909F,
        CONTRACT,
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
