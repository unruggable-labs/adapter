// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Test} from "forge-std/Test.sol";
import {ERC1967Proxy} from "@openzeppelin/contracts/proxy/ERC1967/ERC1967Proxy.sol";
import {Adapter8004} from "../../src/Adapter8004.sol";
import {IERC8217} from "../../src/interfaces/IERC8217.sol";
import {MockIdentityRegistry} from "../mocks/MockIdentityRegistry.sol";

/// R1 #4 was a hostile bound owner(). This binds CONTRACT_OWNABLE to the adapter itself.
contract GrokR2_18_BindAdapterOwnable is Test {
    /// Success condition: binding the adapter as CONTRACT_OWNABLE lets a stranger pass isController
    /// because owner() is confused with tx.origin or the bound address.
    function test_defense_strangerDoesNotControlAnAdapterOwnableBinding() external {
        MockIdentityRegistry registry = new MockIdentityRegistry();
        address admin = makeAddr("admin");
        address attacker = makeAddr("attacker");
        Adapter8004 adapter = Adapter8004(
            address(
                new ERC1967Proxy(
                    address(new Adapter8004(address(registry))), abi.encodeCall(Adapter8004.initialize, (admin))
                )
            )
        );

        vm.prank(admin);
        uint256 agentId = adapter.register(IERC8217.Standard.CONTRACT_OWNABLE, address(adapter), 0, "ipfs://self");

        assertTrue(adapter.isController(agentId, admin), "adapter owner() is admin");
        assertFalse(adapter.isController(agentId, attacker));
        assertFalse(adapter.isController(agentId, address(adapter)), "self is not CONTRACT_OWNABLE authority");
        vm.prank(attacker);
        vm.expectRevert(abi.encodeWithSelector(Adapter8004.NotController.selector, attacker, agentId));
        adapter.setAgentURI(agentId, "ipfs://pwn");
    }
}
