// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Test} from "forge-std/Test.sol";
import {ERC1967Proxy} from "@openzeppelin/contracts/proxy/ERC1967/ERC1967Proxy.sol";
import {Adapter8004} from "../../src/Adapter8004.sol";
import {IERC8217} from "../../src/interfaces/IERC8217.sol";
import {IERC8004IdentityRegistry} from "../../src/interfaces/IERC8004IdentityRegistry.sol";
import {MockIdentityRegistry} from "../mocks/MockIdentityRegistry.sol";
import {MockERC721} from "../mocks/MockERC721.sol";

/// R1 #18 was post-register setMetadata. This is the register-time metadata array.
contract GrokR2_4_RegisterReservedMetadata is Test {
    /// Success condition: register with reserved metadata mints an agent whose agent-binding is attacker-chosen.
    function test_defense_registerRejectsReservedMetadataBeforeMint() external {
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

        IERC8004IdentityRegistry.MetadataEntry[] memory metadata = new IERC8004IdentityRegistry.MetadataEntry[](1);
        metadata[0] = IERC8004IdentityRegistry.MetadataEntry("agent-binding", abi.encodePacked(alice));

        vm.prank(alice);
        vm.expectRevert(abi.encodeWithSelector(Adapter8004.ReservedMetadataKey.selector, "agent-binding"));
        adapter.register(IERC8217.Standard.ERC721, address(token), 1, "ipfs://a", metadata);

        vm.expectRevert(abi.encodeWithSelector(Adapter8004.UnknownAgent.selector, uint256(0)));
        adapter.bindingOf(0);
    }
}
