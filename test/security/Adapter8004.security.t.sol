// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Test, Vm} from "forge-std/Test.sol";
import {ERC1967Proxy} from "@openzeppelin/contracts/proxy/ERC1967/ERC1967Proxy.sol";
import {Initializable} from "@openzeppelin/contracts-upgradeable/proxy/utils/Initializable.sol";
import {OwnableUpgradeable} from "@openzeppelin/contracts-upgradeable/access/OwnableUpgradeable.sol";

import {Adapter8004} from "../../src/Adapter8004.sol";
import {IERC8217} from "../../src/interfaces/IERC8217.sol";
import {IERC8004IdentityRegistry} from "../../src/interfaces/IERC8004IdentityRegistry.sol";

import {MockIdentityRegistry} from "../mocks/MockIdentityRegistry.sol";
import {MockERC721} from "../mocks/MockERC721.sol";
import {MockERC1155} from "../mocks/MockERC1155.sol";
import {MockERC6909} from "../mocks/MockERC6909.sol";

/// @notice Fills the coverage gaps left by the primary unit tests:
/// every revert, every event, every standard's non-controller path,
/// and every view function's unknown-agent path.
contract SecurityAdapter8004Test is Test {
    MockIdentityRegistry internal registry;
    MockIdentityRegistry internal registry2;
    Adapter8004 internal implementation;
    Adapter8004 internal adapter;
    MockERC721 internal token721;
    MockERC1155 internal token1155;
    MockERC6909 internal token6909;

    address internal admin = makeAddr("admin");
    address internal alice = makeAddr("alice");
    address internal bob = makeAddr("bob");
    address internal eve = makeAddr("eve");

    event AgentBound(
        uint256 indexed agentId,
        IERC8217.Standard indexed standard,
        address indexed boundAddress,
        uint256 tokenId,
        address registeredBy
    );

    function setUp() external {
        registry = new MockIdentityRegistry();
        registry2 = new MockIdentityRegistry();

        implementation = new Adapter8004(address(registry));
        ERC1967Proxy proxy = new ERC1967Proxy(address(implementation), abi.encodeCall(Adapter8004.initialize, (admin)));
        adapter = Adapter8004(address(proxy));

        token721 = new MockERC721();
        token1155 = new MockERC1155();
        token6909 = new MockERC6909();

        token721.mint(alice, 1);
        token721.mint(bob, 2);
        token1155.mint(alice, 10, 5);
        token1155.mint(bob, 10, 5);
        token6909.mint(alice, 42, 3);
        token6909.mint(bob, 42, 3);
    }

    // -----------------------------------------------------------------
    // initializer
    // -----------------------------------------------------------------

    /// @dev The registry is a constructor argument since `0.0.17`, so the zero check moved with it.
    /// Rejecting at construction is strictly earlier than rejecting at initialize: an implementation
    /// carrying a zero registry cannot be deployed at all, so no proxy can ever point at one.
    function testConstructorRejectsZeroRegistry() external {
        vm.expectRevert(Adapter8004.InvalidBoundAddress.selector);
        new Adapter8004(address(0));
    }

    function testInitializeRejectsZeroOwner() external {
        Adapter8004 impl = new Adapter8004(address(registry));
        vm.expectRevert(abi.encodeWithSelector(OwnableUpgradeable.OwnableInvalidOwner.selector, address(0)));
        new ERC1967Proxy(address(impl), abi.encodeCall(Adapter8004.initialize, (address(0))));
    }

    function testCannotReinitializeProxy() external {
        vm.expectRevert(Initializable.InvalidInitialization.selector);
        adapter.initialize(eve);
    }

    function testImplementationInitializerIsDisabled() external {
        vm.expectRevert(Initializable.InvalidInitialization.selector);
        implementation.initialize(admin);
    }

    // -----------------------------------------------------------------
    // register — validation + events
    // -----------------------------------------------------------------

    function testRegisterRejectsZeroTokenContract() external {
        vm.prank(alice);
        vm.expectRevert(Adapter8004.InvalidBoundAddress.selector);
        adapter.register(IERC8217.Standard.ERC721, address(0), 1, "", _emptyMetadata());
    }

    function testRegisterEmitsAgentBound() external {
        vm.expectEmit(true, true, true, true, address(adapter));
        // agentId is assigned sequentially by MockIdentityRegistry starting at 0
        emit AgentBound(0, IERC8217.Standard.ERC721, address(token721), 1, alice);
        vm.prank(alice);
        adapter.register(IERC8217.Standard.ERC721, address(token721), 1, "", _emptyMetadata());
    }

    function testRegister1155NonControllerReverts() external {
        vm.prank(eve);
        vm.expectRevert(abi.encodeWithSelector(Adapter8004.NotController.selector, eve, type(uint256).max));
        adapter.register(IERC8217.Standard.ERC1155, address(token1155), 10, "", _emptyMetadata());
    }

    function testRegister6909NonControllerReverts() external {
        vm.prank(eve);
        vm.expectRevert(abi.encodeWithSelector(Adapter8004.NotController.selector, eve, type(uint256).max));
        adapter.register(IERC8217.Standard.ERC6909, address(token6909), 42, "", _emptyMetadata());
    }

    function testRegisterSameTokenAcrossStandardsProducesDistinctAgents() external {
        // Same boundAddress/tokenId pair but different standards hash to
        // different binding keys — each should yield a fresh agentId.
        vm.prank(alice);
        uint256 a1 = adapter.register(IERC8217.Standard.ERC721, address(token721), 1, "", _emptyMetadata());

        // ERC721 at tokenId 1 is held by alice and would collide with the 1155
        // binding key only if (standard) were dropped from the hash. It is not.
        // Mint a fresh 1155 id to avoid polluting setUp state.
        token1155.mint(alice, 1, 1);
        vm.prank(alice);
        uint256 a2 = adapter.register(IERC8217.Standard.ERC1155, address(token1155), 1, "", _emptyMetadata());

        token6909.mint(alice, 1, 1);
        vm.prank(alice);
        uint256 a3 = adapter.register(IERC8217.Standard.ERC6909, address(token6909), 1, "", _emptyMetadata());

        assertTrue(a1 != a2 && a2 != a3 && a1 != a3, "agentIds must be distinct");
    }

    // -----------------------------------------------------------------
    // controller-gated writes: non-controller + unknown agent
    // -----------------------------------------------------------------

    function testSetAgentURINonControllerReverts() external {
        uint256 agentId = _register721(alice, 1);
        vm.prank(eve);
        vm.expectRevert(abi.encodeWithSelector(Adapter8004.NotController.selector, eve, agentId));
        adapter.setAgentURI(agentId, "ipfs://evil");
    }

    function testSetAgentURIUnknownAgentReverts() external {
        vm.prank(alice);
        vm.expectRevert(abi.encodeWithSelector(Adapter8004.UnknownAgent.selector, 999));
        adapter.setAgentURI(999, "ipfs://nope");
    }

    function testSetMetadataUnknownAgentReverts() external {
        vm.prank(alice);
        vm.expectRevert(abi.encodeWithSelector(Adapter8004.UnknownAgent.selector, 123));
        adapter.setMetadata(123, "k", bytes("v"));
    }

    function testSetMetadataBatchNonControllerReverts() external {
        uint256 agentId = _register721(alice, 1);
        vm.prank(eve);
        vm.expectRevert(abi.encodeWithSelector(Adapter8004.NotController.selector, eve, agentId));
        adapter.setMetadataBatch(agentId, _emptyMetadata());
    }

    function testSetMetadataBatchUnknownAgentReverts() external {
        vm.prank(alice);
        vm.expectRevert(abi.encodeWithSelector(Adapter8004.UnknownAgent.selector, 77));
        adapter.setMetadataBatch(77, _emptyMetadata());
    }

    /// @dev An empty batch writes nothing, so it now says nothing. The removed summary event was the
    /// only way to observe a caller passing zero entries, and that carried no information a consumer
    /// could act on.
    function testSetMetadataBatchEmptyEmitsNothingFromTheAdapter() external {
        uint256 agentId = _register721(alice, 1);
        vm.recordLogs();
        vm.prank(alice);
        adapter.setMetadataBatch(agentId, _emptyMetadata());

        Vm.Log[] memory logs = vm.getRecordedLogs();
        for (uint256 i; i < logs.length; ++i) {
            assertTrue(logs[i].emitter != address(adapter), "empty batch must emit no adapter event");
        }
    }

    /// @dev Asserts the key and value of every entry, and their order, not just how many were
    /// emitted. A count assertion cannot tell a correct batch from one that wrote the right number
    /// of wrong things.
    function testSetMetadataBatchEmitsMetadataSetPerEntryInOrder() external {
        uint256 agentId = _register721(alice, 1);
        IERC8004IdentityRegistry.MetadataEntry[] memory entries = new IERC8004IdentityRegistry.MetadataEntry[](3);
        entries[0] = IERC8004IdentityRegistry.MetadataEntry("a", bytes("1"));
        entries[1] = IERC8004IdentityRegistry.MetadataEntry("b", bytes("2"));
        entries[2] = IERC8004IdentityRegistry.MetadataEntry("c", bytes("3"));

        vm.recordLogs();
        vm.prank(alice);
        adapter.setMetadataBatch(agentId, entries);

        Vm.Log[] memory logs = vm.getRecordedLogs();
        bytes32 topic = keccak256("MetadataSet(uint256,string,bytes,address)");
        uint256 seen;
        for (uint256 i; i < logs.length; ++i) {
            if (logs[i].emitter != address(adapter) || logs[i].topics[0] != topic) continue;
            assertEq(uint256(logs[i].topics[1]), agentId);
            assertEq(address(uint160(uint256(logs[i].topics[2]))), alice);
            (string memory key, bytes memory value) = abi.decode(logs[i].data, (string, bytes));
            assertEq(key, entries[seen].metadataKey, "key must match its entry, in order");
            assertEq(value, entries[seen].metadataValue, "value must match its entry, in order");
            seen++;
        }
        assertEq(seen, 3, "one MetadataSet per entry");
    }

    function testSetAgentWalletNonControllerReverts() external {
        uint256 agentId = _register721(alice, 1);
        vm.prank(eve);
        vm.expectRevert(abi.encodeWithSelector(Adapter8004.NotController.selector, eve, agentId));
        adapter.setAgentWallet(agentId, makeAddr("x"), block.timestamp + 1, bytes(""));
    }

    function testSetAgentWalletUnknownAgentReverts() external {
        vm.prank(alice);
        vm.expectRevert(abi.encodeWithSelector(Adapter8004.UnknownAgent.selector, 42));
        adapter.setAgentWallet(42, makeAddr("x"), block.timestamp + 1, bytes(""));
    }

    function testUnsetAgentWalletNonControllerReverts() external {
        uint256 agentId = _register721(alice, 1);
        vm.prank(eve);
        vm.expectRevert(abi.encodeWithSelector(Adapter8004.NotController.selector, eve, agentId));
        adapter.unsetAgentWallet(agentId);
    }

    function testUnsetAgentWalletUnknownAgentReverts() external {
        vm.prank(alice);
        vm.expectRevert(abi.encodeWithSelector(Adapter8004.UnknownAgent.selector, 1));
        adapter.unsetAgentWallet(1);
    }

    function testUnsetAgentWalletControllerHappyPath() external {
        uint256 agentId = _register721(alice, 1);
        // Registration already clears the wallet; seed a value via the registry
        // so we can observe the user-initiated clear.
        // We can't set it without a valid signature, so instead assert the
        // wallet is zero after an extra unset call (idempotency).
        vm.prank(alice);
        adapter.unsetAgentWallet(agentId);
        assertEq(registry.getAgentWallet(agentId), address(0));
    }

    // -----------------------------------------------------------------
    // views: bindingOf, isController
    // -----------------------------------------------------------------

    function testBindingOfHappyPath() external {
        uint256 agentId = _register721(alice, 1);
        IERC8217.Binding memory b = adapter.bindingOf(agentId);
        assertEq(uint256(b.standard), uint256(IERC8217.Standard.ERC721));
        assertEq(b.boundAddress, address(token721));
        assertEq(b.tokenId, 1);
    }

    function testBindingOfUnknownAgentReverts() external {
        vm.expectRevert(abi.encodeWithSelector(Adapter8004.UnknownAgent.selector, 999));
        adapter.bindingOf(999);
    }

    function testIsControllerUnknownAgentReturnsFalse() external view {
        assertFalse(adapter.isController(999, alice));
    }

    function testIsControllerTracksTokenOwnership() external {
        uint256 agentId = _register721(alice, 1);
        assertTrue(adapter.isController(agentId, alice));
        assertFalse(adapter.isController(agentId, bob));

        vm.prank(alice);
        token721.transferFrom(alice, bob, 1);
        assertFalse(adapter.isController(agentId, alice));
        assertTrue(adapter.isController(agentId, bob));
    }

    function testIsController1155TracksBalance() external {
        uint256 agentId = _register1155(alice, 10);
        assertTrue(adapter.isController(agentId, alice));
        assertTrue(adapter.isController(agentId, bob));
        assertFalse(adapter.isController(agentId, eve));
    }

    function testIsController6909TracksBalance() external {
        uint256 agentId = _register6909(alice, 42);
        assertTrue(adapter.isController(agentId, alice));
        assertTrue(adapter.isController(agentId, bob));
        assertFalse(adapter.isController(agentId, eve));
    }

    // -----------------------------------------------------------------
    // onERC721Received
    // -----------------------------------------------------------------

    function testOnERC721ReceivedReturnsSelector() external view {
        bytes4 sel = adapter.onERC721Received(address(0), address(0), 0, "");
        assertEq(sel, bytes4(keccak256("onERC721Received(address,address,uint256,bytes)")));
    }

    // -----------------------------------------------------------------
    // 1155 / 6909 full transfer drops control
    // -----------------------------------------------------------------

    function test1155TransferOutDropsControl() external {
        uint256 agentId = _register1155(alice, 10);
        assertTrue(adapter.isController(agentId, alice));

        vm.prank(alice);
        token1155.safeTransferFrom(alice, bob, 10, 5, "");

        assertFalse(adapter.isController(agentId, alice));
        assertTrue(adapter.isController(agentId, bob));

        vm.prank(alice);
        vm.expectRevert(abi.encodeWithSelector(Adapter8004.NotController.selector, alice, agentId));
        adapter.setMetadata(agentId, "x", bytes("1"));
    }

    function test6909TransferOutDropsControl() external {
        uint256 agentId = _register6909(alice, 42);
        assertTrue(adapter.isController(agentId, alice));

        vm.prank(alice);
        token6909.transfer(bob, 42, 3);

        assertFalse(adapter.isController(agentId, alice));
        assertTrue(adapter.isController(agentId, bob));
    }

    // -----------------------------------------------------------------
    // helpers
    // -----------------------------------------------------------------

    function _register721(address caller, uint256 tokenId) internal returns (uint256) {
        vm.prank(caller);
        return adapter.register(IERC8217.Standard.ERC721, address(token721), tokenId, "", _emptyMetadata());
    }

    function _register1155(address caller, uint256 tokenId) internal returns (uint256) {
        vm.prank(caller);
        return adapter.register(IERC8217.Standard.ERC1155, address(token1155), tokenId, "", _emptyMetadata());
    }

    function _register6909(address caller, uint256 tokenId) internal returns (uint256) {
        vm.prank(caller);
        return adapter.register(IERC8217.Standard.ERC6909, address(token6909), tokenId, "", _emptyMetadata());
    }

    function _emptyMetadata() internal pure returns (IERC8004IdentityRegistry.MetadataEntry[] memory) {
        return new IERC8004IdentityRegistry.MetadataEntry[](0);
    }
}
