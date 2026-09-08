// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Test} from "forge-std/Test.sol";
import {ERC1967Proxy} from "@openzeppelin/contracts/proxy/ERC1967/ERC1967Proxy.sol";
import {IERC721} from "@openzeppelin/contracts/token/ERC721/IERC721.sol";
import {AdapterImplementation} from "../../src/AdapterImplementation.sol";
import {IERC8217} from "../../src/interfaces/IERC8217.sol";
import {MockIdentityRegistry} from "../mocks/MockIdentityRegistry.sol";
import {MockERC721} from "../mocks/MockERC721.sol";

/// R1 cut this as griefing and never executed it.
contract GrokR2_2_StrayNftReceive is Test {
    /// Success condition: a stranger parks an unrelated NFT on the adapter and forges a binding for it.
    function test_defense_strayNftDoesNotCreateABinding() external {
        MockIdentityRegistry registry = new MockIdentityRegistry();
        AdapterImplementation adapter = AdapterImplementation(
            address(
                new ERC1967Proxy(
                    address(new AdapterImplementation(address(registry))),
                    abi.encodeCall(AdapterImplementation.initialize, (makeAddr("admin")))
                )
            )
        );
        MockERC721 token = new MockERC721();
        address alice = makeAddr("alice");
        token.mint(alice, 99);
        vm.prank(alice);
        token.safeTransferFrom(alice, address(adapter), 99);

        assertEq(IERC721(address(token)).ownerOf(99), address(adapter), "adapter holds the stray NFT");
        vm.expectRevert(abi.encodeWithSelector(IERC8217.UnknownAgent.selector, uint256(99)));
        adapter.bindingOf(99);
        assertFalse(adapter.isController(99, alice));
        assertFalse(adapter.isController(99, address(adapter)));
    }
}
