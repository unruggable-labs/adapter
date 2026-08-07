// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {IERC721} from "@openzeppelin/contracts/token/ERC721/IERC721.sol";

import {Adapter8004} from "../../src/Adapter8004.sol";
import {IERCAgentBindings} from "../../src/interfaces/IERCAgentBindings.sol";
import {MockIdentityRegistry} from "./MockIdentityRegistry.sol";

/// @dev A binder that is not a token at all: no ERC-20/721/1155/6909 interface, no `ownerOf`, no
/// `balanceOf`, no supply, no holders, no `owner()`. It exists to show that `TokenStandard.CONTRACT`
/// binds a contract identity rather than a token, so a plain service contract can hold an agent with
/// nothing for the adapter to probe. Its only state is unrelated bookkeeping.
contract MockContractBinder {
    Adapter8004 internal immutable ADAPTER;

    uint256 public callCount;

    constructor(Adapter8004 adapter) {
        ADAPTER = adapter;
    }

    function doWork() external {
        ++callCount;
    }

    // ---------------------------------------------------------------
    //  Adapter calls made by the binder contract itself
    // ---------------------------------------------------------------

    function register(uint256 tokenId) external returns (uint256) {
        return
            ADAPTER.register(IERCAgentBindings.TokenStandard.CONTRACT, address(this), tokenId, "ipfs://contract-agent");
    }

    function counterfactualRegister(uint256 tokenId) external returns (bytes32) {
        return ADAPTER.counterfactualRegister(
            IERCAgentBindings.TokenStandard.CONTRACT, address(this), tokenId, "ipfs://contract-agent"
        );
    }

    function prepareExistingAgent(MockIdentityRegistry registry) external returns (uint256 agentId) {
        agentId = registry.register("ipfs://existing");
        IERC721(address(registry)).approve(address(ADAPTER), agentId);
    }

    function bindExisting(uint256 agentId, uint256 tokenId) external {
        ADAPTER.bindExisting(agentId, IERCAgentBindings.TokenStandard.CONTRACT, address(this), tokenId);
    }

    function setAgentURI(uint256 agentId, string calldata newURI) external {
        ADAPTER.setAgentURI(agentId, newURI);
    }

    function setMetadata(uint256 agentId, string calldata metadataKey, bytes calldata metadataValue) external {
        ADAPTER.setMetadata(agentId, metadataKey, metadataValue);
    }

    function unsetAgentWallet(uint256 agentId) external {
        ADAPTER.unsetAgentWallet(agentId);
    }

    function onERC721Received(address, address, uint256, bytes calldata) external pure returns (bytes4) {
        return this.onERC721Received.selector;
    }
}
