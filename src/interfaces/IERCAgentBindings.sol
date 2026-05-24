// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

interface IERCAgentBindings {
    enum TokenStandard {
        ERC721,
        ERC1155,
        ERC6909,
        ERC1155F,
        ERC6909F
    }

    struct Binding {
        TokenStandard standard;
        address tokenContract;
        uint256 tokenId;
    }

    function bindingOf(uint256 agentId) external view returns (Binding memory);
}
