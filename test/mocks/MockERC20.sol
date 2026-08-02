// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {IERC721} from "@openzeppelin/contracts/token/ERC721/IERC721.sol";

import {Adapter8004} from "../../src/Adapter8004.sol";
import {IERCAgentBindings} from "../../src/interfaces/IERCAgentBindings.sol";
import {IERC8004IdentityRegistry} from "../../src/interfaces/IERC8004IdentityRegistry.sol";
import {MockIdentityRegistry} from "./MockIdentityRegistry.sol";

/// @dev Concrete token fixture for `TokenStandard.CONTRACT`: a minimal ERC-20 that binds itself as a
/// contract. It has no `ownerOf` and no `balanceOf(address,uint256)`, so any adapter probe for
/// per-token ownership or per-id balance would have to hit a function it does not have, and its
/// ordinary `balanceOf(address)` gives holders no authority. The adapter-driving helpers below run
/// with `msg.sender == address(this)`, which is the only authority a contract binding recognizes.
contract MockERC20 {
    string public constant name = "Mock20";
    string public constant symbol = "M20";
    uint8 public constant decimals = 18;

    Adapter8004 internal immutable ADAPTER;

    uint256 public totalSupply;
    mapping(address account => uint256 balance) internal _balances;
    mapping(address owner => mapping(address spender => uint256 amount)) public allowance;

    event Transfer(address indexed from, address indexed to, uint256 value);
    event Approval(address indexed owner, address indexed spender, uint256 value);

    constructor(Adapter8004 adapter) {
        ADAPTER = adapter;
    }

    function balanceOf(address account) public view returns (uint256) {
        return _balances[account];
    }

    function mint(address to, uint256 amount) external {
        totalSupply += amount;
        _balances[to] += amount;
        emit Transfer(address(0), to, amount);
    }

    function transfer(address to, uint256 amount) external returns (bool) {
        _balances[msg.sender] -= amount;
        _balances[to] += amount;
        emit Transfer(msg.sender, to, amount);
        return true;
    }

    function approve(address spender, uint256 amount) external returns (bool) {
        allowance[msg.sender][spender] = amount;
        emit Approval(msg.sender, spender, amount);
        return true;
    }

    function transferFrom(address from, address to, uint256 amount) external returns (bool) {
        allowance[from][msg.sender] -= amount;
        _balances[from] -= amount;
        _balances[to] += amount;
        emit Transfer(from, to, amount);
        return true;
    }

    // ---------------------------------------------------------------
    //  Adapter calls made by the token contract itself
    // ---------------------------------------------------------------

    function register(uint256 tokenId) external returns (uint256) {
        return ADAPTER.register(IERCAgentBindings.TokenStandard.CONTRACT, address(this), tokenId, "ipfs://erc20-agent");
    }

    function registerAndSetPrimary(uint256 tokenId) external returns (uint256) {
        return ADAPTER.registerAndSetPrimary(
            IERCAgentBindings.TokenStandard.CONTRACT, address(this), tokenId, "ipfs://erc20-agent"
        );
    }

    function registerWithMetadata(uint256 tokenId, IERC8004IdentityRegistry.MetadataEntry[] calldata metadata)
        external
        returns (uint256)
    {
        return ADAPTER.register(
            IERCAgentBindings.TokenStandard.CONTRACT, address(this), tokenId, "ipfs://erc20-agent", metadata
        );
    }

    function counterfactualRegister(uint256 tokenId) external returns (bytes32) {
        return ADAPTER.counterfactualRegister(
            IERCAgentBindings.TokenStandard.CONTRACT, address(this), tokenId, "ipfs://erc20-agent"
        );
    }

    function counterfactualRegisterWithMetadata(
        uint256 tokenId,
        string calldata agentURI,
        IERC8004IdentityRegistry.MetadataEntry[] calldata metadata
    ) external returns (bytes32) {
        return ADAPTER.counterfactualRegister(
            IERCAgentBindings.TokenStandard.CONTRACT, address(this), tokenId, agentURI, metadata
        );
    }

    function counterfactualSetAgentURI(uint256 tokenId, string calldata newURI) external {
        ADAPTER.counterfactualSetAgentURI(IERCAgentBindings.TokenStandard.CONTRACT, address(this), tokenId, newURI);
    }

    function counterfactualSetMetadata(uint256 tokenId, string calldata metadataKey, bytes calldata metadataValue)
        external
    {
        ADAPTER.counterfactualSetMetadata(
            IERCAgentBindings.TokenStandard.CONTRACT, address(this), tokenId, metadataKey, metadataValue
        );
    }

    function counterfactualSetMetadataBatch(uint256 tokenId, IERC8004IdentityRegistry.MetadataEntry[] calldata metadata)
        external
    {
        ADAPTER.counterfactualSetMetadataBatch(
            IERCAgentBindings.TokenStandard.CONTRACT, address(this), tokenId, metadata
        );
    }

    function counterfactualSetAgentWallet(uint256 tokenId, address newWallet) external {
        ADAPTER.counterfactualSetAgentWallet(
            IERCAgentBindings.TokenStandard.CONTRACT, address(this), tokenId, newWallet
        );
    }

    function counterfactualUnsetAgentWallet(uint256 tokenId) external {
        ADAPTER.counterfactualUnsetAgentWallet(IERCAgentBindings.TokenStandard.CONTRACT, address(this), tokenId);
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

    function setAgentWallet(uint256 agentId, address newWallet, uint256 deadline, bytes calldata signature) external {
        ADAPTER.setAgentWallet(agentId, newWallet, deadline, signature);
    }

    function unsetAgentWallet(uint256 agentId) external {
        ADAPTER.unsetAgentWallet(agentId);
    }

    function onERC721Received(address, address, uint256, bytes calldata) external pure returns (bytes4) {
        return this.onERC721Received.selector;
    }
}
