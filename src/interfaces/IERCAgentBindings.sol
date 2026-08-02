// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

interface IERCAgentBindings {
    /// @dev Append-only. Values 0-4 are load-bearing: they are persisted inside every stored `Binding`
    /// and emitted in `AgentBound` / counterfactual events, so renumbering them would silently
    /// reinterpret existing bindings and indexed history. `CONTRACT` is therefore appended as value 5.
    ///
    /// Values 0-4 name a token *within* a contract, so the binding coordinate is `(tokenContract,
    /// tokenId)`. `CONTRACT` names the contract itself: there is no token to identify, so the binding
    /// has exactly one canonical coordinate, `tokenId == 0`, and the contract is its own controller.
    enum TokenStandard {
        ERC721,
        ERC1155,
        ERC6909,
        ERC1155F,
        ERC6909F,
        CONTRACT
    }

    struct Binding {
        TokenStandard standard;
        address tokenContract;
        uint256 tokenId;
    }

    function bindingOf(uint256 agentId) external view returns (Binding memory);
}
