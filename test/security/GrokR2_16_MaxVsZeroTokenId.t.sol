// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Test} from "forge-std/Test.sol";
import {ERC1967Proxy} from "@openzeppelin/contracts/proxy/ERC1967/ERC1967Proxy.sol";
import {AdapterImplementation} from "../../src/AdapterImplementation.sol";
import {IERC8217} from "../../src/interfaces/IERC8217.sol";
import {MockIdentityRegistry} from "../mocks/MockIdentityRegistry.sol";
import {MockERC721} from "../mocks/MockERC721.sol";

/// R1 #12 was two rows of the same coordinate. This is tokenId max vs 0 on one collection.
contract GrokR2_16_MaxVsZeroTokenId is Test {
    /// Success condition: ERC-721 tokenId=max hashes to the same UBID as tokenId=0, capturing the zero-id identity.
    function test_defense_maxTokenIdIsADistinctIdentityFromZero() external {
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
        bytes32 zeroId = adapter.hashBinding(IERC8217.Standard.ERC721, address(token), 0);
        bytes32 maxId = adapter.hashBinding(IERC8217.Standard.ERC721, address(token), type(uint256).max);
        assertTrue(zeroId != maxId);
        address alice = makeAddr("alice");
        token.mint(alice, 0);
        token.mint(alice, type(uint256).max);
        vm.startPrank(alice);
        uint256 a0 = adapter.register(IERC8217.Standard.ERC721, address(token), 0, "ipfs://zero");
        uint256 aMax = adapter.register(IERC8217.Standard.ERC721, address(token), type(uint256).max, "ipfs://max");
        vm.stopPrank();
        assertTrue(a0 != aMax);
        assertEq(adapter.bindingHashOf(a0), zeroId);
        assertEq(adapter.bindingHashOf(aMax), maxId);
    }
}
