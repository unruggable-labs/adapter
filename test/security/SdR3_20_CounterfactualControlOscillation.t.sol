// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Test} from "forge-std/Test.sol";
import {ERC1967Proxy} from "@openzeppelin/contracts/proxy/ERC1967/ERC1967Proxy.sol";

import {AdapterImplementation} from "../../src/AdapterImplementation.sol";
import {IERC8217} from "../../src/interfaces/IERC8217.sol";
import {MockIdentityRegistry} from "../mocks/MockIdentityRegistry.sol";
import {MockERC721} from "../mocks/MockERC721.sol";

/// SdR3 #20 — CounterfactualControlOscillation. Counterfactual authority is the CURRENT token owner
/// (`_requireTokenAuthority`), and metadata is last-event-wins per UBID. As an ERC-721 changes hands
/// A->B->A, each current owner may overwrite the same key, and the final owner's last write wins —
/// so a seller's history is not durable against a re-acquiring party. NOT one of the prior 40: R1 #7
/// was delegation reactivation; R1 #16 was attestation reputation on resale; none drives repeated
/// counterfactual metadata overwrites across ownership oscillation with a denied write in between.
/// Defended-by-design: control tracks live ownership; last-event-wins is the documented projection.
contract SdR3_20_CounterfactualControlOscillation is Test {
    MockIdentityRegistry internal registry;
    AdapterImplementation internal adapter;
    MockERC721 internal token;

    address internal admin = makeAddr("admin");
    address internal alice = makeAddr("alice");
    address internal bob = makeAddr("bob");
    uint256 internal constant TID = 1;

    function setUp() external {
        registry = new MockIdentityRegistry();
        AdapterImplementation impl = new AdapterImplementation(address(registry));
        ERC1967Proxy proxy = new ERC1967Proxy(address(impl), abi.encodeCall(AdapterImplementation.initialize, (admin)));
        adapter = AdapterImplementation(address(proxy));
        token = new MockERC721();
        token.mint(alice, TID);
    }

    /// Success condition: control follows ownership on every hop; a former owner is denied mid-cycle;
    /// the re-acquiring owner overwrites again (last-event-wins).
    function test_controlOscillatesWithOwnershipAndLastWriteWins() external {
        vm.prank(alice);
        adapter.counterfactualSetMetadata(IERC8217.Standard.ERC721, address(token), TID, "k", bytes("A"));

        vm.prank(alice);
        token.transferFrom(alice, bob, TID);

        vm.prank(bob);
        adapter.counterfactualSetMetadata(IERC8217.Standard.ERC721, address(token), TID, "k", bytes("B"));

        // Alice, no longer owner, is denied.
        vm.prank(alice);
        vm.expectRevert(abi.encodeWithSelector(AdapterImplementation.NotController.selector, alice, type(uint256).max));
        adapter.counterfactualSetMetadata(IERC8217.Standard.ERC721, address(token), TID, "k", bytes("A2"));

        // Token returns to Alice; she can overwrite again.
        vm.prank(bob);
        token.transferFrom(bob, alice, TID);
        vm.prank(alice);
        bytes32 ubid =
            adapter.counterfactualSetMetadata(IERC8217.Standard.ERC721, address(token), TID, "k", bytes("A2"));
        assertEq(
            ubid, adapter.hashBinding(IERC8217.Standard.ERC721, address(token), TID), "same UBID throughout the cycle"
        );
    }
}
