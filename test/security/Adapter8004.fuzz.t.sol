// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Test} from "forge-std/Test.sol";
import {ERC1967Proxy} from "@openzeppelin/contracts/proxy/ERC1967/ERC1967Proxy.sol";

import {Adapter8004} from "../../src/Adapter8004.sol";
import {IERCAgentBindings} from "../../src/interfaces/IERCAgentBindings.sol";
import {IERC8004IdentityRegistry} from "../../src/interfaces/IERC8004IdentityRegistry.sol";

import {MockIdentityRegistry} from "../mocks/MockIdentityRegistry.sol";
import {MockERC721} from "../mocks/MockERC721.sol";
import {MockERC1155} from "../mocks/MockERC1155.sol";
import {MockERC6909} from "../mocks/MockERC6909.sol";

/// @notice Property-based tests verifying the adapter's core invariants
/// across randomized inputs.
contract FuzzAdapter8004Test is Test {
    MockIdentityRegistry internal registry;
    Adapter8004 internal adapter;
    MockERC721 internal token721;
    MockERC1155 internal token1155;
    MockERC6909 internal token6909;

    address internal admin = makeAddr("admin");

    function setUp() external {
        registry = new MockIdentityRegistry();
        Adapter8004 impl = new Adapter8004(address(registry));
        ERC1967Proxy proxy = new ERC1967Proxy(address(impl), abi.encodeCall(Adapter8004.initialize, (admin)));
        adapter = Adapter8004(address(proxy));

        token721 = new MockERC721();
        token1155 = new MockERC1155();
        token6909 = new MockERC6909();
    }

    // -----------------------------------------------------------------
    // Invariant: successful register preserves the bound-token data on the
    // resulting agent record.
    // -----------------------------------------------------------------

    function testFuzzRegister721BindingIsConsistent(address holder, uint256 tokenId) external {
        holder = _sanitizeHolder(holder);
        token721.mint(holder, tokenId);

        vm.prank(holder);
        uint256 agentId =
            adapter.register(IERCAgentBindings.TokenStandard.ERC721, address(token721), tokenId, "", _emptyMetadata());

        IERCAgentBindings.Binding memory b = adapter.bindingOf(agentId);
        assertEq(b.boundAddress, address(token721));
        assertEq(b.tokenId, tokenId);
        assertEq(uint256(b.standard), uint256(IERCAgentBindings.TokenStandard.ERC721));
    }

    // -----------------------------------------------------------------
    // Invariant: duplicate registrations for the same external token remain
    // allowed and produce distinct ERC-8004 agent ids.
    // -----------------------------------------------------------------

    function testFuzzDuplicate721RegisterProducesDistinctAgents(address holder, uint256 tokenId) external {
        holder = _sanitizeHolder(holder);
        token721.mint(holder, tokenId);

        vm.startPrank(holder);
        uint256 firstAgentId =
            adapter.register(IERCAgentBindings.TokenStandard.ERC721, address(token721), tokenId, "", _emptyMetadata());

        uint256 secondAgentId =
            adapter.register(IERCAgentBindings.TokenStandard.ERC721, address(token721), tokenId, "", _emptyMetadata());
        vm.stopPrank();

        assertTrue(firstAgentId != secondAgentId);
    }

    // -----------------------------------------------------------------
    // Invariant: ERC-721 control always follows the current owner.
    // -----------------------------------------------------------------

    function testFuzzControl721FollowsOwner(address alice, address bob, uint256 tokenId) external {
        alice = _sanitizeHolder(alice);
        bob = _sanitizeHolder(bob);
        vm.assume(alice != bob);

        token721.mint(alice, tokenId);
        vm.prank(alice);
        uint256 agentId =
            adapter.register(IERCAgentBindings.TokenStandard.ERC721, address(token721), tokenId, "", _emptyMetadata());

        assertTrue(adapter.isController(agentId, alice));
        assertFalse(adapter.isController(agentId, bob));

        vm.prank(alice);
        token721.transferFrom(alice, bob, tokenId);

        assertFalse(adapter.isController(agentId, alice));
        assertTrue(adapter.isController(agentId, bob));
    }

    // -----------------------------------------------------------------
    // Invariant: ERC-1155 / ERC-6909 shared control — every current
    // holder passes, every non-holder fails.
    // -----------------------------------------------------------------

    function testFuzzControl1155FollowsBalances(
        address alice,
        address bob,
        uint256 tokenId,
        uint128 aliceBal,
        uint128 bobBal
    ) external {
        alice = _sanitizeHolder(alice);
        bob = _sanitizeHolder(bob);
        vm.assume(alice != bob);
        vm.assume(aliceBal > 0); // alice registers, so must hold at least 1

        token1155.mint(alice, tokenId, aliceBal);
        if (bobBal > 0) token1155.mint(bob, tokenId, bobBal);

        vm.prank(alice);
        uint256 agentId =
            adapter.register(IERCAgentBindings.TokenStandard.ERC1155, address(token1155), tokenId, "", _emptyMetadata());

        assertTrue(adapter.isController(agentId, alice));
        assertEq(adapter.isController(agentId, bob), bobBal > 0);
    }

    function testFuzzControl6909FollowsBalances(
        address alice,
        address bob,
        uint256 tokenId,
        uint128 aliceBal,
        uint128 bobBal
    ) external {
        alice = _sanitizeHolder(alice);
        bob = _sanitizeHolder(bob);
        vm.assume(alice != bob);
        vm.assume(aliceBal > 0);

        token6909.mint(alice, tokenId, aliceBal);
        if (bobBal > 0) token6909.mint(bob, tokenId, bobBal);

        vm.prank(alice);
        uint256 agentId =
            adapter.register(IERCAgentBindings.TokenStandard.ERC6909, address(token6909), tokenId, "", _emptyMetadata());

        assertTrue(adapter.isController(agentId, alice));
        assertEq(adapter.isController(agentId, bob), bobBal > 0);
    }

    // -----------------------------------------------------------------
    // Invariant: non-controllers are always rejected from all gated
    // writes. Fuzz the attacker address.
    // -----------------------------------------------------------------

    function testFuzzNonControllerCannotWrite(address attacker, uint256 tokenId) external {
        address holder = makeAddr("holder");
        vm.assume(attacker != holder && attacker != address(0) && attacker != address(adapter));

        token721.mint(holder, tokenId);
        vm.prank(holder);
        uint256 agentId =
            adapter.register(IERCAgentBindings.TokenStandard.ERC721, address(token721), tokenId, "", _emptyMetadata());

        vm.startPrank(attacker);

        vm.expectRevert(abi.encodeWithSelector(Adapter8004.NotController.selector, attacker, agentId));
        adapter.setAgentURI(agentId, "ipfs://evil");

        vm.expectRevert(abi.encodeWithSelector(Adapter8004.NotController.selector, attacker, agentId));
        adapter.setMetadata(agentId, "k", bytes("v"));

        vm.expectRevert(abi.encodeWithSelector(Adapter8004.NotController.selector, attacker, agentId));
        adapter.setMetadataBatch(agentId, _emptyMetadata());

        vm.expectRevert(abi.encodeWithSelector(Adapter8004.NotController.selector, attacker, agentId));
        adapter.setAgentWallet(agentId, attacker, block.timestamp + 1, "");

        vm.expectRevert(abi.encodeWithSelector(Adapter8004.NotController.selector, attacker, agentId));
        adapter.unsetAgentWallet(agentId);

        vm.stopPrank();
    }

    // -----------------------------------------------------------------
    // Invariant: only the owner can upgrade, and nobody can swap the registry.
    // -----------------------------------------------------------------

    /// @dev Was "only the owner can swap the registry". Since `0.0.17` nobody can, so the fuzz now
    /// asserts the stronger property across arbitrary callers and arbitrary targets.
    function testFuzzNobodyCanSwapRegistry(address caller, address newRegistry) external {
        vm.assume(caller != address(0));

        vm.prank(caller);
        (bool ok,) = address(adapter).call(abi.encodeWithSignature("setIdentityRegistry(address)", newRegistry));
        assertFalse(ok, "no caller may repoint the registry");
        assertEq(address(adapter.identityRegistry()), address(registry), "and it is unchanged");
    }

    function testFuzzNonOwnerCannotUpgrade(address attacker) external {
        vm.assume(attacker != admin && attacker != address(0));
        Adapter8004 newImpl = new Adapter8004(address(registry));

        vm.prank(attacker);
        vm.expectRevert();
        adapter.upgradeToAndCall(address(newImpl), "");
    }

    // -----------------------------------------------------------------
    // helpers
    // -----------------------------------------------------------------

    function _sanitizeHolder(address a) internal returns (address) {
        if (
            a == address(0) || a == address(adapter) || a == address(registry) || a == address(token721)
                || a == address(token1155) || a == address(token6909) || a == address(this)
        ) {
            return makeAddr("fuzzHolder");
        }
        // Some addresses have bytecode that rejects ERC721 receive — force an EOA-like address
        if (a.code.length > 0) {
            return makeAddr("fuzzEoa");
        }
        return a;
    }

    function _emptyMetadata() internal pure returns (IERC8004IdentityRegistry.MetadataEntry[] memory) {
        return new IERC8004IdentityRegistry.MetadataEntry[](0);
    }
}
