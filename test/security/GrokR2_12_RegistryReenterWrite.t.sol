// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Test} from "forge-std/Test.sol";
import {ERC1967Proxy} from "@openzeppelin/contracts/proxy/ERC1967/ERC1967Proxy.sol";
import {AdapterImplementation} from "../../src/AdapterImplementation.sol";
import {IERC8217} from "../../src/interfaces/IERC8217.sol";
import {IERC8004IdentityRegistry} from "../../src/interfaces/IERC8004IdentityRegistry.sol";
import {MockERC721} from "../mocks/MockERC721.sol";

interface IReentrancyGuardErrors {
    error ReentrancyGuardReentrantCall();
}

/// R1 reentrancy was ownerOf STATICCALL. This is a registry write callback into setAgentURI.
contract ReenterOnSetURI is IERC8004IdentityRegistry {
    AdapterImplementation public adapter;
    uint256 public nextId;
    string public lastURI;

    function setAdapter(AdapterImplementation adapter_) external {
        adapter = adapter_;
    }

    function register(string memory, MetadataEntry[] memory) external returns (uint256) {
        return nextId++;
    }

    function register(string memory) external returns (uint256) {
        return nextId++;
    }

    function register() external returns (uint256) {
        return nextId++;
    }

    function setMetadata(uint256, string memory, bytes memory) external {}

    function setAgentURI(uint256 agentId, string calldata newURI) external {
        lastURI = newURI;
        adapter.setAgentURI(agentId, "reentered");
    }

    function setAgentWallet(uint256, address, uint256, bytes calldata) external {}
    function unsetAgentWallet(uint256) external {}

    function getMetadata(uint256, string memory) external pure returns (bytes memory) {
        return "";
    }

    function getAgentWallet(uint256) external pure returns (address) {
        return address(0);
    }

    function ownerOf(uint256) external view returns (address) {
        return address(adapter);
    }

    function tokenURI(uint256) external view returns (string memory) {
        return lastURI;
    }
}

contract GrokR2_12_RegistryReenterWrite is Test {
    /// Success condition: a registry setAgentURI callback reenters and overwrites the URI.
    function test_defense_registryCallbackCannotReenterSetAgentURI() external {
        ReenterOnSetURI evil = new ReenterOnSetURI();
        AdapterImplementation adapter = AdapterImplementation(
            address(
                new ERC1967Proxy(
                    address(new AdapterImplementation(address(evil))),
                    abi.encodeCall(AdapterImplementation.initialize, (makeAddr("admin")))
                )
            )
        );
        evil.setAdapter(adapter);
        MockERC721 token = new MockERC721();
        address alice = makeAddr("alice");
        token.mint(alice, 1);
        vm.prank(alice);
        uint256 agentId = adapter.register(IERC8217.Standard.ERC721, address(token), 1, "ipfs://a");

        vm.prank(alice);
        vm.expectRevert(IReentrancyGuardErrors.ReentrancyGuardReentrantCall.selector);
        adapter.setAgentURI(agentId, "ipfs://first");
    }
}
