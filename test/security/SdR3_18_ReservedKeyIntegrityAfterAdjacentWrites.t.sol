// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Test} from "forge-std/Test.sol";
import {ERC1967Proxy} from "@openzeppelin/contracts/proxy/ERC1967/ERC1967Proxy.sol";

import {AdapterImplementation} from "../../src/AdapterImplementation.sol";
import {IERC8217} from "../../src/interfaces/IERC8217.sol";
import {MockIdentityRegistry} from "../mocks/MockIdentityRegistry.sol";
import {MockERC721} from "../mocks/MockERC721.sol";

/// SdR3 #18 — ReservedKeyIntegrityAfterAdjacentWrites. The reserved-key guard is one exact keccak
/// (:210, :46-47). A controller can write near-keys like `agent-binding-x` or `binding`, which are
/// distinct storage slots. This asserts the canonical `agent-binding` value survives such adjacent
/// writes intact and the exact reserved key still reverts. NOT one of the prior 40: R1 #18 / R2 #13
/// tested normalization variants (revert or different slot); none asserts the canonical value's
/// INTEGRITY after legitimate adjacent-key writes. Defended: the record is unshadowable by non-equal
/// keys and remains the 20-byte adapter address.
contract SdR3_18_ReservedKeyIntegrityAfterAdjacentWrites is Test {
    MockIdentityRegistry internal registry;
    AdapterImplementation internal adapter;
    MockERC721 internal token;

    address internal admin = makeAddr("admin");
    address internal owner = makeAddr("owner");
    uint256 internal constant TID = 1;

    function setUp() external {
        registry = new MockIdentityRegistry();
        AdapterImplementation impl = new AdapterImplementation(address(registry));
        ERC1967Proxy proxy = new ERC1967Proxy(address(impl), abi.encodeCall(AdapterImplementation.initialize, (admin)));
        adapter = AdapterImplementation(address(proxy));
        token = new MockERC721();
        token.mint(owner, TID);
    }

    /// Success condition (defense): after adjacent-key writes, `agent-binding` is still the adapter
    /// address, and the exact reserved key still reverts.
    function test_canonicalBindingRecordSurvivesAdjacentWrites() external {
        vm.prank(owner);
        uint256 agentId = adapter.register(IERC8217.Standard.ERC721, address(token), TID, "ipfs://a");

        assertEq(
            adapter.getMetadata(agentId, "agent-binding"), abi.encodePacked(address(adapter)), "canonical at register"
        );

        vm.startPrank(owner);
        adapter.setMetadata(agentId, "agent-binding-x", bytes("junk"));
        adapter.setMetadata(agentId, "binding", bytes("junk"));
        vm.stopPrank();

        assertEq(
            adapter.getMetadata(agentId, "agent-binding"),
            abi.encodePacked(address(adapter)),
            "canonical record is unshadowed by adjacent keys"
        );

        vm.prank(owner);
        vm.expectRevert(abi.encodeWithSelector(AdapterImplementation.ReservedMetadataKey.selector, "agent-binding"));
        adapter.setMetadata(agentId, "agent-binding", bytes("forged"));
    }
}
