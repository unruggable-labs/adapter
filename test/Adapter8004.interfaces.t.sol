// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Test} from "forge-std/Test.sol";
import {Vm} from "forge-std/Vm.sol";
import {ERC1967Proxy} from "@openzeppelin/contracts/proxy/ERC1967/ERC1967Proxy.sol";
import {AdapterImplementation} from "../src/AdapterImplementation.sol";
import {IERC8004AdapterCounterfactual} from "../src/interfaces/IERC8004AdapterCounterfactual.sol";
import {IInteroperableAddressView} from "../src/interfaces/IInteroperableAddressView.sol";
import {IERC8217} from "../src/interfaces/IERC8217.sol";
import {IERC8004IdentityRecord} from "../src/interfaces/IERC8004IdentityRecord.sol";
import {IERC8004IdentityRegistry} from "../src/interfaces/IERC8004IdentityRegistry.sol";
import {MockIdentityRegistry} from "./mocks/MockIdentityRegistry.sol";
import {MockERC721} from "./mocks/MockERC721.sol";

/// @notice Closes the audit gaps from `output/audit-2026-05-07-pashov-tob.md`:
/// - I-03: explicit `IERC8004IdentityRecord` interface-cast coverage and revert-forwarding.
/// - L-01: exercises the two new ERC-8004 `register` overloads on the registry interface.
contract Adapter8004InterfacesTest is Test {
    MockIdentityRegistry internal registry;
    AdapterImplementation internal adapter;
    MockERC721 internal token721;

    address internal alice;
    address internal admin;

    function setUp() external {
        alice = makeAddr("alice");
        admin = makeAddr("admin");

        registry = new MockIdentityRegistry();

        AdapterImplementation implementation = new AdapterImplementation(address(registry));
        ERC1967Proxy proxy =
            new ERC1967Proxy(address(implementation), abi.encodeCall(AdapterImplementation.initialize, (admin)));
        adapter = AdapterImplementation(address(proxy));

        token721 = new MockERC721();
        token721.mint(alice, 1);
    }

    function testStandardValuesAreAdditive() external pure {
        assertEq(uint8(IERC8217.Standard.ERC721), 0);
        assertEq(uint8(IERC8217.Standard.ERC1155), 1);
        assertEq(uint8(IERC8217.Standard.ERC6909), 2);
        assertEq(uint8(IERC8217.Standard.ERC1155F), 3);
        assertEq(uint8(IERC8217.Standard.ERC6909F), 4);
        assertEq(uint8(IERC8217.Standard.ACCOUNT), 5);
        assertEq(uint8(IERC8217.Standard.CONTRACT_OWNABLE), 6);
    }

    function testPrimaryInterfacesCastAndSelectors() external {
        IERC8004AdapterCounterfactual cf = IERC8004AdapterCounterfactual(address(adapter));
        vm.prank(alice);
        assertEq(
            cf.setWalletUBID(IERC8217.Standard.ERC721, address(token721), 1),
            adapter.hashBinding(IERC8217.Standard.ERC721, address(token721), 1),
            "reachable through the interface cast"
        );
        assertEq(
            IERC8004AdapterCounterfactual.setWalletUBID.selector,
            bytes4(keccak256("setWalletUBID(uint8,address,uint256)"))
        );
        (bool oldNonceGetter,) = address(adapter).staticcall(abi.encodeWithSignature("nonces(address)", alice));
        assertFalse(oldNonceGetter);
        (bool counterfactualNonceGetter,) =
            address(adapter).staticcall(abi.encodeWithSignature("primaryCounterfactualAgentNonces(address)", alice));
        assertFalse(counterfactualNonceGetter);
        (bool counterfactualSetWithSig,) = address(adapter).call(
            abi.encodeWithSignature(
                "setPrimaryCounterfactualAgentWithSig(address,address,uint256,uint256,bytes)",
                alice,
                address(token721),
                1,
                block.timestamp,
                bytes("")
            )
        );
        assertFalse(counterfactualSetWithSig);
        (bool counterfactualClearWithSig,) = address(adapter).call(
            abi.encodeWithSignature(
                "clearPrimaryCounterfactualAgentWithSig(address,uint256,bytes)", alice, block.timestamp, bytes("")
            )
        );
        assertFalse(counterfactualClearWithSig);
    }

    /// @dev The signed primary-agent surface was removed at `0.0.17`. A stale selector that still
    /// resolves is the failure mode worth a test, so each removed entry point is probed directly:
    /// the call must fail because the function is absent, not because its arguments were wrong.
    function testRemovedSignedPrimaryAgentSelectorsDoNotResolve() external {
        // Each call is encoded at its own arity. A shared argument tuple would make every probe
        // fail in the ABI decoder instead of the dispatcher, so `assertFalse` would pass whether or
        // not the function was still there.
        bytes[3] memory removed = [
            abi.encodeWithSignature(
                "setPrimaryAgentWithSig(address,uint256,uint256,bytes)", alice, uint256(7), block.timestamp, bytes("")
            ),
            abi.encodeWithSignature("clearPrimaryAgentWithSig(address,uint256,bytes)", alice, block.timestamp, bytes("")),
            abi.encodeWithSignature("primaryAgentNonces(address)", alice)
        ];
        for (uint256 i; i < removed.length; ++i) {
            (bool resolved,) = address(adapter).call(removed[i]);
            assertFalse(resolved, "a removed signed-surface selector still resolves");
        }

        // The surviving surface is untouched, so the assertions above are not passing because the
        // whole wallet-pointer family went away.
        vm.prank(alice);
        assertEq(
            adapter.setWalletUBID(IERC8217.Standard.ERC721, address(token721), 1),
            adapter.hashBinding(IERC8217.Standard.ERC721, address(token721), 1)
        );
        vm.prank(alice);
        adapter.clearWalletUBID();
    }

    /// @dev The wallet-id surface was renamed at `0.0.17`. Every old selector must be gone, not merely
    /// shadowed by a new one, so each is probed directly and required not to resolve.
    function testRenamedWalletIdSelectorsDoNotResolveUnderTheirOldNames() external {
        string[6] memory oldOneArg = [
            "setPrimaryAgent(uint256)",
            "clearPrimaryAgent()",
            "primaryAgentOf(address)",
            "PRIMARY_AGENT_UNSET()",
            "clearPrimaryCounterfactualAgent()",
            "PRIMARY_COUNTERFACTUAL_AGENT_UNSET()"
        ];
        for (uint256 i; i < oldOneArg.length; ++i) {
            (bool resolved,) = address(adapter).call(abi.encodeWithSignature(oldOneArg[i]));
            assertFalse(resolved, "an old wallet-id selector still resolves");
        }

        string[4] memory oldTwoArg = [
            "setPrimaryAgentFor(address,uint256)",
            "clearPrimaryAgentFor(address)",
            "primaryCounterfactualAgentOf(address)",
            "clearPrimaryCounterfactualAgentFor(address)"
        ];
        for (uint256 i; i < oldTwoArg.length; ++i) {
            (bool resolved,) = address(adapter).call(abi.encodeWithSignature(oldTwoArg[i], alice, uint256(1)));
            assertFalse(resolved, "an old wallet-id selector still resolves");
        }

        (bool oldCfSet,) = address(adapter).call(
            abi.encodeWithSignature("setPrimaryCounterfactualAgent(uint8,address,uint256)", 0, alice, uint256(1))
        );
        assertFalse(oldCfSet, "the old counterfactual setter still resolves");

        // Positive control: the renamed surface works, so the assertions above cannot pass because
        // the whole family disappeared.
        vm.prank(alice);
        assertTrue(adapter.setWalletUBID(IERC8217.Standard.ERC721, address(token721), 1) != bytes32(0));
        vm.prank(alice);
        adapter.clearWalletUBID();
    }

    /// @dev The renamed events must not still carry their old topic0 values.
    function testRenamedWalletIdEventTopicsAreUnused() external {
        vm.recordLogs();
        vm.prank(alice);
        adapter.setWalletUBID(IERC8217.Standard.ERC721, address(token721), 1);
        vm.prank(alice);
        adapter.clearWalletUBID();

        bytes32[4] memory oldTopics = [
            keccak256("PrimaryAgentSet(address,uint256,address)"),
            keccak256("PrimaryAgentCleared(address,address)"),
            keccak256("PrimaryCounterfactualAgentSet(address,bytes32,address,uint256,bytes32,uint8,address)"),
            keccak256("PrimaryCounterfactualAgentCleared(address,address)")
        ];
        Vm.Log[] memory logs = vm.getRecordedLogs();
        assertEq(logs.length, 2, "both renamed paths still emit");
        for (uint256 i; i < logs.length; ++i) {
            for (uint256 j; j < oldTopics.length; ++j) {
                assertTrue(logs[i].topics[0] != oldTopics[j], "an old wallet-id event topic is still emitted");
            }
        }
    }

    /// @dev The two `WithSig` events go with their functions, so nothing should still emit or expect
    /// their topics. Pinned by signature rather than by selector, since the events are gone from the
    /// interface and cannot be referenced by name any more.
    function testRemovedSignedPrimaryAgentEventTopicsAreUnused() external {
        vm.recordLogs();
        vm.prank(alice);
        adapter.setWalletUBID(IERC8217.Standard.ERC721, address(token721), 1);
        vm.prank(alice);
        adapter.clearWalletUBID();

        bytes32 setWithSig = keccak256("PrimaryAgentSetWithSig(address,uint256,address,uint256)");
        bytes32 clearedWithSig = keccak256("PrimaryAgentClearedWithSig(address,address,uint256)");
        Vm.Log[] memory logs = vm.getRecordedLogs();
        for (uint256 i; i < logs.length; ++i) {
            assertTrue(logs[i].topics[0] != setWithSig, "PrimaryAgentSetWithSig still emitted");
            assertTrue(logs[i].topics[0] != clearedWithSig, "PrimaryAgentClearedWithSig still emitted");
        }
        assertEq(logs.length, 2, "the plain set and clear events still fire");
    }

    /// @dev The coordinate-form `ubid` stays on the counterfactual interface, because a
    /// counterfactual identity has no agent id and the coordinates are its only derivation. The
    /// ERC-7930 encoding moved to `IInteroperableAddressView`, which carries no identity meaning and
    /// is depended on by the counterfactual and attestation surfaces alike.
    function testCounterfactualAndEncodingInterfaceCastsAndSelectors() external view {
        IERC8004AdapterCounterfactual cf = IERC8004AdapterCounterfactual(address(adapter));
        assertEq(
            cf.hashBinding(IERC8217.Standard.ERC721, alice, 7), adapter.hashBinding(IERC8217.Standard.ERC721, alice, 7)
        );

        IInteroperableAddressView encoding = IInteroperableAddressView(address(adapter));
        assertEq(encoding.chainIdentifier(), adapter.chainIdentifier());
        assertEq(encoding.interoperableAddress(alice), adapter.interoperableAddress(alice));

        // Moving a declaration between interfaces must not move a selector.
        assertEq(
            IInteroperableAddressView.interoperableAddress.selector, bytes4(keccak256("interoperableAddress(address)"))
        );
        assertEq(IInteroperableAddressView.chainIdentifier.selector, bytes4(keccak256("chainIdentifier()")));

        // The counterfactual writers are declared on the counterfactual interface now, so the whole
        // surface is reachable through it. Selector equality checks the declarations match the
        // implementations exactly; `counterfactualRegister` is overloaded, so `.selector` is
        // ambiguous on it and both of its overloads are exercised by call below instead.
        assertEq(
            IERC8004AdapterCounterfactual.counterfactualSetAgentWalletAndUBID.selector,
            bytes4(keccak256("counterfactualSetAgentWalletAndUBID(uint8,address,uint256)"))
        );
        assertEq(
            IERC8004AdapterCounterfactual.counterfactualUnsetAgentWallet.selector,
            bytes4(keccak256("counterfactualUnsetAgentWallet(uint8,address,uint256)"))
        );
    }

    /// @dev `counterfactualRegister` is overloaded, so the interface declares both signatures and
    /// the contract must satisfy the pair. Both are called through the interface cast rather than
    /// through the concrete type, which is what proves the declarations are the ones being
    /// implemented, and both must name the same identity for the same coordinates.
    function testBothCounterfactualRegisterOverloadsResolveThroughTheInterface() external {
        IERC8004AdapterCounterfactual cf = IERC8004AdapterCounterfactual(address(adapter));
        bytes32 expected = adapter.hashBinding(IERC8217.Standard.ERC721, address(token721), 1);

        vm.prank(alice);
        bytes32 withoutMetadata = cf.counterfactualRegister(IERC8217.Standard.ERC721, address(token721), 1, "ipfs://a");

        IERC8004IdentityRegistry.MetadataEntry[] memory metadata = new IERC8004IdentityRegistry.MetadataEntry[](1);
        metadata[0] = IERC8004IdentityRegistry.MetadataEntry({metadataKey: "k", metadataValue: bytes("v")});
        vm.prank(alice);
        bytes32 withMetadata =
            cf.counterfactualRegister(IERC8217.Standard.ERC721, address(token721), 1, "ipfs://b", metadata);

        assertEq(withoutMetadata, expected, "four-argument overload");
        assertEq(withMetadata, expected, "five-argument overload");
    }

    /// @dev ERC-8217 requires this function on `IERC8217`, the interface that standard
    /// defines, and that is the only interface declaring it. It sits beside `bindingOf`, which
    /// returns the `Binding` this hashes, and it takes an agent id, which exists only for a
    /// registered agent. Deleting the declaration fails this test at compile time.
    function testBindingHashOfIsReachableThroughTheBindingsInterface() external {
        uint256 agentId = _register721(alice, 1, "ipfs://a");

        IERC8217 bindings = IERC8217(address(adapter));
        assertEq(bindings.bindingHashOf(agentId), adapter.bindingHashOf(agentId), "same answer");
        assertEq(
            bindings.bindingHashOf(agentId),
            adapter.hashBinding(IERC8217.Standard.ERC721, address(token721), 1),
            "and it is the coordinate form of the stored binding"
        );

        // The selector ERC-8217 pins.
        assertEq(IERC8217.bindingHashOf.selector, bytes4(0x30b7f986));
        assertEq(IERC8217.bindingHashOf.selector, bytes4(keccak256("bindingHashOf(uint256)")));

        // The revert behaviour is reachable through the standard's own interface, not only through
        // the concrete contract type.
        vm.expectRevert(abi.encodeWithSelector(IERC8217.UnknownAgent.selector, uint256(4242)));
        bindings.bindingHashOf(4242);
    }

    function testPrimaryEventTopicsAreSystemSpecific() external pure {
        assertEq(
            IERC8004AdapterCounterfactual.WalletUBIDSet.selector,
            keccak256("WalletUBIDSet(address,bytes32,address,uint256,uint8,address)")
        );
    }

    // ---------------------------------------------------------------------
    // (a) IERC8004IdentityRecord interface-cast: read forwarders
    // ---------------------------------------------------------------------

    function testIdentityRecordInterfaceCastReadsMatchRegistry() external {
        uint256 agentId = _register721(alice, 1, "ipfs://agent/1");

        IERC8004IdentityRecord record = IERC8004IdentityRecord(address(adapter));

        assertEq(record.ownerOf(agentId), registry.ownerOf(agentId));
        assertEq(record.tokenURI(agentId), registry.tokenURI(agentId));
        assertEq(record.getAgentWallet(agentId), registry.getAgentWallet(agentId));
        assertEq(
            record.getMetadata(agentId, adapter.BINDING_METADATA_KEY()),
            registry.getMetadata(agentId, adapter.BINDING_METADATA_KEY())
        );
    }

    function testIdentityRecordInterfaceCastWritesGoThroughControllerCheck() external {
        uint256 agentId = _register721(alice, 1, "");

        IERC8004IdentityRecord record = IERC8004IdentityRecord(address(adapter));

        // Controller can write through the IERC8004IdentityRecord surface.
        vm.prank(alice);
        record.setAgentURI(agentId, "ipfs://agent/updated");
        assertEq(registry.tokenURI(agentId), "ipfs://agent/updated");

        vm.prank(alice);
        record.setMetadata(agentId, "k", bytes("v"));
        assertEq(string(registry.getMetadata(agentId, "k")), "v");

        // Non-controller is rejected at the adapter layer, even via the interface cast.
        address eve = makeAddr("eve");
        vm.prank(eve);
        vm.expectRevert(abi.encodeWithSelector(AdapterImplementation.NotController.selector, eve, agentId));
        record.setMetadata(agentId, "k", bytes("bad"));

        vm.prank(eve);
        vm.expectRevert(abi.encodeWithSelector(AdapterImplementation.NotController.selector, eve, agentId));
        record.setAgentURI(agentId, "ipfs://bad");

        vm.prank(eve);
        vm.expectRevert(abi.encodeWithSelector(AdapterImplementation.NotController.selector, eve, agentId));
        record.unsetAgentWallet(agentId);
    }

    // ---------------------------------------------------------------------
    // (b) Read-revert forwarding from the underlying registry
    // ---------------------------------------------------------------------

    /// @dev These used to swap the registry under the live adapter. The registry is fixed at
    /// construction since `0.0.17`, so each builds a whole adapter on the reverting registry
    /// instead. The property under test is unchanged: a view must bubble the registry's revert
    /// rather than swallow it and answer zero.
    function _onReverting() private returns (AdapterImplementation) {
        RevertingRegistry reverting = new RevertingRegistry();
        return AdapterImplementation(
            address(
                new ERC1967Proxy(
                    address(new AdapterImplementation(address(reverting))),
                    abi.encodeCall(AdapterImplementation.initialize, (admin))
                )
            )
        );
    }

    function testGetMetadataForwardsRegistryRevert() external {
        AdapterImplementation reverting = _onReverting();
        vm.expectRevert(bytes("getMetadata reverted"));
        reverting.getMetadata(0, "any");
    }

    function testGetAgentWalletForwardsRegistryRevert() external {
        AdapterImplementation reverting = _onReverting();
        vm.expectRevert(bytes("getAgentWallet reverted"));
        reverting.getAgentWallet(0);
    }

    function testOwnerOfForwardsRegistryRevert() external {
        AdapterImplementation reverting = _onReverting();
        vm.expectRevert(bytes("ownerOf reverted"));
        reverting.ownerOf(0);
    }

    function testTokenURIForwardsRegistryRevert() external {
        AdapterImplementation reverting = _onReverting();
        vm.expectRevert(bytes("tokenURI reverted"));
        reverting.tokenURI(0);
    }

    // ---------------------------------------------------------------------
    // (c) ERC-8004 register overloads on IERC8004IdentityRegistry
    // ---------------------------------------------------------------------

    function testRegistryRegisterWithURIOnlyOverload() external {
        IERC8004IdentityRegistry typedRegistry = IERC8004IdentityRegistry(address(registry));

        vm.prank(alice);
        uint256 agentId = typedRegistry.register("ipfs://uri-only");

        assertEq(agentId, 0);
        assertEq(registry.ownerOf(agentId), alice);
        assertEq(registry.tokenURI(agentId), "ipfs://uri-only");
        // Bare overload sets the default agentWallet to the caller per ERC-8004.
        assertEq(registry.getAgentWallet(agentId), alice);
    }

    function testRegistryRegisterBareOverload() external {
        IERC8004IdentityRegistry typedRegistry = IERC8004IdentityRegistry(address(registry));

        vm.prank(alice);
        uint256 agentId = typedRegistry.register();

        assertEq(agentId, 0);
        assertEq(registry.ownerOf(agentId), alice);
        // No URI was supplied; ERC-721 returns empty tokenURI when none was set.
        assertEq(registry.tokenURI(agentId), "");
        assertEq(registry.getAgentWallet(agentId), alice);
    }

    function testRegistryRegisterOverloadsIncrementAgentId() external {
        IERC8004IdentityRegistry typedRegistry = IERC8004IdentityRegistry(address(registry));

        vm.prank(alice);
        uint256 firstId = typedRegistry.register();
        vm.prank(alice);
        uint256 secondId = typedRegistry.register("ipfs://second");
        vm.prank(alice);
        IERC8004IdentityRegistry.MetadataEntry[] memory empty = new IERC8004IdentityRegistry.MetadataEntry[](0);
        uint256 thirdId = typedRegistry.register("ipfs://third", empty);

        assertEq(firstId, 0);
        assertEq(secondId, 1);
        assertEq(thirdId, 2);
    }

    // ---------------------------------------------------------------------
    // helpers
    // ---------------------------------------------------------------------

    function _register721(address caller, uint256 tokenId, string memory agentURI) internal returns (uint256) {
        IERC8004IdentityRegistry.MetadataEntry[] memory empty = new IERC8004IdentityRegistry.MetadataEntry[](0);
        vm.prank(caller);
        return adapter.register(IERC8217.Standard.ERC721, address(token721), tokenId, agentURI, empty);
    }
}

