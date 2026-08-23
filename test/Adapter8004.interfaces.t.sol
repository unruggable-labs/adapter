// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Test} from "forge-std/Test.sol";
import {Vm} from "forge-std/Vm.sol";
import {ERC1967Proxy} from "@openzeppelin/contracts/proxy/ERC1967/ERC1967Proxy.sol";
import {Adapter8004} from "../src/Adapter8004.sol";
import {IERC8004AdapterCounterfactual} from "../src/interfaces/IERC8004AdapterCounterfactual.sol";
import {IInteroperableAddressView} from "../src/interfaces/IInteroperableAddressView.sol";
import {IERC8004AdapterWalletUBI} from "../src/interfaces/IERC8004AdapterWalletUBI.sol";
import {IERC8004AdapterWalletAgentID} from "../src/interfaces/IERC8004AdapterWalletAgentID.sol";
import {IERCAgentBindings} from "../src/interfaces/IERCAgentBindings.sol";
import {IERC8004IdentityRecord} from "../src/interfaces/IERC8004IdentityRecord.sol";
import {IERC8004IdentityRegistry} from "../src/interfaces/IERC8004IdentityRegistry.sol";
import {MockIdentityRegistry} from "./mocks/MockIdentityRegistry.sol";
import {MockERC721} from "./mocks/MockERC721.sol";

