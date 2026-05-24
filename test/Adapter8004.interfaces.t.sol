// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Test} from "forge-std/Test.sol";
import {ERC1967Proxy} from "@openzeppelin/contracts/proxy/ERC1967/ERC1967Proxy.sol";
import {Adapter8004} from "../src/Adapter8004.sol";
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

        Adapter8004 implementation = new Adapter8004();
        ERC1967Proxy proxy = new ERC1967Proxy(
            address(implementation), abi.encodeCall(Adapter8004.initialize, (address(registry), admin))
        );
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

    function testGetMetadataForwardsRegistryRevert() external {
        RevertingRegistry reverting = new RevertingRegistry();
        vm.prank(admin);
        adapter.setIdentityRegistry(address(reverting));

        vm.expectRevert(bytes("getMetadata reverted"));
        adapter.getMetadata(0, "any");
    }

    function testGetAgentWalletForwardsRegistryRevert() external {
        RevertingRegistry reverting = new RevertingRegistry();
        vm.prank(admin);
        adapter.setIdentityRegistry(address(reverting));

        vm.expectRevert(bytes("getAgentWallet reverted"));
        adapter.getAgentWallet(0);
    }

    function testOwnerOfForwardsRegistryRevert() external {
        RevertingRegistry reverting = new RevertingRegistry();
        vm.prank(admin);
        adapter.setIdentityRegistry(address(reverting));

        vm.expectRevert(bytes("ownerOf reverted"));
        adapter.ownerOf(0);
    }

    function testTokenURIForwardsRegistryRevert() external {
        RevertingRegistry reverting = new RevertingRegistry();
        vm.prank(admin);
        adapter.setIdentityRegistry(address(reverting));

        vm.expectRevert(bytes("tokenURI reverted"));
        adapter.tokenURI(0);
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
