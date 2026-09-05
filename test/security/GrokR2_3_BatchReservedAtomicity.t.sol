// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Test} from "forge-std/Test.sol";
import {ERC1967Proxy} from "@openzeppelin/contracts/proxy/ERC1967/ERC1967Proxy.sol";
import {Adapter8004} from "../../src/Adapter8004.sol";
import {IERC8217} from "../../src/interfaces/IERC8217.sol";
import {IERC8004IdentityRegistry} from "../../src/interfaces/IERC8004IdentityRegistry.sol";
import {MockIdentityRegistry} from "../mocks/MockIdentityRegistry.sol";
import {MockERC721} from "../mocks/MockERC721.sol";

/// R1 #18 was key-normalization of a single setMetadata. This is batch atomicity.
contract GrokR2_3_BatchReservedAtomicity is Test {
    /// Success condition: a reserved key later in the batch still commits the earlier entries.
    function test_defense_reservedKeyRevertsTheWholeBatch() external {
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

        IERC8004IdentityRegistry.MetadataEntry[] memory batch = new IERC8004IdentityRegistry.MetadataEntry[](2);
        batch[0] = IERC8004IdentityRegistry.MetadataEntry("ok", bytes("v"));
        batch[1] = IERC8004IdentityRegistry.MetadataEntry("agent-binding", abi.encodePacked(alice));

        vm.prank(alice);
        vm.expectRevert(abi.encodeWithSelector(Adapter8004.ReservedMetadataKey.selector, "agent-binding"));
        adapter.setMetadataBatch(agentId, batch);

        assertEq(registry.getMetadata(agentId, "ok"), bytes(""), "first entry did not commit");
        assertEq(registry.getMetadata(agentId, "agent-binding"), abi.encodePacked(address(adapter)));
    }
}