/// @notice Closes the audit gaps from `output/audit-2026-05-07-pashov-tob.md`:
/// - I-03: explicit `IERC8004IdentityRecord` interface-cast coverage and revert-forwarding.
/// - L-01: exercises the two new ERC-8004 `register` overloads on the registry interface.
contract Adapter8004InterfacesTest is Test {
    MockIdentityRegistry internal registry;
    Adapter8004 internal adapter;
    MockERC721 internal token721;

    address internal alice;
    address internal admin;

    function setUp() external {
        alice = makeAddr("alice");
        admin = makeAddr("admin");

        registry = new MockIdentityRegistry();

        Adapter8004 implementation = new Adapter8004(address(registry));
        ERC1967Proxy proxy = new ERC1967Proxy(address(implementation), abi.encodeCall(Adapter8004.initialize, (admin)));
        adapter = Adapter8004(address(proxy));

        token721 = new MockERC721();
        token721.mint(alice, 1);
    }

    function testTokenStandardValuesAreAdditive() external pure {
        assertEq(uint8(IERCAgentBindings.TokenStandard.ERC721), 0);
        assertEq(uint8(IERCAgentBindings.TokenStandard.ERC1155), 1);
        assertEq(uint8(IERCAgentBindings.TokenStandard.ERC6909), 2);
        assertEq(uint8(IERCAgentBindings.TokenStandard.ERC1155F), 3);
        assertEq(uint8(IERCAgentBindings.TokenStandard.ERC6909F), 4);
        assertEq(uint8(IERCAgentBindings.TokenStandard.ACCOUNT), 5);
        assertEq(uint8(IERCAgentBindings.TokenStandard.CONTRACT_OWNABLE), 6);
    }

    function testPrimaryInterfacesCastAndSelectors() external {
        IERC8004AdapterWalletAgentID full = IERC8004AdapterWalletAgentID(address(adapter));
        IERC8004AdapterWalletUBI cf = IERC8004AdapterWalletUBI(address(adapter));
        assertEq(full.walletAgentIDOf(alice), type(uint256).max);
        assertEq(cf.walletUBIOf(alice), bytes32(type(uint256).max));
        assertEq(IERC8004AdapterWalletAgentID.setWalletAgentID.selector, bytes4(keccak256("setWalletAgentID(uint256)")));
        assertEq(
            IERC8004AdapterWalletUBI.setWalletUBI.selector, bytes4(keccak256("setWalletUBI(uint8,address,uint256)"))
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
        // whole primary-agent family went away.
        vm.prank(alice);
        adapter.setWalletAgentID(7);
        assertEq(adapter.walletAgentIDOf(alice), 7);
        vm.prank(alice);
        adapter.clearWalletAgentID();
        assertEq(adapter.walletAgentIDOf(alice), type(uint256).max);
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
        adapter.setWalletAgentID(5);
        assertEq(adapter.walletAgentIDOf(alice), 5);
        vm.prank(alice);
        adapter.clearWalletAgentID();
        assertEq(adapter.walletAgentIDOf(alice), adapter.WALLET_AGENT_ID_UNSET());
    }

    /// @dev The four renamed events must not still carry their old topic0 values.
    function testRenamedWalletIdEventTopicsAreUnused() external {
        vm.recordLogs();
        vm.prank(alice);
        adapter.setWalletAgentID(2);
        vm.prank(alice);
        adapter.clearWalletAgentID();
        vm.prank(alice);
        adapter.setWalletUBI(IERCAgentBindings.TokenStandard.ERC721, address(token721), 1);
        vm.prank(alice);
        adapter.clearWalletUBI();

        bytes32[4] memory oldTopics = [
            keccak256("PrimaryAgentSet(address,uint256,address)"),
            keccak256("PrimaryAgentCleared(address,address)"),
            keccak256("PrimaryCounterfactualAgentSet(address,bytes32,address,uint256,bytes32,uint8,address)"),
            keccak256("PrimaryCounterfactualAgentCleared(address,address)")
        ];
        Vm.Log[] memory logs = vm.getRecordedLogs();
        assertEq(logs.length, 4, "all four renamed paths still emit");
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
        adapter.setWalletAgentID(3);
        vm.prank(alice);
        adapter.clearWalletAgentID();

        bytes32 setWithSig = keccak256("PrimaryAgentSetWithSig(address,uint256,address,uint256)");
        bytes32 clearedWithSig = keccak256("PrimaryAgentClearedWithSig(address,address,uint256)");
        Vm.Log[] memory logs = vm.getRecordedLogs();
        for (uint256 i; i < logs.length; ++i) {
            assertTrue(logs[i].topics[0] != setWithSig, "PrimaryAgentSetWithSig still emitted");
            assertTrue(logs[i].topics[0] != clearedWithSig, "PrimaryAgentClearedWithSig still emitted");
        }
        assertEq(logs.length, 2, "the plain set and clear events still fire");
    }

    /// @dev The coordinate-form `ubi` stays on the counterfactual interface, because a
    /// counterfactual identity has no agent id and the coordinates are its only derivation. The
    /// ERC-7930 encoding moved to `IInteroperableAddressView`, which carries no identity meaning and
    /// is depended on by the counterfactual and attestation surfaces alike.
    function testCounterfactualAndEncodingInterfaceCastsAndSelectors() external view {
        IERC8004AdapterCounterfactual cf = IERC8004AdapterCounterfactual(address(adapter));
        assertEq(
            cf.bindingHashFor(IERCAgentBindings.TokenStandard.ERC721, alice, 7),
            adapter.bindingHashFor(IERCAgentBindings.TokenStandard.ERC721, alice, 7)
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
            IERC8004AdapterCounterfactual.counterfactualSetAgentWalletAndUBI.selector,
            bytes4(keccak256("counterfactualSetAgentWalletAndUBI(uint8,address,uint256)"))
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
        bytes32 expected = adapter.bindingHashFor(IERCAgentBindings.TokenStandard.ERC721, address(token721), 1);

        vm.prank(alice);
        bytes32 withoutMetadata =
            cf.counterfactualRegister(IERCAgentBindings.TokenStandard.ERC721, address(token721), 1, "ipfs://a");

        IERC8004IdentityRegistry.MetadataEntry[] memory metadata = new IERC8004IdentityRegistry.MetadataEntry[](1);
        metadata[0] = IERC8004IdentityRegistry.MetadataEntry({metadataKey: "k", metadataValue: bytes("v")});
        vm.prank(alice);
        bytes32 withMetadata = cf.counterfactualRegister(
            IERCAgentBindings.TokenStandard.ERC721, address(token721), 1, "ipfs://b", metadata
        );

        assertEq(withoutMetadata, expected, "four-argument overload");
        assertEq(withMetadata, expected, "five-argument overload");
    }

    /// @dev ERC-8217 requires this function on `IERCAgentBindings`, the interface that standard
    /// defines, and that is the only interface declaring it. It sits beside `bindingOf`, which
    /// returns the `Binding` this hashes, and it takes an agent id, which exists only for a
    /// registered agent. Deleting the declaration fails this test at compile time.
    function testBindingHashOfIsReachableThroughTheBindingsInterface() external {
        uint256 agentId = _register721(alice, 1, "ipfs://a");

        IERCAgentBindings bindings = IERCAgentBindings(address(adapter));
        assertEq(bindings.bindingHashOf(agentId), adapter.bindingHashOf(agentId), "same answer");
        assertEq(
            bindings.bindingHashOf(agentId),
            adapter.bindingHashFor(IERCAgentBindings.TokenStandard.ERC721, address(token721), 1),
            "and it is the coordinate form of the stored binding"
        );

        // The selector ERC-8217 pins.
        assertEq(IERCAgentBindings.bindingHashOf.selector, bytes4(0x30b7f986));
        assertEq(IERCAgentBindings.bindingHashOf.selector, bytes4(keccak256("bindingHashOf(uint256)")));

        // The revert behaviour is reachable through the standard's own interface, not only through
        // the concrete contract type.
        vm.expectRevert(abi.encodeWithSelector(Adapter8004.UnknownAgent.selector, uint256(4242)));
        bindings.bindingHashOf(4242);
    }

    function testPrimaryEventTopicsAreSystemSpecific() external pure {
        assertEq(
            IERC8004AdapterWalletAgentID.WalletAgentIDSet.selector,
            keccak256("WalletAgentIDSet(address,uint256,address)")
        );
        assertEq(
            IERC8004AdapterWalletUBI.WalletUBISet.selector,
            keccak256("WalletUBISet(address,bytes32,address,uint256,uint8,address)")
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
        vm.expectRevert(abi.encodeWithSelector(Adapter8004.NotController.selector, eve, agentId));
        record.setMetadata(agentId, "k", bytes("bad"));

        vm.prank(eve);
        vm.expectRevert(abi.encodeWithSelector(Adapter8004.NotController.selector, eve, agentId));
        record.setAgentURI(agentId, "ipfs://bad");

        vm.prank(eve);
        vm.expectRevert(abi.encodeWithSelector(Adapter8004.NotController.selector, eve, agentId));
        record.unsetAgentWallet(agentId);
    }

    // ---------------------------------------------------------------------
    // (b) Read-revert forwarding from the underlying registry
    // ---------------------------------------------------------------------

    /// @dev These used to swap the registry under the live adapter. The registry is fixed at
    /// construction since `0.0.17`, so each builds a whole adapter on the reverting registry
    /// instead. The property under test is unchanged: a view must bubble the registry's revert
    /// rather than swallow it and answer zero.
    function _onReverting() private returns (Adapter8004) {
        RevertingRegistry reverting = new RevertingRegistry();
        return Adapter8004(
            address(
                new ERC1967Proxy(
                    address(new Adapter8004(address(reverting))), abi.encodeCall(Adapter8004.initialize, (admin))
                )
            )
        );
    }

    function testGetMetadataForwardsRegistryRevert() external {
        Adapter8004 reverting = _onReverting();
        vm.expectRevert(bytes("getMetadata reverted"));
        reverting.getMetadata(0, "any");
    }

    function testGetAgentWalletForwardsRegistryRevert() external {
        Adapter8004 reverting = _onReverting();
        vm.expectRevert(bytes("getAgentWallet reverted"));
        reverting.getAgentWallet(0);
    }

    function testOwnerOfForwardsRegistryRevert() external {
        Adapter8004 reverting = _onReverting();
        vm.expectRevert(bytes("ownerOf reverted"));
        reverting.ownerOf(0);
    }

    function testTokenURIForwardsRegistryRevert() external {
        Adapter8004 reverting = _onReverting();
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
        return adapter.register(IERCAgentBindings.TokenStandard.ERC721, address(token721), tokenId, agentURI, empty);
    }
}

/// @notice Minimal IERC8004IdentityRegistry stub whose view functions all revert,
/// used to verify Adapter8004 propagates registry-side read failures faithfully.
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
