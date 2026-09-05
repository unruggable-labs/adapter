// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Test} from "forge-std/Test.sol";
import {ERC1967Proxy} from "@openzeppelin/contracts/proxy/ERC1967/ERC1967Proxy.sol";
import {Adapter8004} from "../../src/Adapter8004.sol";
import {IERC8217} from "../../src/interfaces/IERC8217.sol";
import {MockIdentityRegistry} from "../mocks/MockIdentityRegistry.sol";
import {MockERC721} from "../mocks/MockERC721.sol";

/// R1 never compared hashBinding to bindingHashOf after a live register (cross-function identity).
contract GrokR2_17_HashBindingMatchesStored is Test {
    /// Success condition: after register, bindingHashOf(agentId) differs from hashBinding of the stored binding.
    function test_defense_storedHashMatchesThePublicDerivation() external {
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
        token.mint(alice, 7);
        vm.prank(alice);
        uint256 agentId = adapter.register(IERC8217.Standard.ERC721, address(token), 7, "ipfs://a");
        IERC8217.Binding memory b = adapter.bindingOf(agentId);
        assertEq(adapter.bindingHashOf(agentId), adapter.hashBinding(b.standard, b.boundAddress, b.tokenId));
        assertEq(uint8(b.standard), uint8(IERC8217.Standard.ERC721));
        assertEq(b.boundAddress, address(token));
        assertEq(b.tokenId, 7);
    }
}
