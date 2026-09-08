// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Test} from "forge-std/Test.sol";
import {ERC1967Proxy} from "@openzeppelin/contracts/proxy/ERC1967/ERC1967Proxy.sol";
import {AdapterImplementation} from "../../src/AdapterImplementation.sol";
import {IERC8217} from "../../src/interfaces/IERC8217.sol";
import {MockIdentityRegistry} from "../mocks/MockIdentityRegistry.sol";
import {MockERC721} from "../mocks/MockERC721.sol";

/// R1 #2 was isController totality. This is view-vs-bindingOf skew on unbound registry ids.
contract GrokR2_5_UnboundViewForwarding is Test {
    /// Success condition: adapter.ownerOf on a raw registry id the adapter never bound reports the
    /// attacker as controller of an adapter identity.
    function test_defense_unboundViewsDoNotMakeIsControllerTrue() external {
        MockIdentityRegistry registry = new MockIdentityRegistry();
        AdapterImplementation adapter = AdapterImplementation(
            address(
                new ERC1967Proxy(
                    address(new AdapterImplementation(address(registry))),
                    abi.encodeCall(AdapterImplementation.initialize, (makeAddr("admin")))
                )
            )
        );
        address attacker = makeAddr("attacker");
        vm.prank(attacker);
        uint256 rawId = registry.register("ipfs://raw");

        assertEq(adapter.ownerOf(rawId), attacker, "forwarded registry owner");
        assertFalse(adapter.isController(rawId, attacker), "no binding, not an adapter controller");
        vm.expectRevert(abi.encodeWithSelector(IERC8217.UnknownAgent.selector, rawId));
        adapter.bindingOf(rawId);
        vm.expectRevert(abi.encodeWithSelector(IERC8217.UnknownAgent.selector, rawId));
        adapter.bindingHashOf(rawId);
        vm.prank(attacker);
        vm.expectRevert(abi.encodeWithSelector(IERC8217.UnknownAgent.selector, rawId));
        adapter.setAgentURI(rawId, "ipfs://pwn");
    }
}
