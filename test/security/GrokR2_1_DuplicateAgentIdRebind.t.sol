// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Test} from "forge-std/Test.sol";
import {ERC1967Proxy} from "@openzeppelin/contracts/proxy/ERC1967/ERC1967Proxy.sol";
import {AdapterImplementation} from "../../src/AdapterImplementation.sol";
import {IERC8217} from "../../src/interfaces/IERC8217.sol";
import {OverflowRegistry} from "./mocks/OverflowRegistry.sol";
import {MockERC721} from "../mocks/MockERC721.sol";

/// Inverse of R1 #12 (two agentIds, one UBID): here one agentId, two bindings.
contract GrokR2_1_DuplicateAgentIdRebind is Test {
    /// Success condition: a second register overwrites `_bindings[agentId]` so Alice's identity is captured.
    function test_trustBoundary_duplicateRegistryIdOverwritesTheBinding() external {
        OverflowRegistry ov = new OverflowRegistry();
        AdapterImplementation adapter = AdapterImplementation(
            address(
                new ERC1967Proxy(
                    address(new AdapterImplementation(address(ov))),
                    abi.encodeCall(AdapterImplementation.initialize, (makeAddr("admin")))
                )
            )
        );
        MockERC721 token = new MockERC721();
        address alice = makeAddr("alice");
        address bob = makeAddr("bob");
        token.mint(alice, 1);
        token.mint(bob, 2);

        vm.prank(alice);
        uint256 idA = adapter.register(IERC8217.Standard.ERC721, address(token), 1, "ipfs://a");
        vm.prank(bob);
        uint256 idB = adapter.register(IERC8217.Standard.ERC721, address(token), 2, "ipfs://b");

        assertEq(idA, type(uint256).max);
        assertEq(idB, type(uint256).max);
        assertEq(adapter.bindingOf(idA).tokenId, 2, "second write won the single slot");
        assertFalse(adapter.isController(idA, alice), "Alice's binding is gone");
        assertTrue(adapter.isController(idB, bob));
    }
}
