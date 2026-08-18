// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Test} from "forge-std/Test.sol";
import {ERC1967Proxy} from "@openzeppelin/contracts/proxy/ERC1967/ERC1967Proxy.sol";

import {Adapter8004} from "../../src/Adapter8004.sol";
import {IERCAgentBindings} from "../../src/interfaces/IERCAgentBindings.sol";
import {IERC8004IdentityRegistry} from "../../src/interfaces/IERC8004IdentityRegistry.sol";

import {MockIdentityRegistry} from "../mocks/MockIdentityRegistry.sol";
import {MockERC1155} from "../mocks/MockERC1155.sol";
import {MockERC6909} from "../mocks/MockERC6909.sol";

import {MaliciousERC721} from "./mocks/MaliciousERC721.sol";
import {MaliciousERC1155} from "./mocks/MaliciousERC1155.sol";
import {MaliciousERC6909} from "./mocks/MaliciousERC6909.sol";
import {ReentrantERC721} from "./mocks/ReentrantERC721.sol";
import {RevertingToken} from "./mocks/RevertingToken.sol";
import {OverflowRegistry} from "./mocks/OverflowRegistry.sol";

interface IReentrancyGuardErrors {
    error ReentrancyGuardReentrantCall();
}

/// @notice Probes the adapter's trust boundary with hostile / malformed
/// token contracts and hostile registries. Every test here asserts that
/// the adapter either (a) faithfully enforces whatever the token contract
/// says about ownership, or (b) reverts cleanly without corrupting state.
contract AdversarialAdapter8004Test is Test {
    MockIdentityRegistry internal registry;
    Adapter8004 internal adapter;
    MockERC1155 internal token1155;
    MockERC6909 internal token6909;

    address internal admin = makeAddr("admin");
    address internal alice = makeAddr("alice");
    address internal bob = makeAddr("bob");
    address internal eve = makeAddr("eve");

    function setUp() external {
        registry = new MockIdentityRegistry();
        Adapter8004 impl = new Adapter8004();
        ERC1967Proxy proxy =
            new ERC1967Proxy(address(impl), abi.encodeCall(Adapter8004.initialize, (address(registry), admin)));
        adapter = Adapter8004(address(proxy));

        token1155 = new MockERC1155();
        token6909 = new MockERC6909();
    }

    // -----------------------------------------------------------------
    // A) Malformed token contracts
    // -----------------------------------------------------------------

    /// Binding to a contract whose read path always reverts must propagate
    /// the revert — the adapter must not silently register.
    function testRegisterPropagatesRevertingToken() external {
        RevertingToken rev = new RevertingToken();
        vm.prank(alice);
        vm.expectRevert();
        adapter.register(IERCAgentBindings.TokenStandard.ERC721, address(rev), 1, "", _emptyMetadata());

        vm.expectRevert(abi.encodeWithSelector(Adapter8004.UnknownAgent.selector, 0));
        adapter.bindingOf(0);
    }

    function testRegisterPropagatesRevertingToken1155() external {
        RevertingToken rev = new RevertingToken();
        vm.prank(alice);
        vm.expectRevert();
        adapter.register(IERCAgentBindings.TokenStandard.ERC1155, address(rev), 1, "", _emptyMetadata());
    }

    function testRegisterPropagatesRevertingToken6909() external {
        RevertingToken rev = new RevertingToken();
        vm.prank(alice);
        vm.expectRevert();
        adapter.register(IERCAgentBindings.TokenStandard.ERC6909, address(rev), 1, "", _emptyMetadata());
    }

    /// An EOA or any account with no bytecode cannot satisfy the staticcall
    /// to `ownerOf`/`balanceOf`; Solidity aborts on the missing extcodesize.
    function testRegisterRejectsEoaTokenContract() external {
        address eoa = makeAddr("eoa");
        vm.prank(alice);
        vm.expectRevert();
        adapter.register(IERCAgentBindings.TokenStandard.ERC721, eoa, 1, "", _emptyMetadata());
    }

    // -----------------------------------------------------------------
    // B) Attacker-controlled token contracts
    // -----------------------------------------------------------------

    /// A malicious 721 can claim any owner it wants. The adapter is
    /// intentionally a trust-forwarder: whoever the token says owns the
    /// tokenId becomes the controller of the resulting agent. This test
    /// documents that trust boundary so any future change to it is visible.
    function testMaliciousERC721GrantsControlToForcedOwner() external {
        MaliciousERC721 mal = new MaliciousERC721();
        mal.setOwner(1, alice);

        vm.prank(alice);
        uint256 agentId =
            adapter.register(IERCAgentBindings.TokenStandard.ERC721, address(mal), 1, "", _emptyMetadata());

        assertTrue(adapter.isController(agentId, alice));
        assertFalse(adapter.isController(agentId, bob));
    }

    /// The same malicious 721 can later flip control to a different
    /// address. The adapter reads ownership fresh on every gated call,
    /// so the flip takes effect immediately.
    function testMaliciousERC721CanFlipControl() external {
        MaliciousERC721 mal = new MaliciousERC721();
        mal.setOwner(1, alice);

        vm.prank(alice);
        uint256 agentId =
            adapter.register(IERCAgentBindings.TokenStandard.ERC721, address(mal), 1, "", _emptyMetadata());

        vm.prank(alice);
        adapter.setMetadata(agentId, "k", bytes("alice"));

        mal.setOwner(1, eve);

        vm.prank(alice);
        vm.expectRevert(abi.encodeWithSelector(Adapter8004.NotController.selector, alice, agentId));
        adapter.setMetadata(agentId, "k", bytes("alice again"));

        vm.prank(eve);
        adapter.setMetadata(agentId, "k", bytes("eve"));
        assertEq(string(registry.getMetadata(agentId, "k")), "eve");
    }

    // -----------------------------------------------------------------
    // C) View-time reentrancy attempts
    // -----------------------------------------------------------------

    /// A malicious ERC-721 that tries to reenter the adapter from inside
    /// `ownerOf` cannot succeed: Solidity compiles the adapter's view call
    /// as STATICCALL, so any state write or external CALL in the token
    /// reverts the whole frame.
    function testMaliciousERC721ReentryIsBlockedByStaticcall() external {
        MaliciousERC721 mal = new MaliciousERC721();
        mal.setOwner(1, alice);
        mal.setReentry(
            address(adapter),
            abi.encodeWithSignature(
                "register(uint8,address,uint256,string,(string,bytes)[])",
                IERCAgentBindings.TokenStandard.ERC721,
                address(mal),
                2,
                "",
                new IERC8004IdentityRegistry.MetadataEntry[](0)
            )
        );

        vm.prank(alice);
        vm.expectRevert();
        adapter.register(IERCAgentBindings.TokenStandard.ERC721, address(mal), 1, "", _emptyMetadata());

        vm.expectRevert(abi.encodeWithSelector(Adapter8004.UnknownAgent.selector, 0));
        adapter.bindingOf(0);
    }

    function testMaliciousERC1155ReentryIsBlockedByStaticcall() external {
        MaliciousERC1155 mal = new MaliciousERC1155();
        mal.setBalance(alice, 1, 1);
        mal.setReentry(address(adapter), abi.encodeCall(adapter.bindingOf, (0)));

        vm.prank(alice);
        vm.expectRevert();
        adapter.register(IERCAgentBindings.TokenStandard.ERC1155, address(mal), 1, "", _emptyMetadata());
    }

    function testMaliciousERC6909ReentryIsBlockedByStaticcall() external {
        MaliciousERC6909 mal = new MaliciousERC6909();
        mal.setBalance(alice, 1, 1);
        mal.setReentry(address(adapter), abi.encodeCall(adapter.bindingOf, (0)));

        vm.prank(alice);
        vm.expectRevert();
        adapter.register(IERCAgentBindings.TokenStandard.ERC6909, address(mal), 1, "", _emptyMetadata());
    }

    // -----------------------------------------------------------------
    // D) Shared-control race / front-running
    // -----------------------------------------------------------------

    /// Two ERC-1155 holders of the same id can both register separate
    /// ERC-8004 agents because the adapter no longer enforces canonical
    /// uniqueness per external token.
    function test1155MultipleHoldersCanRegisterSeparateAgents() external {
        token1155.mint(alice, 7, 1);
        token1155.mint(bob, 7, 1);

        vm.prank(bob);
        uint256 firstAgentId =
            adapter.register(IERCAgentBindings.TokenStandard.ERC1155, address(token1155), 7, "", _emptyMetadata());

        vm.prank(alice);
        uint256 secondAgentId =
            adapter.register(IERCAgentBindings.TokenStandard.ERC1155, address(token1155), 7, "", _emptyMetadata());

        assertTrue(firstAgentId != secondAgentId);
        assertTrue(adapter.isController(firstAgentId, alice));
        assertTrue(adapter.isController(firstAgentId, bob));
        assertTrue(adapter.isController(secondAgentId, alice));
        assertTrue(adapter.isController(secondAgentId, bob));
    }

    function test6909MultipleHoldersCanRegisterSeparateAgents() external {
        token6909.mint(alice, 7, 1);
        token6909.mint(bob, 7, 1);

        vm.prank(bob);
        uint256 firstAgentId =
            adapter.register(IERCAgentBindings.TokenStandard.ERC6909, address(token6909), 7, "", _emptyMetadata());

        vm.prank(alice);
        uint256 secondAgentId =
            adapter.register(IERCAgentBindings.TokenStandard.ERC6909, address(token6909), 7, "", _emptyMetadata());

        assertTrue(firstAgentId != secondAgentId);
        assertTrue(adapter.isController(firstAgentId, alice));
        assertTrue(adapter.isController(firstAgentId, bob));
        assertTrue(adapter.isController(secondAgentId, alice));
        assertTrue(adapter.isController(secondAgentId, bob));
    }

    // -----------------------------------------------------------------
    // E) Registry-side attacker
    // -----------------------------------------------------------------

    /// An adversarial registry that returns `type(uint256).max` should not
    /// break the adapter's own storage writes now that reverse lookup is gone.
    function testOverflowRegistryCanStillRegister() external {
        OverflowRegistry evilRegistry = new OverflowRegistry();
        vm.prank(admin);
        adapter.setIdentityRegistry(address(evilRegistry));

        MaliciousERC721 mal = new MaliciousERC721();
        mal.setOwner(1, alice);

        vm.prank(alice);
        uint256 agentId =
            adapter.register(IERCAgentBindings.TokenStandard.ERC721, address(mal), 1, "", _emptyMetadata());

        IERCAgentBindings.Binding memory binding = adapter.bindingOf(agentId);
        assertEq(binding.boundAddress, address(mal));
        assertEq(binding.tokenId, 1);
    }

    // -----------------------------------------------------------------
    // F) Admin hostile paths
    // -----------------------------------------------------------------

    /// After an admin swaps out the registry, old bindings remain but the
    /// adapter now writes to the new registry. Verifying that no state
    /// corruption occurs and that reads on the old binding still work.
    function testRegistrySwapLeavesOldBindingsQueryable() external {
        token1155.mint(alice, 1, 1);
        vm.prank(alice);
        uint256 agentId =
            adapter.register(IERCAgentBindings.TokenStandard.ERC1155, address(token1155), 1, "", _emptyMetadata());

        MockIdentityRegistry newRegistry = new MockIdentityRegistry();
        vm.prank(admin);
        adapter.setIdentityRegistry(address(newRegistry));

        IERCAgentBindings.Binding memory b = adapter.bindingOf(agentId);
        assertEq(b.boundAddress, address(token1155));
        assertTrue(adapter.isController(agentId, alice));

        // Writes now forward into the new registry, which doesn't know this
        // agentId at all — so the call reverts in the registry's auth check.
        vm.prank(alice);
        vm.expectRevert();
        adapter.setMetadata(agentId, "k", bytes("v"));
    }

    /// Owner renouncement is permissible per OwnableUpgradeable. After
    /// renouncement, both `setIdentityRegistry` and `upgradeToAndCall`
    /// become uncallable. Document the hazard with a regression test.
    function testOwnerRenouncementLocksAdminFunctions() external {
        vm.prank(admin);
        adapter.renounceOwnership();
        assertEq(adapter.owner(), address(0));

        vm.prank(admin);
        vm.expectRevert();
        adapter.setIdentityRegistry(address(1));

        Adapter8004 freshImpl = new Adapter8004();
        vm.prank(admin);
        vm.expectRevert();
        adapter.upgradeToAndCall(address(freshImpl), "");
    }

    /// On-chain register reentrancy: a malicious ERC-721 attempts to reenter `adapter.register(...)`
    /// during its own `ownerOf` staticcall. The adapter's `nonReentrant` guard fires on the SLOAD
    /// entry check (allowed inside the static frame), reverting the inner frame with
    /// `ReentrancyGuardReentrantCall()`. The mock propagates that selector verbatim, and the outer
    /// register call surfaces it to the caller — proving the reentrancy lock is engaged.
    function testRegisterReentryRevertsWithReentrancyGuardReentrantCall() external {
        ReentrantERC721 mal = new ReentrantERC721();
        mal.setOwner(1, alice);
        mal.setReentry(
            address(adapter),
            abi.encodeWithSignature(
                "register(uint8,address,uint256,string,(string,bytes)[])",
                IERCAgentBindings.TokenStandard.ERC721,
                address(mal),
                1,
                "",
                new IERC8004IdentityRegistry.MetadataEntry[](0)
            )
        );

        vm.prank(alice);
        vm.expectRevert(IReentrancyGuardErrors.ReentrancyGuardReentrantCall.selector);
        adapter.register(IERCAgentBindings.TokenStandard.ERC721, address(mal), 1, "", _emptyMetadata());
    }

    function _emptyMetadata() internal pure returns (IERC8004IdentityRegistry.MetadataEntry[] memory) {
        return new IERC8004IdentityRegistry.MetadataEntry[](0);
    }
}
