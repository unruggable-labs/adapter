// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Test} from "forge-std/Test.sol";
import {ERC1967Proxy} from "@openzeppelin/contracts/proxy/ERC1967/ERC1967Proxy.sol";
import {AdapterImplementation} from "../../src/AdapterImplementation.sol";
import {IERC8217} from "../../src/interfaces/IERC8217.sol";
import {MockIdentityRegistry} from "../mocks/MockIdentityRegistry.sol";

/// R1 #11 used tokenId=7. This is the uint256.max edge on the same canonical-id guard.
contract GrokR2_8_MaxTokenIdAccount is Test {
    /// Success condition: ACCOUNT + tokenId=max is claimable and collides with the canonical (addr, 0) UBID.
    function test_defense_maxTokenIdOnAccountRevertsAndDoesNotCollide() external {
        MockIdentityRegistry registry = new MockIdentityRegistry();
        AdapterImplementation adapter = AdapterImplementation(
            address(
                new ERC1967Proxy(
                    address(new AdapterImplementation(address(registry))),
                    abi.encodeCall(AdapterImplementation.initialize, (makeAddr("admin")))
                )
            )
        );
        address victim = makeAddr("victim");
        uint256 maxId = type(uint256).max;
        bytes32 phantom = adapter.hashBinding(IERC8217.Standard.ACCOUNT, victim, maxId);
        bytes32 canonical = adapter.hashBinding(IERC8217.Standard.ACCOUNT, victim, 0);
        assertTrue(phantom != canonical);

        vm.prank(victim);
        vm.expectRevert(abi.encodeWithSelector(AdapterImplementation.NonZeroTokenIdForAccount.selector, victim, maxId));
        adapter.register(IERC8217.Standard.ACCOUNT, victim, maxId, "ipfs://x");

        vm.prank(victim);
        uint256 agentId = adapter.register(IERC8217.Standard.ACCOUNT, victim, 0, "ipfs://ok");
        assertEq(adapter.bindingHashOf(agentId), canonical);
        assertTrue(adapter.bindingHashOf(agentId) != phantom);
    }
}