/// @notice Minimal IERC8004IdentityRegistry stub whose view functions all revert,
/// used to verify AdapterImplementation propagates registry-side read failures faithfully.
contract RevertingRegistry is IERC8004IdentityRegistry {
    function register(string memory, MetadataEntry[] memory) external pure override returns (uint256) {
        revert("register reverted");
    }

    function register(string memory) external pure override returns (uint256) {
        revert("register reverted");
    }

    function register() external pure override returns (uint256) {
        revert("register reverted");
    }

    function setMetadata(uint256, string memory, bytes memory) external pure override {
        revert("setMetadata reverted");
    }

    function setAgentURI(uint256, string calldata) external pure override {
        revert("setAgentURI reverted");
    }

    function setAgentWallet(uint256, address, uint256, bytes calldata) external pure override {
        revert("setAgentWallet reverted");
    }

    function unsetAgentWallet(uint256) external pure override {
        revert("unsetAgentWallet reverted");
    }

    function getMetadata(uint256, string memory) external pure override returns (bytes memory) {
        revert("getMetadata reverted");
    }

    function getAgentWallet(uint256) external pure override returns (address) {
        revert("getAgentWallet reverted");
    }

    function ownerOf(uint256) external pure override returns (address) {
        revert("ownerOf reverted");
    }

    function tokenURI(uint256) external pure override returns (string memory) {
        revert("tokenURI reverted");
    }
}
