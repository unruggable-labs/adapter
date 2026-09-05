// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Test} from "forge-std/Test.sol";
import {ERC1967Proxy} from "@openzeppelin/contracts/proxy/ERC1967/ERC1967Proxy.sol";
import {Adapter8004} from "../../src/Adapter8004.sol";
import {IERC8217} from "../../src/interfaces/IERC8217.sol";
import {MockIdentityRegistry} from "../mocks/MockIdentityRegistry.sol";
import {MockERC721} from "../mocks/MockERC721.sol";

/// R1 #18 used case/whitespace variants of "agent-binding". This is the empty key.
contract GrokR2_13_EmptyMetadataKey is Test {
    /// Success condition: setMetadata with an empty key overwrites the reserved agent-binding slot.
    function test_defense_emptyKeyDoesNotForgeAgentBinding() external {
        MockIdentityRegistry registry = new MockIdentityRegistry();
        Adapter8004 adapter = Adapter8004(
            address(
                new ERC1967Proxy(
                    address(new Adapter8004(address(registry))),
                    abi.encodeCall(Adapter8004.initialize, (makeAddr("admin")))
                )
            )
        );
        MockERC721 token = new MockERC721();
        address alice = makeAddr("alice");
        token.mint(alice, 1);
        vm.prank(alice);
        uint256 agentId = adapter.register(IERC8217.Standard.ERC721, address(token), 1, "ipfs://a");

        vm.prank(alice);
        adapter.setMetadata(agentId, "", abi.encodePacked(alice));

        assertEq(registry.getMetadata(agentId, "agent-binding"), abi.encodePacked(address(adapter)));
        assertEq(registry.getMetadata(agentId, ""), abi.encodePacked(alice));
        assertTrue(
            keccak256(registry.getMetadata(agentId, "agent-binding")) != keccak256(registry.getMetadata(agentId, ""))
        );
    }
}
