// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Test} from "forge-std/Test.sol";
import {Vm} from "forge-std/Vm.sol";
import {ERC1967Proxy} from "@openzeppelin/contracts/proxy/ERC1967/ERC1967Proxy.sol";
import {IERC721} from "@openzeppelin/contracts/token/ERC721/IERC721.sol";
import {Adapter8004} from "../src/Adapter8004.sol";
import {IERC8004AdapterCounterfactual} from "../src/interfaces/IERC8004AdapterCounterfactual.sol";
import {IERCAgentBindings} from "../src/interfaces/IERCAgentBindings.sol";
import {IERC8004IdentityRegistry} from "../src/interfaces/IERC8004IdentityRegistry.sol";
import {MockIdentityRegistry} from "./mocks/MockIdentityRegistry.sol";
import {MockERC721} from "./mocks/MockERC721.sol";
import {MockERC1155} from "./mocks/MockERC1155.sol";
import {MockERC1155F} from "./mocks/MockERC1155F.sol";
import {MockERC6909} from "./mocks/MockERC6909.sol";
import {MockERC6909F} from "./mocks/MockERC6909F.sol";

contract Adapter8004Test is Test {
    bytes32 internal constant DOMAIN_TYPEHASH =
        keccak256("EIP712Domain(string name,string version,uint256 chainId,address verifyingContract)");
    bytes32 internal constant AGENT_WALLET_SET_TYPEHASH =
        keccak256("AgentWalletSet(uint256 agentId,address newWallet,address owner,uint256 deadline)");

    MockIdentityRegistry internal registry;
    MockIdentityRegistry internal registry2;
    Adapter8004 internal adapter;
    MockERC721 internal token721;
    MockERC1155 internal token1155;
    MockERC1155F internal token1155F;
    MockERC6909 internal token6909;
    MockERC6909F internal token6909F;

    uint256 internal alicePk = 0xA11CE;
    uint256 internal bobPk = 0xB0B;
    uint256 internal walletPk = 0xCAFE;
    uint256 internal evePk = 0xE0E;

    address internal alice;
    address internal bob;
    address internal wallet;
    address internal eve;
    address internal admin;

    function setUp() external {
        alice = vm.addr(alicePk);
        bob = vm.addr(bobPk);
        wallet = vm.addr(walletPk);
        eve = vm.addr(evePk);
        admin = makeAddr("admin");

        registry = new MockIdentityRegistry();
        registry2 = new MockIdentityRegistry();

        Adapter8004 implementation = new Adapter8004();
        ERC1967Proxy proxy = new ERC1967Proxy(
            address(implementation), abi.encodeCall(Adapter8004.initialize, (address(registry), admin))
        );
        adapter = Adapter8004(address(proxy));

        token721 = new MockERC721();
        token1155 = new MockERC1155();
        token1155F = new MockERC1155F();
        token6909 = new MockERC6909();
        token6909F = new MockERC6909F();

        token721.mint(alice, 1);
        token721.mint(bob, 2);
        token1155.mint(alice, 10, 5);
        token1155F.mint(alice, 50);
        token6909.mint(alice, 42, 3);
        token6909F.mint(alice, 60);
    }

    function testInitializeSetsAdminAndRegistry() external view {
        assertEq(adapter.owner(), admin);
        assertEq(address(adapter.identityRegistry()), address(registry));
    }

    function testRegisters721AndClearsInitialAdapterWallet() external {
        IERC8004IdentityRegistry.MetadataEntry[] memory metadata = new IERC8004IdentityRegistry.MetadataEntry[](1);
        metadata[0] = IERC8004IdentityRegistry.MetadataEntry({metadataKey: "name", metadataValue: bytes("alpha")});

        vm.prank(alice);
        uint256 agentId =
            adapter.register(IERCAgentBindings.TokenStandard.ERC721, address(token721), 1, "ipfs://agent/1", metadata);

        assertEq(registry.ownerOf(agentId), address(adapter));
        assertEq(registry.tokenURI(agentId), "ipfs://agent/1");
        assertEq(string(registry.getMetadata(agentId, "name")), "alpha");
        assertEq(registry.getAgentWallet(agentId), address(0));
        assertEq(registry.getMetadata(agentId, adapter.BINDING_METADATA_KEY()), abi.encodePacked(address(adapter)));

        assertEq(adapter.ownerOf(agentId), registry.ownerOf(agentId));
        assertEq(adapter.tokenURI(agentId), registry.tokenURI(agentId));
        assertEq(adapter.getMetadata(agentId, "name"), registry.getMetadata(agentId, "name"));
        assertEq(adapter.getAgentWallet(agentId), registry.getAgentWallet(agentId));
        assertEq(
            adapter.getMetadata(agentId, adapter.BINDING_METADATA_KEY()),
            registry.getMetadata(agentId, adapter.BINDING_METADATA_KEY())
        );
    }

    function test721ControllerCanUpdateRegistryFields() external {
        uint256 agentId = _register721(alice, 1);

        vm.startPrank(alice);
        adapter.setAgentURI(agentId, "ipfs://agent/updated");
        adapter.setMetadata(agentId, "description", bytes("new"));
        vm.stopPrank();

        assertEq(registry.tokenURI(agentId), "ipfs://agent/updated");
        assertEq(string(registry.getMetadata(agentId, "description")), "new");
    }

    function test721ControlFollowsTokenTransfer() external {
        uint256 agentId = _register721(alice, 1);

        vm.prank(alice);
        token721.transferFrom(alice, bob, 1);

        vm.prank(alice);
        vm.expectRevert(abi.encodeWithSelector(Adapter8004.NotController.selector, alice, agentId));
        adapter.setMetadata(agentId, "x", bytes("1"));

        vm.prank(bob);
        adapter.setMetadata(agentId, "x", bytes("2"));

        assertEq(string(registry.getMetadata(agentId, "x")), "2");
    }

    function test1155ControlIsAnyCurrentHolder() external {
        uint256 agentId = _register1155(alice, 10);

        vm.prank(alice);
        token1155.safeTransferFrom(alice, bob, 10, 1, "");

        vm.prank(bob);
        adapter.setMetadata(agentId, "holder", bytes("bob"));

        assertEq(string(registry.getMetadata(agentId, "holder")), "bob");
    }

    function test6909ControlIsAnyCurrentHolder() external {
        uint256 agentId = _register6909(alice, 42);

        vm.prank(alice);
        token6909.transfer(bob, 42, 1);

        vm.prank(bob);
        adapter.setMetadata(agentId, "holder", bytes("bob"));

        assertEq(string(registry.getMetadata(agentId, "holder")), "bob");
    }

    function test1155FControlUsesOwnerOfAndFollowsTransfer() external {
        uint256 agentId = _register1155F(alice, 50);

        vm.prank(bob);
        vm.expectRevert(abi.encodeWithSelector(Adapter8004.NotController.selector, bob, agentId));
        adapter.setMetadata(agentId, "holder", bytes("bob"));

        vm.prank(alice);
        token1155F.transferOwner(alice, bob, 50);

        assertFalse(adapter.isController(agentId, alice));
        assertTrue(adapter.isController(agentId, bob));

        vm.prank(bob);
        adapter.setMetadata(agentId, "holder", bytes("bob"));

        assertEq(string(registry.getMetadata(agentId, "holder")), "bob");
    }

    function test6909FControlUsesOwnerOfAndFollowsTransfer() external {
        uint256 agentId = _register6909F(alice, 60);

        vm.prank(alice);
        token6909F.transferOwner(alice, bob, 60);

        vm.prank(alice);
        vm.expectRevert(abi.encodeWithSelector(Adapter8004.NotController.selector, alice, agentId));
        adapter.setMetadata(agentId, "holder", bytes("alice"));

        vm.prank(bob);
        adapter.setMetadata(agentId, "holder", bytes("bob"));

        assertEq(string(registry.getMetadata(agentId, "holder")), "bob");
    }

    function testCannotRegisterWithoutCurrentTokenControl() external {
        vm.prank(eve);
        vm.expectRevert(abi.encodeWithSelector(Adapter8004.NotController.selector, eve, type(uint256).max));
        adapter.register(IERCAgentBindings.TokenStandard.ERC721, address(token721), 1, "", _emptyMetadata());
    }

    function testRegisterNoMetadataOverloadProducesIdenticalBinding() external {
        vm.prank(alice);
        uint256 agentId =
            adapter.register(IERCAgentBindings.TokenStandard.ERC721, address(token721), 1, "ipfs://agent/1");

        assertEq(registry.ownerOf(agentId), address(adapter));
        assertEq(registry.tokenURI(agentId), "ipfs://agent/1");
        assertEq(registry.getAgentWallet(agentId), address(0));
        assertEq(registry.getMetadata(agentId, adapter.BINDING_METADATA_KEY()), abi.encodePacked(address(adapter)));

        IERCAgentBindings.Binding memory binding = adapter.bindingOf(agentId);
        assertEq(uint8(binding.standard), uint8(IERCAgentBindings.TokenStandard.ERC721));
        assertEq(binding.tokenContract, address(token721));
        assertEq(binding.tokenId, 1);
    }

    function testRegisterNoMetadataOverloadEnforcesTokenControl() external {
        vm.prank(eve);
        vm.expectRevert(abi.encodeWithSelector(Adapter8004.NotController.selector, eve, type(uint256).max));
        adapter.register(IERCAgentBindings.TokenStandard.ERC721, address(token721), 1, "");
    }

    function testSameTokenCanRegisterMultipleAgents() external {
        uint256 firstAgentId = _register721(alice, 1);

        vm.prank(alice);
        uint256 secondAgentId =
            adapter.register(IERCAgentBindings.TokenStandard.ERC721, address(token721), 1, "", _emptyMetadata());

        assertEq(firstAgentId, 0);
        assertEq(secondAgentId, 1);

        IERCAgentBindings.Binding memory firstBinding = adapter.bindingOf(firstAgentId);
        IERCAgentBindings.Binding memory secondBinding = adapter.bindingOf(secondAgentId);
        assertEq(firstBinding.tokenContract, address(token721));
        assertEq(secondBinding.tokenContract, address(token721));
        assertEq(firstBinding.tokenId, 1);
        assertEq(secondBinding.tokenId, 1);
    }

    function testSetMetadataBatch() external {
        uint256 agentId = _register721(alice, 1);

        IERC8004IdentityRegistry.MetadataEntry[] memory metadata = new IERC8004IdentityRegistry.MetadataEntry[](2);
        metadata[0] = IERC8004IdentityRegistry.MetadataEntry({metadataKey: "a", metadataValue: bytes("1")});
        metadata[1] = IERC8004IdentityRegistry.MetadataEntry({metadataKey: "b", metadataValue: bytes("2")});

        vm.prank(alice);
        adapter.setMetadataBatch(agentId, metadata);

        assertEq(string(registry.getMetadata(agentId, "a")), "1");
        assertEq(string(registry.getMetadata(agentId, "b")), "2");
    }

    function testBindingMetadataEncodingIsTwentyByteAddress() external view {
        address binding = address(adapter);
        bytes memory encoded = abi.encodePacked(binding);
        assertEq(encoded.length, 20);
        assertEq(encoded, abi.encodePacked(binding));
    }

    function testBindingVerifierRoundTripUsesStoredBindingContract() external {
        uint256 agentId = _register721(alice, 1);

        bytes memory stored = registry.getMetadata(agentId, adapter.BINDING_METADATA_KEY());
        assertEq(stored.length, 20);

        address bindingContract = address(bytes20(stored));
        IERCAgentBindings.Binding memory binding = IERCAgentBindings(bindingContract).bindingOf(agentId);

        assertEq(uint256(binding.standard), uint256(IERCAgentBindings.TokenStandard.ERC721));
        assertEq(binding.tokenContract, address(token721));
        assertEq(binding.tokenId, 1);
    }

    function testAdapterImplementsIERCAgentBindingsInterface() external {
        uint256 agentId = _register721(alice, 1);

        IERCAgentBindings bindings = IERCAgentBindings(address(adapter));
        IERCAgentBindings.Binding memory binding = bindings.bindingOf(agentId);

        assertEq(uint256(binding.standard), uint256(IERCAgentBindings.TokenStandard.ERC721));
        assertEq(binding.tokenContract, address(token721));
        assertEq(binding.tokenId, 1);
    }

    function testRewriteBindingMetadataRewritesLegacyPayloadToTwentyBytes() external {
        uint256 agentId = _register721(alice, 1);
        string memory key = adapter.BINDING_METADATA_KEY();
        bytes memory legacy =
            _encodeLegacyBindingMetadata(address(adapter), IERCAgentBindings.TokenStandard.ERC721, address(token721), 1);
        assertGt(legacy.length, 20);

        vm.prank(address(adapter));
        registry.setMetadata(agentId, key, legacy);
        assertEq(registry.getMetadata(agentId, key), legacy);

        vm.prank(admin);
        adapter.rewriteBindingMetadata(agentId);

        bytes memory stored = registry.getMetadata(agentId, key);
        assertEq(stored.length, 20);
        assertEq(stored, abi.encodePacked(address(adapter)));
    }

    function testRegisterRejectsReservedBindingMetadataKey() external {
        IERC8004IdentityRegistry.MetadataEntry[] memory metadata = new IERC8004IdentityRegistry.MetadataEntry[](1);
        metadata[0] = IERC8004IdentityRegistry.MetadataEntry({
            metadataKey: adapter.BINDING_METADATA_KEY(),
            metadataValue: bytes("bad")
        });

        vm.expectRevert(
            abi.encodeWithSelector(Adapter8004.ReservedMetadataKey.selector, adapter.BINDING_METADATA_KEY())
        );
        vm.prank(alice);
        adapter.register(IERCAgentBindings.TokenStandard.ERC721, address(token721), 1, "", metadata);
    }

    function testSetMetadataRejectsReservedBindingMetadataKey() external {
        uint256 agentId = _register721(alice, 1);
        string memory key = adapter.BINDING_METADATA_KEY();

        vm.expectRevert(abi.encodeWithSelector(Adapter8004.ReservedMetadataKey.selector, key));
        vm.prank(alice);
        adapter.setMetadata(agentId, key, bytes("bad"));
    }

    function testSetMetadataBatchRejectsReservedBindingMetadataKey() external {
        uint256 agentId = _register721(alice, 1);

        IERC8004IdentityRegistry.MetadataEntry[] memory metadata = new IERC8004IdentityRegistry.MetadataEntry[](1);
        metadata[0] = IERC8004IdentityRegistry.MetadataEntry({
            metadataKey: adapter.BINDING_METADATA_KEY(),
            metadataValue: bytes("bad")
        });

        vm.expectRevert(
            abi.encodeWithSelector(Adapter8004.ReservedMetadataKey.selector, adapter.BINDING_METADATA_KEY())
        );
        vm.prank(alice);
        adapter.setMetadataBatch(agentId, metadata);
    }

    function testSetAgentURIEmitsAdapterEvent() external {
        uint256 agentId = _register721(alice, 1);

        vm.recordLogs();
        vm.prank(alice);
        adapter.setAgentURI(agentId, "ipfs://agent/updated");

        Vm.Log[] memory logs = vm.getRecordedLogs();
        bytes32 topic = keccak256("AgentURISet(uint256,string,address)");
        uint256 matches;
        for (uint256 i; i < logs.length; ++i) {
            if (logs[i].emitter != address(adapter) || logs[i].topics.length == 0) continue;
            if (logs[i].topics[0] == topic) {
                assertEq(logs[i].topics[1], bytes32(agentId));
                assertEq(logs[i].topics[2], bytes32(uint256(uint160(alice))));
                assertEq(abi.decode(logs[i].data, (string)), "ipfs://agent/updated");
                ++matches;
            }
        }
        assertEq(matches, 1, "AgentURISet must fire exactly once from the adapter");
    }

    function testSetMetadataEmitsAdapterEvent() external {
        uint256 agentId = _register721(alice, 1);

        vm.recordLogs();
        vm.prank(alice);
        adapter.setMetadata(agentId, "description", bytes("hello"));

        Vm.Log[] memory logs = vm.getRecordedLogs();
        bytes32 topic = keccak256("MetadataSet(uint256,string,bytes,address)");
        uint256 matches;
        for (uint256 i; i < logs.length; ++i) {
            if (logs[i].emitter != address(adapter) || logs[i].topics.length == 0) continue;
            if (logs[i].topics[0] == topic) {
                assertEq(logs[i].topics[1], bytes32(agentId));
                assertEq(logs[i].topics[2], bytes32(uint256(uint160(alice))));
                (string memory key, bytes memory value) = abi.decode(logs[i].data, (string, bytes));
                assertEq(key, "description");
                assertEq(value, bytes("hello"));
                ++matches;
            }
        }
        assertEq(matches, 1, "MetadataSet must fire exactly once from the adapter");
    }

    function testSetAgentWalletEmitsAdapterEvent() external {
        uint256 agentId = _register721(alice, 1);
        uint256 deadline = block.timestamp + 4 minutes;
        bytes memory signature = _signAgentWallet(agentId, wallet, address(adapter), deadline, walletPk);

        vm.recordLogs();
        vm.prank(alice);
        adapter.setAgentWallet(agentId, wallet, deadline, signature);

        Vm.Log[] memory logs = vm.getRecordedLogs();
        bytes32 topic = keccak256("AgentWalletSet(uint256,address,address)");
        uint256 matches;
        for (uint256 i; i < logs.length; ++i) {
            if (logs[i].emitter != address(adapter) || logs[i].topics.length == 0) continue;
            if (logs[i].topics[0] == topic) {
                assertEq(logs[i].topics[1], bytes32(agentId));
                assertEq(logs[i].topics[2], bytes32(uint256(uint160(wallet))));
                assertEq(logs[i].topics[3], bytes32(uint256(uint160(alice))));
                ++matches;
            }
        }
        assertEq(matches, 1, "AgentWalletSet must fire exactly once from the adapter");
    }

    function testUnsetAgentWalletEmitsAdapterEvent() external {
        uint256 agentId = _register721(alice, 1);

        vm.recordLogs();
        vm.prank(alice);
        adapter.unsetAgentWallet(agentId);

        Vm.Log[] memory logs = vm.getRecordedLogs();
        bytes32 topic = keccak256("AgentWalletUnset(uint256,address)");
        uint256 matches;
        for (uint256 i; i < logs.length; ++i) {
            if (logs[i].emitter != address(adapter) || logs[i].topics.length == 0) continue;
            if (logs[i].topics[0] == topic) {
                assertEq(logs[i].topics[1], bytes32(agentId));
                assertEq(logs[i].topics[2], bytes32(uint256(uint160(alice))));
                ++matches;
            }
        }
        assertEq(matches, 1, "AgentWalletUnset must fire exactly once from the adapter");
    }

    function testRewriteBindingMetadataEmitsAdapterEvent() external {
        uint256 agentId = _register721(alice, 1);

        vm.recordLogs();
        vm.prank(admin);
        adapter.rewriteBindingMetadata(agentId);

        Vm.Log[] memory logs = vm.getRecordedLogs();
        bytes32 topic = keccak256("BindingMetadataRewritten(uint256,address)");
        uint256 matches;
        for (uint256 i; i < logs.length; ++i) {
            if (logs[i].emitter != address(adapter) || logs[i].topics.length == 0) continue;
            if (logs[i].topics[0] == topic) {
                assertEq(logs[i].topics[1], bytes32(agentId));
                assertEq(logs[i].topics[2], bytes32(uint256(uint160(admin))));
                ++matches;
            }
        }
        assertEq(matches, 1, "BindingMetadataRewritten must fire exactly once from the adapter");
    }

    function testSetAgentWalletPassesThroughNativeSignatureCheck() external {
        uint256 agentId = _register721(alice, 1);
        uint256 deadline = block.timestamp + 4 minutes;
        bytes memory signature = _signAgentWallet(agentId, wallet, address(adapter), deadline, walletPk);

        vm.prank(alice);
        adapter.setAgentWallet(agentId, wallet, deadline, signature);

        assertEq(registry.getAgentWallet(agentId), wallet);
    }

    function testSetAgentWalletRejectsInvalidSignature() external {
        uint256 agentId = _register721(alice, 1);
        uint256 deadline = block.timestamp + 4 minutes;
        bytes memory signature = _signAgentWallet(agentId, wallet, address(adapter), deadline, bobPk);

        vm.prank(alice);
        vm.expectRevert(bytes("invalid wallet sig"));
        adapter.setAgentWallet(agentId, wallet, deadline, signature);
    }

    function testCounterfactualRegisterEmitsEventAndReturnsHash() external {
        IERC8004IdentityRegistry.MetadataEntry[] memory metadata = new IERC8004IdentityRegistry.MetadataEntry[](1);
        metadata[0] = IERC8004IdentityRegistry.MetadataEntry({metadataKey: "name", metadataValue: bytes("alpha")});

        bytes32 expectedHash = keccak256(
            abi.encode(
                block.chainid, address(adapter), IERCAgentBindings.TokenStandard.ERC721, address(token721), uint256(1)
            )
        );

        vm.prank(alice);
        vm.expectEmit(true, true, true, true, address(adapter));
        emit IERC8004AdapterCounterfactual.CounterfactualAgentRegistered(
            expectedHash,
            address(token721),
            1,
            uint8(1),
            IERCAgentBindings.TokenStandard.ERC721,
            "ipfs://agent/cf",
            metadata,
            alice
        );
        bytes32 registrationHash = adapter.counterfactualRegister(
            IERCAgentBindings.TokenStandard.ERC721, address(token721), 1, "ipfs://agent/cf", metadata
        );

        assertEq(registrationHash, expectedHash);
    }

    function testRegistrationHashViewMatchesEncodingAndCounterfactualEventTopic() external {
        bytes32 viewHash = adapter.registrationHash(IERCAgentBindings.TokenStandard.ERC721, address(token721), 1);
        bytes32 expectedHash = keccak256(
            abi.encode(
                block.chainid, address(adapter), IERCAgentBindings.TokenStandard.ERC721, address(token721), uint256(1)
            )
        );
        assertEq(viewHash, expectedHash);

        vm.recordLogs();
        vm.prank(alice);
        bytes32 emittedHash =
            adapter.counterfactualRegister(IERCAgentBindings.TokenStandard.ERC721, address(token721), 1, "ipfs://view");

        Vm.Log[] memory entries = vm.getRecordedLogs();
        assertEq(emittedHash, viewHash);
        assertEq(entries.length, 1);
        assertEq(entries[0].topics[0], IERC8004AdapterCounterfactual.CounterfactualAgentRegistered.selector);
        assertEq(entries[0].topics[1], viewHash);
    }

    function testCounterfactualRegisterEmptyMetadataOverload() external {
        bytes32 expectedHash = keccak256(
            abi.encode(
                block.chainid, address(adapter), IERCAgentBindings.TokenStandard.ERC721, address(token721), uint256(1)
            )
        );

        vm.prank(alice);
        bytes32 registrationHash = adapter.counterfactualRegister(
            IERCAgentBindings.TokenStandard.ERC721, address(token721), 1, "ipfs://agent/cf"
        );

        assertEq(registrationHash, expectedHash);
    }

    function testCounterfactualRegisterRejectsZeroTokenContract() external {
        vm.prank(alice);
        vm.expectRevert(Adapter8004.InvalidTokenContract.selector);
        adapter.counterfactualRegister(
            IERCAgentBindings.TokenStandard.ERC721, address(0), 1, "ipfs://agent/cf", _emptyMetadata()
        );
    }

    function testCounterfactualRegisterRejectsNonController() external {
        vm.prank(eve);
        vm.expectRevert(abi.encodeWithSelector(Adapter8004.NotController.selector, eve, type(uint256).max));
        adapter.counterfactualRegister(
            IERCAgentBindings.TokenStandard.ERC721, address(token721), 1, "ipfs://agent/cf", _emptyMetadata()
        );
    }

    function testCounterfactualRegisterRejectsReservedBindingMetadataKey() external {
        IERC8004IdentityRegistry.MetadataEntry[] memory metadata = new IERC8004IdentityRegistry.MetadataEntry[](1);
        metadata[0] = IERC8004IdentityRegistry.MetadataEntry({
            metadataKey: adapter.BINDING_METADATA_KEY(),
            metadataValue: bytes("bad")
        });

        vm.expectRevert(
            abi.encodeWithSelector(Adapter8004.ReservedMetadataKey.selector, adapter.BINDING_METADATA_KEY())
        );
        vm.prank(alice);
        adapter.counterfactualRegister(
            IERCAgentBindings.TokenStandard.ERC721, address(token721), 1, "ipfs://agent/cf", metadata
        );
    }

    function testCounterfactualRegisterRejectsCfRegistrationKey() external {
        IERC8004IdentityRegistry.MetadataEntry[] memory metadata = new IERC8004IdentityRegistry.MetadataEntry[](1);
        metadata[0] = IERC8004IdentityRegistry.MetadataEntry({
            metadataKey: adapter.CF_REGISTRATION_KEY(),
            metadataValue: bytes("bad")
        });

        vm.expectRevert(abi.encodeWithSelector(Adapter8004.ReservedMetadataKey.selector, adapter.CF_REGISTRATION_KEY()));
        vm.prank(alice);
        adapter.counterfactualRegister(
            IERCAgentBindings.TokenStandard.ERC721, address(token721), 1, "ipfs://agent/cf", metadata
        );
    }

    function testCounterfactualSetAgentURIEmits() external {
        bytes32 expectedHash = keccak256(
            abi.encode(
                block.chainid, address(adapter), IERCAgentBindings.TokenStandard.ERC721, address(token721), uint256(1)
            )
        );

        vm.prank(alice);
        vm.expectEmit(true, true, true, true, address(adapter));
        emit IERC8004AdapterCounterfactual.CounterfactualAgentURISet(
            expectedHash, address(token721), 1, uint8(1), "ipfs://updated", alice
        );
        adapter.counterfactualSetAgentURI(
            IERCAgentBindings.TokenStandard.ERC721, address(token721), 1, "ipfs://updated"
        );
    }

    function testCounterfactualSetAgentURIRejectsZeroTokenContract() external {
        vm.prank(alice);
        vm.expectRevert(Adapter8004.InvalidTokenContract.selector);
        adapter.counterfactualSetAgentURI(IERCAgentBindings.TokenStandard.ERC721, address(0), 1, "ipfs://x");
    }

    function testCounterfactualSetAgentURIRejectsNonController() external {
        vm.prank(eve);
        vm.expectRevert(abi.encodeWithSelector(Adapter8004.NotController.selector, eve, type(uint256).max));
        adapter.counterfactualSetAgentURI(IERCAgentBindings.TokenStandard.ERC721, address(token721), 1, "ipfs://x");
    }

    function testCounterfactualSetMetadataEmits() external {
        bytes32 expectedHash = keccak256(
            abi.encode(
                block.chainid, address(adapter), IERCAgentBindings.TokenStandard.ERC721, address(token721), uint256(1)
            )
        );

        vm.prank(alice);
        vm.expectEmit(true, true, true, true, address(adapter));
        emit IERC8004AdapterCounterfactual.CounterfactualMetadataSet(
            expectedHash, address(token721), 1, uint8(1), "description", bytes("hello"), alice
        );
        adapter.counterfactualSetMetadata(
            IERCAgentBindings.TokenStandard.ERC721, address(token721), 1, "description", bytes("hello")
        );
    }

    function testCounterfactualSetMetadataRejectsZeroTokenContract() external {
        vm.prank(alice);
        vm.expectRevert(Adapter8004.InvalidTokenContract.selector);
        adapter.counterfactualSetMetadata(IERCAgentBindings.TokenStandard.ERC721, address(0), 1, "k", bytes("v"));
    }

    function testCounterfactualSetMetadataRejectsNonController() external {
        vm.prank(eve);
        vm.expectRevert(abi.encodeWithSelector(Adapter8004.NotController.selector, eve, type(uint256).max));
        adapter.counterfactualSetMetadata(IERCAgentBindings.TokenStandard.ERC721, address(token721), 1, "k", bytes("v"));
    }

    function testCounterfactualSetMetadataRejectsReservedBindingMetadataKey() external {
        string memory key = adapter.BINDING_METADATA_KEY();

        vm.expectRevert(abi.encodeWithSelector(Adapter8004.ReservedMetadataKey.selector, key));
        vm.prank(alice);
        adapter.counterfactualSetMetadata(
            IERCAgentBindings.TokenStandard.ERC721, address(token721), 1, key, bytes("bad")
        );
    }

    function testCounterfactualSetMetadataRejectsCfRegistrationKey() external {
        string memory key = adapter.CF_REGISTRATION_KEY();

        vm.expectRevert(abi.encodeWithSelector(Adapter8004.ReservedMetadataKey.selector, key));
        vm.prank(alice);
        adapter.counterfactualSetMetadata(
            IERCAgentBindings.TokenStandard.ERC721, address(token721), 1, key, bytes("bad")
        );
    }

    function testCounterfactualSetMetadataBatchEmits() external {
        bytes32 expectedHash = keccak256(
            abi.encode(
                block.chainid, address(adapter), IERCAgentBindings.TokenStandard.ERC721, address(token721), uint256(1)
            )
        );

        IERC8004IdentityRegistry.MetadataEntry[] memory metadata = new IERC8004IdentityRegistry.MetadataEntry[](2);
        metadata[0] = IERC8004IdentityRegistry.MetadataEntry({metadataKey: "a", metadataValue: bytes("1")});
        metadata[1] = IERC8004IdentityRegistry.MetadataEntry({metadataKey: "b", metadataValue: bytes("2")});

        vm.prank(alice);
        vm.expectEmit(true, true, true, true, address(adapter));
        emit IERC8004AdapterCounterfactual.CounterfactualMetadataBatchSet(
            expectedHash, address(token721), 1, uint8(1), metadata, alice
        );
        adapter.counterfactualSetMetadataBatch(IERCAgentBindings.TokenStandard.ERC721, address(token721), 1, metadata);
    }

    function testCounterfactualSetMetadataBatchRejectsZeroTokenContract() external {
        vm.prank(alice);
        vm.expectRevert(Adapter8004.InvalidTokenContract.selector);
        adapter.counterfactualSetMetadataBatch(IERCAgentBindings.TokenStandard.ERC721, address(0), 1, _emptyMetadata());
    }

    function testCounterfactualSetMetadataBatchRejectsNonController() external {
        IERC8004IdentityRegistry.MetadataEntry[] memory metadata = new IERC8004IdentityRegistry.MetadataEntry[](1);
        metadata[0] = IERC8004IdentityRegistry.MetadataEntry({metadataKey: "a", metadataValue: bytes("1")});

        vm.prank(eve);
        vm.expectRevert(abi.encodeWithSelector(Adapter8004.NotController.selector, eve, type(uint256).max));
        adapter.counterfactualSetMetadataBatch(IERCAgentBindings.TokenStandard.ERC721, address(token721), 1, metadata);
    }

    function testCounterfactualSetMetadataBatchRejectsReservedBindingMetadataKey() external {
        IERC8004IdentityRegistry.MetadataEntry[] memory metadata = new IERC8004IdentityRegistry.MetadataEntry[](1);
        metadata[0] = IERC8004IdentityRegistry.MetadataEntry({
            metadataKey: adapter.BINDING_METADATA_KEY(),
            metadataValue: bytes("bad")
        });

        vm.expectRevert(
            abi.encodeWithSelector(Adapter8004.ReservedMetadataKey.selector, adapter.BINDING_METADATA_KEY())
        );
        vm.prank(alice);
        adapter.counterfactualSetMetadataBatch(IERCAgentBindings.TokenStandard.ERC721, address(token721), 1, metadata);
    }

    function testCounterfactualSetMetadataBatchRejectsCfRegistrationKey() external {
        IERC8004IdentityRegistry.MetadataEntry[] memory metadata = new IERC8004IdentityRegistry.MetadataEntry[](1);
        metadata[0] = IERC8004IdentityRegistry.MetadataEntry({
            metadataKey: adapter.CF_REGISTRATION_KEY(),
            metadataValue: bytes("bad")
        });

        vm.expectRevert(abi.encodeWithSelector(Adapter8004.ReservedMetadataKey.selector, adapter.CF_REGISTRATION_KEY()));
        vm.prank(alice);
        adapter.counterfactualSetMetadataBatch(IERCAgentBindings.TokenStandard.ERC721, address(token721), 1, metadata);
    }

    function testCounterfactualSetAgentWalletEmits() external {
        bytes32 expectedHash = keccak256(
            abi.encode(
                block.chainid, address(adapter), IERCAgentBindings.TokenStandard.ERC721, address(token721), uint256(1)
            )
        );

        vm.prank(alice);
        vm.expectEmit(true, true, true, true, address(adapter));
        emit IERC8004AdapterCounterfactual.CounterfactualAgentWalletSet(
            expectedHash, address(token721), 1, uint8(1), wallet, alice
        );
        adapter.counterfactualSetAgentWallet(IERCAgentBindings.TokenStandard.ERC721, address(token721), 1, wallet);
    }

    function testCounterfactualSetAgentWalletRejectsZeroTokenContract() external {
        vm.prank(alice);
        vm.expectRevert(Adapter8004.InvalidTokenContract.selector);
        adapter.counterfactualSetAgentWallet(IERCAgentBindings.TokenStandard.ERC721, address(0), 1, wallet);
    }

    function testCounterfactualSetAgentWalletRejectsNonController() external {
        vm.prank(eve);
        vm.expectRevert(abi.encodeWithSelector(Adapter8004.NotController.selector, eve, type(uint256).max));
        adapter.counterfactualSetAgentWallet(IERCAgentBindings.TokenStandard.ERC721, address(token721), 1, wallet);
    }

    function testCounterfactualUnsetAgentWalletEmits() external {
        bytes32 expectedHash = keccak256(
            abi.encode(
                block.chainid, address(adapter), IERCAgentBindings.TokenStandard.ERC721, address(token721), uint256(1)
            )
        );

        vm.prank(alice);
        vm.expectEmit(true, true, true, true, address(adapter));
        emit IERC8004AdapterCounterfactual.CounterfactualAgentWalletUnset(
            expectedHash, address(token721), 1, uint8(1), alice
        );
        adapter.counterfactualUnsetAgentWallet(IERCAgentBindings.TokenStandard.ERC721, address(token721), 1);
    }

    function testCounterfactualUnsetAgentWalletRejectsZeroTokenContract() external {
        vm.prank(alice);
        vm.expectRevert(Adapter8004.InvalidTokenContract.selector);
        adapter.counterfactualUnsetAgentWallet(IERCAgentBindings.TokenStandard.ERC721, address(0), 1);
    }

    function testCounterfactualUnsetAgentWalletRejectsNonController() external {
        vm.prank(eve);
        vm.expectRevert(abi.encodeWithSelector(Adapter8004.NotController.selector, eve, type(uint256).max));
        adapter.counterfactualUnsetAgentWallet(IERCAgentBindings.TokenStandard.ERC721, address(token721), 1);
    }

    function testCounterfactualRegistrationHashIsStableForSameInputs() external {
        vm.prank(alice);
        bytes32 first =
            adapter.counterfactualRegister(IERCAgentBindings.TokenStandard.ERC721, address(token721), 1, "u1");

        vm.prank(alice);
        bytes32 second =
            adapter.counterfactualRegister(IERCAgentBindings.TokenStandard.ERC721, address(token721), 1, "u2");

        assertEq(first, second);
    }

    function testCounterfactualRegistrationHashChangesWithTokenContract() external {
        vm.prank(alice);
        bytes32 viaToken721 =
            adapter.counterfactualRegister(IERCAgentBindings.TokenStandard.ERC721, address(token721), 1, "u");
        vm.prank(alice);
        bytes32 viaToken1155 =
            adapter.counterfactualRegister(IERCAgentBindings.TokenStandard.ERC1155, address(token1155), 10, "u");

        assertTrue(viaToken721 != viaToken1155);
    }

    function testCounterfactualRegistrationHashChangesWithTokenId() external {
        vm.prank(alice);
        bytes32 forId1 =
            adapter.counterfactualRegister(IERCAgentBindings.TokenStandard.ERC721, address(token721), 1, "u");
        vm.prank(bob);
        bytes32 forId2 =
            adapter.counterfactualRegister(IERCAgentBindings.TokenStandard.ERC721, address(token721), 2, "u");

        assertTrue(forId1 != forId2);
    }

    function testCounterfactualRegistrationHashChangesWithChainId() external {
        bytes32 atDefaultChain = keccak256(
            abi.encode(
                block.chainid, address(adapter), IERCAgentBindings.TokenStandard.ERC721, address(token721), uint256(1)
            )
        );
        bytes32 atOtherChain = keccak256(
            abi.encode(
                uint256(424242), address(adapter), IERCAgentBindings.TokenStandard.ERC721, address(token721), uint256(1)
            )
        );

        assertTrue(atDefaultChain != atOtherChain);

        vm.chainId(424242);
        vm.prank(alice);
        bytes32 onAltChain =
            adapter.counterfactualRegister(IERCAgentBindings.TokenStandard.ERC721, address(token721), 1, "u");
        assertEq(onAltChain, atOtherChain);
    }

    function testRegistrationHashIncludesStandard() external view {
        bytes32 h721 = adapter.registrationHash(IERCAgentBindings.TokenStandard.ERC721, address(token721), 1);
        bytes32 h1155 = adapter.registrationHash(IERCAgentBindings.TokenStandard.ERC1155, address(token721), 1);

        assertNotEq(h721, h1155);
    }

    function testHybridTokenContractProducesDistinctHashesPerStandard() external {
        HybridERC721ERC1155 hybrid = new HybridERC721ERC1155();
        hybrid.mint721(alice, 77);
        hybrid.mint1155(alice, 77, 1);

        bytes32 h721 = adapter.registrationHash(IERCAgentBindings.TokenStandard.ERC721, address(hybrid), 77);
        bytes32 h1155 = adapter.registrationHash(IERCAgentBindings.TokenStandard.ERC1155, address(hybrid), 77);
        assertNotEq(h721, h1155);

        vm.startPrank(alice);
        uint256 agent721 = adapter.register(IERCAgentBindings.TokenStandard.ERC721, address(hybrid), 77, "ipfs://721");
        uint256 agent1155 =
            adapter.register(IERCAgentBindings.TokenStandard.ERC1155, address(hybrid), 77, "ipfs://1155");
        bytes32 cf721 =
            adapter.counterfactualRegister(IERCAgentBindings.TokenStandard.ERC721, address(hybrid), 77, "ipfs://cf721");
        bytes32 cf1155 = adapter.counterfactualRegister(
            IERCAgentBindings.TokenStandard.ERC1155, address(hybrid), 77, "ipfs://cf1155"
        );
        vm.stopPrank();

        assertEq(cf721, h721);
        assertEq(cf1155, h1155);
        assertNotEq(agent721, agent1155);
        assertEq(uint8(adapter.bindingOf(agent721).standard), uint8(IERCAgentBindings.TokenStandard.ERC721));
        assertEq(uint8(adapter.bindingOf(agent1155).standard), uint8(IERCAgentBindings.TokenStandard.ERC1155));
    }

    function testCounterfactualRegistrationHashChangesWithAdapterAddress() external {
        Adapter8004 implementation = new Adapter8004();
        ERC1967Proxy proxy = new ERC1967Proxy(
            address(implementation), abi.encodeCall(Adapter8004.initialize, (address(registry), admin))
        );
        Adapter8004 secondAdapter = Adapter8004(address(proxy));

        vm.prank(alice);
        bytes32 fromFirst =
            adapter.counterfactualRegister(IERCAgentBindings.TokenStandard.ERC721, address(token721), 1, "u");
        vm.prank(alice);
        bytes32 fromSecond =
            secondAdapter.counterfactualRegister(IERCAgentBindings.TokenStandard.ERC721, address(token721), 1, "u");

        assertTrue(fromFirst != fromSecond);
        assertTrue(address(adapter) != address(secondAdapter));
    }

    function testAdminCanUpdateRegistryReference() external {
        vm.prank(admin);
        adapter.setIdentityRegistry(address(registry2));

        assertEq(address(adapter.identityRegistry()), address(registry2));

        vm.prank(alice);
        uint256 agentId = adapter.register(
            IERCAgentBindings.TokenStandard.ERC721, address(token721), 1, "ipfs://agent/new", _emptyMetadata()
        );

        assertEq(registry2.ownerOf(agentId), address(adapter));
        assertEq(registry2.tokenURI(agentId), "ipfs://agent/new");
    }

    function testNonAdminCannotUpdateRegistryReference() external {
        vm.prank(alice);
        vm.expectRevert();
        adapter.setIdentityRegistry(address(registry2));
    }

    function testAdminCanUpgradeImplementation() external {
        Adapter8004V2 nextImplementation = new Adapter8004V2();

        vm.prank(admin);
        adapter.upgradeToAndCall(address(nextImplementation), bytes(""));

        assertEq(Adapter8004V2(address(adapter)).version(), "2");
        assertEq(address(adapter.identityRegistry()), address(registry));
        assertEq(adapter.owner(), admin);
    }

    function testNonAdminCannotUpgradeImplementation() external {
        Adapter8004V2 nextImplementation = new Adapter8004V2();

        vm.prank(alice);
        vm.expectRevert();
        adapter.upgradeToAndCall(address(nextImplementation), bytes(""));
    }

    // -----------------------------------------------------------------
    // bindExisting
    // -----------------------------------------------------------------

    function testBindExistingHappyPathWithPerTokenApproval() external {
        // Alice mints an ERC-8004 identity directly on the registry, writes URI + non-binding
        // metadata, approves the adapter, then binds her existing agent to token721 tokenId 1.
        vm.prank(alice);
        uint256 agentId = registry.register("ipfs://pre-bind");

        vm.prank(alice);
        registry.setMetadata(agentId, "name", bytes("alice-agent"));

        vm.prank(alice);
        IERC721(address(registry)).approve(address(adapter), agentId);

        vm.expectEmit(true, true, true, true, address(adapter));
        emit Adapter8004.AgentBound(agentId, IERCAgentBindings.TokenStandard.ERC721, address(token721), 1, alice);
        vm.prank(alice);
        adapter.bindExisting(agentId, IERCAgentBindings.TokenStandard.ERC721, address(token721), 1);

        // Registry owner is now the adapter; URI and non-binding metadata are preserved.
        assertEq(registry.ownerOf(agentId), address(adapter));
        assertEq(registry.tokenURI(agentId), "ipfs://pre-bind");
        assertEq(string(registry.getMetadata(agentId, "name")), "alice-agent");

        // Canonical binding metadata points at the adapter; agent wallet cleared.
        assertEq(registry.getMetadata(agentId, adapter.BINDING_METADATA_KEY()), abi.encodePacked(address(adapter)));
        assertEq(registry.getAgentWallet(agentId), address(0));

        // bindingOf reflects the supplied external token.
        IERCAgentBindings.Binding memory b = adapter.bindingOf(agentId);
        assertEq(uint8(b.standard), uint8(IERCAgentBindings.TokenStandard.ERC721));
        assertEq(b.tokenContract, address(token721));
        assertEq(b.tokenId, 1);
    }

    function testBindExistingOperatorApprovalPath() external {
        vm.prank(alice);
        uint256 agentId = registry.register("ipfs://op-approval");

        vm.prank(alice);
        IERC721(address(registry)).setApprovalForAll(address(adapter), true);

        vm.prank(alice);
        adapter.bindExisting(agentId, IERCAgentBindings.TokenStandard.ERC721, address(token721), 1);

        assertEq(registry.ownerOf(agentId), address(adapter));
        assertEq(registry.getMetadata(agentId, adapter.BINDING_METADATA_KEY()), abi.encodePacked(address(adapter)));
    }

    function testBindExistingRejectsZeroTokenContract() external {
        vm.prank(alice);
        uint256 agentId = registry.register("");

        vm.prank(alice);
        IERC721(address(registry)).approve(address(adapter), agentId);

        vm.prank(alice);
        vm.expectRevert(Adapter8004.InvalidTokenContract.selector);
        adapter.bindExisting(agentId, IERCAgentBindings.TokenStandard.ERC721, address(0), 1);
    }

    function testBindExistingRejectsRegistryAsTokenContract() external {
        // Alice mints an agent and approves the adapter, then tries to bind the agent to the
        // identity registry itself with `tokenId == agentId`. Without the registry-as-tokenContract
        // reject, the bind would succeed and the agent would be permanently uncontrollable
        // because `ownerOf` on the registry resolves to the adapter post-transfer.
        vm.prank(alice);
        uint256 agentId = registry.register("");

        vm.prank(alice);
        IERC721(address(registry)).approve(address(adapter), agentId);

        vm.prank(alice);
        vm.expectRevert(Adapter8004.InvalidTokenContractIsRegistry.selector);
        adapter.bindExisting(agentId, IERCAgentBindings.TokenStandard.ERC721, address(registry), agentId);

        // The registry still owns the agent; nothing was bound.
        assertEq(registry.ownerOf(agentId), alice);
    }

    function testRegisterRejectsRegistryAsTokenContract() external {
        vm.prank(alice);
        vm.expectRevert(Adapter8004.InvalidTokenContractIsRegistry.selector);
        adapter.register(IERCAgentBindings.TokenStandard.ERC721, address(registry), 0, "", _emptyMetadata());
    }

    function testCounterfactualRegisterRejectsRegistryAsTokenContract() external {
        vm.prank(alice);
        vm.expectRevert(Adapter8004.InvalidTokenContractIsRegistry.selector);
        adapter.counterfactualRegister(
            IERCAgentBindings.TokenStandard.ERC721, address(registry), 0, "ipfs://agent/cf", _emptyMetadata()
        );
    }

    function testCounterfactualSetAgentURIRejectsRegistryAsTokenContract() external {
        vm.prank(alice);
        vm.expectRevert(Adapter8004.InvalidTokenContractIsRegistry.selector);
        adapter.counterfactualSetAgentURI(IERCAgentBindings.TokenStandard.ERC721, address(registry), 0, "u");
    }

    function testCounterfactualSetMetadataRejectsRegistryAsTokenContract() external {
        vm.prank(alice);
        vm.expectRevert(Adapter8004.InvalidTokenContractIsRegistry.selector);
        adapter.counterfactualSetMetadata(IERCAgentBindings.TokenStandard.ERC721, address(registry), 0, "k", bytes("v"));
    }

    function testCounterfactualSetMetadataBatchRejectsRegistryAsTokenContract() external {
        vm.prank(alice);
        vm.expectRevert(Adapter8004.InvalidTokenContractIsRegistry.selector);
        adapter.counterfactualSetMetadataBatch(
            IERCAgentBindings.TokenStandard.ERC721, address(registry), 0, _emptyMetadata()
        );
    }

    function testCounterfactualSetAgentWalletRejectsRegistryAsTokenContract() external {
        vm.prank(alice);
        vm.expectRevert(Adapter8004.InvalidTokenContractIsRegistry.selector);
        adapter.counterfactualSetAgentWallet(IERCAgentBindings.TokenStandard.ERC721, address(registry), 0, wallet);
    }

    function testCounterfactualUnsetAgentWalletRejectsRegistryAsTokenContract() external {
        vm.prank(alice);
        vm.expectRevert(Adapter8004.InvalidTokenContractIsRegistry.selector);
        adapter.counterfactualUnsetAgentWallet(IERCAgentBindings.TokenStandard.ERC721, address(registry), 0);
    }

    function testBindExistingRejectsAlreadyBoundAgent() external {
        uint256 agentId = _register721(alice, 1);

        // Try to re-bind the same agentId via bindExisting. The adapter already owns the agent
        // because it was minted through `register`, so even if approval were in place this MUST
        // revert with AlreadyBound.
        vm.prank(alice);
        vm.expectRevert(abi.encodeWithSelector(Adapter8004.AlreadyBound.selector, agentId));
        adapter.bindExisting(agentId, IERCAgentBindings.TokenStandard.ERC721, address(token721), 1);
    }

    function testBindExistingRejectsCallerThatIsNotAgentOwner() external {
        // Bob mints the agent; Alice controls the external token (tokenId 1). Alice tries to
        // bindExisting against Bob's agent.
        vm.prank(bob);
        uint256 agentId = registry.register("ipfs://bobs");
        // Even if the registry had blanket approval, Alice does not own the agent.
        vm.prank(bob);
        IERC721(address(registry)).setApprovalForAll(address(adapter), true);

        vm.prank(alice);
        vm.expectRevert(abi.encodeWithSelector(Adapter8004.NotAgentOwner.selector, agentId, bob));
        adapter.bindExisting(agentId, IERCAgentBindings.TokenStandard.ERC721, address(token721), 1);
    }

    function testBindExistingRejectsCallerThatDoesNotControlExternalToken() external {
        // Alice owns the agent, but she tries to bind it to bob's tokenId 2.
        vm.prank(alice);
        uint256 agentId = registry.register("");

        vm.prank(alice);
        IERC721(address(registry)).approve(address(adapter), agentId);

        vm.prank(alice);
        vm.expectRevert(abi.encodeWithSelector(Adapter8004.NotController.selector, alice, type(uint256).max));
        adapter.bindExisting(agentId, IERCAgentBindings.TokenStandard.ERC721, address(token721), 2);
    }

    function testBindExistingRejectsMissingRegistryApproval() external {
        vm.prank(alice);
        uint256 agentId = registry.register("");

        // No approve / setApprovalForAll call.
        vm.prank(alice);
        vm.expectRevert(abi.encodeWithSelector(Adapter8004.AgentTransferNotApproved.selector, agentId));
        adapter.bindExisting(agentId, IERCAgentBindings.TokenStandard.ERC721, address(token721), 1);

        // The proxy still does not own the agent: bindExisting reverted before transferFrom.
        assertEq(registry.ownerOf(agentId), alice);
    }

    function testBindExistingOverwritesPreExistingBindingMetadataKey() external {
        // Capture the reserved-key string before any `vm.prank` so the read does not consume the prank.
        string memory bindingKey = adapter.BINDING_METADATA_KEY();

        vm.prank(alice);
        uint256 agentId = registry.register("");

        // Alice writes an arbitrary value at the reserved binding key before binding.
        vm.prank(alice);
        registry.setMetadata(agentId, bindingKey, bytes("not-an-adapter"));
        assertEq(registry.getMetadata(agentId, bindingKey), bytes("not-an-adapter"));

        vm.prank(alice);
        IERC721(address(registry)).approve(address(adapter), agentId);

        vm.prank(alice);
        adapter.bindExisting(agentId, IERCAgentBindings.TokenStandard.ERC721, address(token721), 1);

        // Post-bind: the canonical binding row is overwritten to point at the adapter.
        assertEq(registry.getMetadata(agentId, bindingKey), abi.encodePacked(address(adapter)));
    }

    function testBindExistingPreservesAgentURIAndAllowsLaterSetAgentURI() external {
        vm.prank(alice);
        uint256 agentId = registry.register("ipfs://before-bind");

        vm.prank(alice);
        IERC721(address(registry)).approve(address(adapter), agentId);

        vm.prank(alice);
        adapter.bindExisting(agentId, IERCAgentBindings.TokenStandard.ERC721, address(token721), 1);

        // URI preserved across binding.
        assertEq(registry.tokenURI(agentId), "ipfs://before-bind");

        // Post-bind, the same external-token controller can update via the adapter.
        vm.prank(alice);
        adapter.setAgentURI(agentId, "ipfs://after-bind");
        assertEq(registry.tokenURI(agentId), "ipfs://after-bind");
    }

    function testBindExistingPreservesNonBindingMetadataAndAllowsLaterSetMetadata() external {
        vm.prank(alice);
        uint256 agentId = registry.register("");

        vm.prank(alice);
        registry.setMetadata(agentId, "preserved", bytes("yes"));

        vm.prank(alice);
        IERC721(address(registry)).approve(address(adapter), agentId);

        vm.prank(alice);
        adapter.bindExisting(agentId, IERCAgentBindings.TokenStandard.ERC721, address(token721), 1);

        // Non-binding metadata preserved across the bind operation.
        assertEq(string(registry.getMetadata(agentId, "preserved")), "yes");

        // The post-bind controller can write more metadata through the adapter.
        vm.prank(alice);
        adapter.setMetadata(agentId, "post", bytes("written"));
        assertEq(string(registry.getMetadata(agentId, "post")), "written");
    }

    function testBindExistingClearsDefaultAgentWallet() external {
        // The mock registry sets agentWallet to msg.sender on register(); confirm bindExisting
        // produces a cleared wallet regardless.
        vm.prank(alice);
        uint256 agentId = registry.register("");
        assertEq(registry.getAgentWallet(agentId), alice);

        vm.prank(alice);
        IERC721(address(registry)).approve(address(adapter), agentId);

        vm.prank(alice);
        adapter.bindExisting(agentId, IERCAgentBindings.TokenStandard.ERC721, address(token721), 1);

        assertEq(registry.getAgentWallet(agentId), address(0));
    }

    function testBindExistingPostBindControllerFollowsExternalToken() external {
        vm.prank(alice);
        uint256 agentId = registry.register("");

        vm.prank(alice);
        IERC721(address(registry)).approve(address(adapter), agentId);

        vm.prank(alice);
        adapter.bindExisting(agentId, IERCAgentBindings.TokenStandard.ERC721, address(token721), 1);

        // Initially alice is the controller because she owns tokenId 1.
        assertTrue(adapter.isController(agentId, alice));
        assertFalse(adapter.isController(agentId, bob));

        // Transfer the external token to bob — bob now controls the bound agent.
        vm.prank(alice);
        token721.transferFrom(alice, bob, 1);
        assertFalse(adapter.isController(agentId, alice));
        assertTrue(adapter.isController(agentId, bob));

        // Alice can no longer write through the adapter; bob can.
        vm.prank(alice);
        vm.expectRevert(abi.encodeWithSelector(Adapter8004.NotController.selector, alice, agentId));
        adapter.setMetadata(agentId, "x", bytes("1"));

        vm.prank(bob);
        adapter.setMetadata(agentId, "x", bytes("2"));
        assertEq(string(registry.getMetadata(agentId, "x")), "2");
    }

    function testBindExistingBindsERC1155CurrentBalanceHolder() external {
        // Alice mints an agent and holds an ERC-1155 balance for tokenId 10.
        vm.prank(alice);
        uint256 agentId = registry.register("");

        vm.prank(alice);
        IERC721(address(registry)).approve(address(adapter), agentId);

        vm.prank(alice);
        adapter.bindExisting(agentId, IERCAgentBindings.TokenStandard.ERC1155, address(token1155), 10);

        IERCAgentBindings.Binding memory b = adapter.bindingOf(agentId);
        assertEq(uint8(b.standard), uint8(IERCAgentBindings.TokenStandard.ERC1155));
        assertEq(b.tokenContract, address(token1155));
        assertEq(b.tokenId, 10);
        assertTrue(adapter.isController(agentId, alice));
    }

    function testBindExistingBindsERC6909CurrentBalanceHolder() external {
        vm.prank(alice);
        uint256 agentId = registry.register("");

        vm.prank(alice);
        IERC721(address(registry)).approve(address(adapter), agentId);

        vm.prank(alice);
        adapter.bindExisting(agentId, IERCAgentBindings.TokenStandard.ERC6909, address(token6909), 42);

        IERCAgentBindings.Binding memory b = adapter.bindingOf(agentId);
        assertEq(uint8(b.standard), uint8(IERCAgentBindings.TokenStandard.ERC6909));
        assertEq(b.tokenContract, address(token6909));
        assertEq(b.tokenId, 42);
        assertTrue(adapter.isController(agentId, alice));
    }

    function testBindExistingBindsERC1155FOwner() external {
        vm.prank(alice);
        uint256 agentId = registry.register("");

        vm.prank(alice);
        IERC721(address(registry)).approve(address(adapter), agentId);

        vm.prank(alice);
        adapter.bindExisting(agentId, IERCAgentBindings.TokenStandard.ERC1155F, address(token1155F), 50);

        IERCAgentBindings.Binding memory b = adapter.bindingOf(agentId);
        assertEq(uint8(b.standard), uint8(IERCAgentBindings.TokenStandard.ERC1155F));
        assertEq(b.tokenContract, address(token1155F));
        assertEq(b.tokenId, 50);
        assertTrue(adapter.isController(agentId, alice));
    }

    function testBindExistingBindsERC6909FOwner() external {
        vm.prank(alice);
        uint256 agentId = registry.register("");

        vm.prank(alice);
        IERC721(address(registry)).approve(address(adapter), agentId);

        vm.prank(alice);
        adapter.bindExisting(agentId, IERCAgentBindings.TokenStandard.ERC6909F, address(token6909F), 60);

        IERCAgentBindings.Binding memory b = adapter.bindingOf(agentId);
        assertEq(uint8(b.standard), uint8(IERCAgentBindings.TokenStandard.ERC6909F));
        assertEq(b.tokenContract, address(token6909F));
        assertEq(b.tokenId, 60);
        assertTrue(adapter.isController(agentId, alice));
    }

    function testBindExistingAllowsSameExternalTokenAcrossMultipleAgents() external {
        // First, register an agent through the adapter for token721 tokenId 1.
        uint256 firstAgentId = _register721(alice, 1);
        assertEq(firstAgentId, 0);

        // Then, mint a second ERC-8004 identity directly and bindExisting to the same external
        // token. The proposal explicitly preserves the current "no reverse uniqueness" behavior.
        vm.prank(alice);
        uint256 secondAgentId = registry.register("");

        vm.prank(alice);
        IERC721(address(registry)).approve(address(adapter), secondAgentId);

        vm.prank(alice);
        adapter.bindExisting(secondAgentId, IERCAgentBindings.TokenStandard.ERC721, address(token721), 1);

        // Both agents exist, both are bound to the same external token, and the adapter owns each.
        assertEq(registry.ownerOf(firstAgentId), address(adapter));
        assertEq(registry.ownerOf(secondAgentId), address(adapter));
        assertTrue(firstAgentId != secondAgentId);

        IERCAgentBindings.Binding memory b1 = adapter.bindingOf(firstAgentId);
        IERCAgentBindings.Binding memory b2 = adapter.bindingOf(secondAgentId);
        assertEq(b1.tokenContract, b2.tokenContract);
        assertEq(b1.tokenId, b2.tokenId);
    }

    function _register721(address caller, uint256 tokenId) internal returns (uint256) {
        vm.prank(caller);
        return
            adapter.register(IERCAgentBindings.TokenStandard.ERC721, address(token721), tokenId, "", _emptyMetadata());
    }

    function _register1155(address caller, uint256 tokenId) internal returns (uint256) {
        vm.prank(caller);
        return
            adapter.register(IERCAgentBindings.TokenStandard.ERC1155, address(token1155), tokenId, "", _emptyMetadata());
    }

    function _register6909(address caller, uint256 tokenId) internal returns (uint256) {
        vm.prank(caller);
        return
            adapter.register(IERCAgentBindings.TokenStandard.ERC6909, address(token6909), tokenId, "", _emptyMetadata());
    }

    function _register1155F(address caller, uint256 tokenId) internal returns (uint256) {
        vm.prank(caller);
        return adapter.register(
            IERCAgentBindings.TokenStandard.ERC1155F, address(token1155F), tokenId, "", _emptyMetadata()
        );
    }

    function _register6909F(address caller, uint256 tokenId) internal returns (uint256) {
        vm.prank(caller);
        return adapter.register(
            IERCAgentBindings.TokenStandard.ERC6909F, address(token6909F), tokenId, "", _emptyMetadata()
        );
    }

    function _emptyMetadata() internal pure returns (IERC8004IdentityRegistry.MetadataEntry[] memory metadata) {
        metadata = new IERC8004IdentityRegistry.MetadataEntry[](0);
    }

    function _encodeLegacyBindingMetadata(
        address bindingContract,
        IERCAgentBindings.TokenStandard standard,
        address tokenContract,
        uint256 tokenId
    ) internal pure returns (bytes memory) {
        bytes memory compactTokenId = _encodeCompactUint(tokenId);
        return abi.encodePacked(
            bindingContract, uint8(standard), tokenContract, uint8(compactTokenId.length), compactTokenId
        );
    }

    function _encodeCompactUint(uint256 value) internal pure returns (bytes memory out) {
        if (value == 0) {
            return bytes("");
        }

        uint256 temp = value;
        uint256 length;
        while (temp != 0) {
            length++;
            temp >>= 8;
        }

        out = new bytes(length);
        temp = value;
        for (uint256 i = length; i > 0; --i) {
            out[i - 1] = bytes1(uint8(temp));
            temp >>= 8;
        }
    }

    function _signAgentWallet(uint256 agentId, address newWallet, address owner, uint256 deadline, uint256 signerPk)
        internal
        view
        returns (bytes memory)
    {
        bytes32 domainSeparator = keccak256(
            abi.encode(
                DOMAIN_TYPEHASH,
                keccak256(bytes("ERC8004IdentityRegistry")),
                keccak256(bytes("1")),
                block.chainid,
                address(registry)
            )
        );

        bytes32 structHash = keccak256(abi.encode(AGENT_WALLET_SET_TYPEHASH, agentId, newWallet, owner, deadline));
        bytes32 digest = keccak256(abi.encodePacked(hex"1901", domainSeparator, structHash));

        (uint8 v, bytes32 r, bytes32 s) = vm.sign(signerPk, digest);
        return abi.encodePacked(r, s, v);
    }
}

contract Adapter8004V2 is Adapter8004 {
    function version() external pure returns (string memory) {
        return "2";
    }
}

contract HybridERC721ERC1155 {
    mapping(uint256 tokenId => address owner) private _owners;
    mapping(address owner => mapping(uint256 tokenId => uint256 balance)) private _balances;

    function mint721(address to, uint256 tokenId) external {
        _owners[tokenId] = to;
    }

    function mint1155(address to, uint256 tokenId, uint256 amount) external {
        _balances[to][tokenId] += amount;
    }

    function ownerOf(uint256 tokenId) external view returns (address) {
        return _owners[tokenId];
    }

    function balanceOf(address account, uint256 tokenId) external view returns (uint256) {
        return _balances[account][tokenId];
    }
}
