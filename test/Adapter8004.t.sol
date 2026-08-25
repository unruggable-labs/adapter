// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Test} from "forge-std/Test.sol";
import {Vm} from "forge-std/Vm.sol";
import {ERC1967Proxy} from "@openzeppelin/contracts/proxy/ERC1967/ERC1967Proxy.sol";
import {IERC721} from "@openzeppelin/contracts/token/ERC721/IERC721.sol";
import {IERC721Errors} from "@openzeppelin/contracts/interfaces/draft-IERC6093.sol";
import {Adapter8004} from "../src/Adapter8004.sol";
import {IERC8004AdapterCounterfactual} from "../src/interfaces/IERC8004AdapterCounterfactual.sol";
import {IERC8217} from "../src/interfaces/IERC8217.sol";
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

        Adapter8004 implementation = new Adapter8004(address(registry));
        ERC1967Proxy proxy = new ERC1967Proxy(address(implementation), abi.encodeCall(Adapter8004.initialize, (admin)));
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
            adapter.register(IERC8217.Standard.ERC721, address(token721), 1, "ipfs://agent/1", metadata);

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

    /// @dev A fresh registry mints agent id 0, so the first bound agent sits on the id most likely
    /// to be confused with a default value. Everything downstream has to keep working for it, which
    /// is why the id is asserted rather than assumed.
    function testFirstMintedAgentIdIsZero() external {
        vm.prank(alice);
        vm.expectEmit(true, true, true, true, address(adapter));
        emit Adapter8004.AgentBound(0, IERC8217.Standard.ERC721, address(token721), 1, alice);
        uint256 agentId = adapter.register(IERC8217.Standard.ERC721, address(token721), 1, "ipfs://agent/1");

        assertEq(agentId, 0);
        assertEq(adapter.bindingOf(agentId).boundAddress, address(token721), "agent 0 is a real binding");
        assertEq(
            adapter.bindingHashOf(agentId), adapter.bindingHashFor(IERC8217.Standard.ERC721, address(token721), 1)
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
        adapter.register(IERC8217.Standard.ERC721, address(token721), 1, "", _emptyMetadata());
    }

    function testRegisterNoMetadataOverloadProducesIdenticalBinding() external {
        vm.prank(alice);
        uint256 agentId = adapter.register(IERC8217.Standard.ERC721, address(token721), 1, "ipfs://agent/1");

        assertEq(registry.ownerOf(agentId), address(adapter));
        assertEq(registry.tokenURI(agentId), "ipfs://agent/1");
        assertEq(registry.getAgentWallet(agentId), address(0));
        assertEq(registry.getMetadata(agentId, adapter.BINDING_METADATA_KEY()), abi.encodePacked(address(adapter)));

        IERC8217.Binding memory binding = adapter.bindingOf(agentId);
        assertEq(uint8(binding.standard), uint8(IERC8217.Standard.ERC721));
        assertEq(binding.boundAddress, address(token721));
        assertEq(binding.tokenId, 1);
    }

    function testRegisterNoMetadataOverloadEnforcesTokenControl() external {
        vm.prank(eve);
        vm.expectRevert(abi.encodeWithSelector(Adapter8004.NotController.selector, eve, type(uint256).max));
        adapter.register(IERC8217.Standard.ERC721, address(token721), 1, "");
    }

    function testSameTokenCanRegisterMultipleAgents() external {
        uint256 firstAgentId = _register721(alice, 1);

        vm.prank(alice);
        uint256 secondAgentId =
            adapter.register(IERC8217.Standard.ERC721, address(token721), 1, "", _emptyMetadata());

        assertEq(firstAgentId, 0);
        assertEq(secondAgentId, 1);

        IERC8217.Binding memory firstBinding = adapter.bindingOf(firstAgentId);
        IERC8217.Binding memory secondBinding = adapter.bindingOf(secondAgentId);
        assertEq(firstBinding.boundAddress, address(token721));
        assertEq(secondBinding.boundAddress, address(token721));
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
        IERC8217.Binding memory binding = IERC8217(bindingContract).bindingOf(agentId);

        assertEq(uint256(binding.standard), uint256(IERC8217.Standard.ERC721));
        assertEq(binding.boundAddress, address(token721));
        assertEq(binding.tokenId, 1);
    }

    function testAdapterImplementsIERC8217Interface() external {
        uint256 agentId = _register721(alice, 1);

        IERC8217 bindings = IERC8217(address(adapter));
        IERC8217.Binding memory binding = bindings.bindingOf(agentId);

        assertEq(uint256(binding.standard), uint256(IERC8217.Standard.ERC721));
        assertEq(binding.boundAddress, address(token721));
        assertEq(binding.tokenId, 1);
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
        adapter.register(IERC8217.Standard.ERC721, address(token721), 1, "", metadata);
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

    // --- `cf-registration` is an ordinary key since `0.0.17`, so every path accepts it ---
    //  Inverted from asserting a revert. Only `agent-binding` is reserved, because only it is a
    //  record this contract writes; `bindingHashOf` is the authoritative identifier source.

    function testRegisterAcceptsCfRegistrationKey() external {
        IERC8004IdentityRegistry.MetadataEntry[] memory metadata = new IERC8004IdentityRegistry.MetadataEntry[](1);
        metadata[0] =
            IERC8004IdentityRegistry.MetadataEntry({metadataKey: "cf-registration", metadataValue: bytes("ok")});

        vm.prank(alice);
        uint256 agentId = adapter.register(IERC8217.Standard.ERC721, address(token721), 1, "", metadata);
        assertEq(registry.getMetadata(agentId, "cf-registration"), bytes("ok"));
    }

    function testSetMetadataAcceptsCfRegistrationKey() external {
        uint256 agentId = _register721(alice, 1);

        vm.prank(alice);
        adapter.setMetadata(agentId, "cf-registration", bytes("ok"));
        assertEq(registry.getMetadata(agentId, "cf-registration"), bytes("ok"));
    }

    function testSetMetadataBatchAcceptsCfRegistrationKey() external {
        uint256 agentId = _register721(alice, 1);

        IERC8004IdentityRegistry.MetadataEntry[] memory metadata = new IERC8004IdentityRegistry.MetadataEntry[](1);
        metadata[0] =
            IERC8004IdentityRegistry.MetadataEntry({metadataKey: "cf-registration", metadataValue: bytes("ok")});

        vm.prank(alice);
        adapter.setMetadataBatch(agentId, metadata);
        assertEq(registry.getMetadata(agentId, "cf-registration"), bytes("ok"));
    }

    // --- Audit fixes: I-5 test gaps ---

    function testRegisterArrayOverloadWithEmptyMetadata() external {
        // Explicitly exercise the metadata.length == 0 branch of the array overload.
        IERC8004IdentityRegistry.MetadataEntry[] memory metadata = new IERC8004IdentityRegistry.MetadataEntry[](0);

        vm.prank(alice);
        uint256 agentId =
            adapter.register(IERC8217.Standard.ERC721, address(token721), 1, "ipfs://agent/empty", metadata);

        assertEq(registry.ownerOf(agentId), address(adapter));
        assertEq(registry.tokenURI(agentId), "ipfs://agent/empty");
        assertEq(registry.getMetadata(agentId, adapter.BINDING_METADATA_KEY()), abi.encodePacked(address(adapter)));

        IERC8217.Binding memory binding = adapter.bindingOf(agentId);
        assertEq(uint8(binding.standard), uint8(IERC8217.Standard.ERC721));
        assertEq(binding.boundAddress, address(token721));
        assertEq(binding.tokenId, 1);
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
                adapter.interoperableAddress(address(adapter)),
                uint8(IERC8217.Standard.ERC721),
                address(token721),
                uint256(1)
            )
        );

        vm.prank(alice);
        vm.expectEmit(true, true, true, true, address(adapter));
        emit IERC8004AdapterCounterfactual.CounterfactualAgentRegistered(
            expectedHash, address(token721), 1, IERC8217.Standard.ERC721, "ipfs://agent/cf", metadata, alice
        );
        bytes32 ubi = adapter.counterfactualRegister(
            IERC8217.Standard.ERC721, address(token721), 1, "ipfs://agent/cf", metadata
        );

        assertEq(ubi, expectedHash);
    }

    function testRegistrationHashViewMatchesEncodingAndCounterfactualEventTopic() external {
        bytes32 viewHash = adapter.bindingHashFor(IERC8217.Standard.ERC721, address(token721), 1);
        bytes32 expectedHash = keccak256(
            abi.encode(
                adapter.interoperableAddress(address(adapter)),
                uint8(IERC8217.Standard.ERC721),
                address(token721),
                uint256(1)
            )
        );
        assertEq(viewHash, expectedHash);

        vm.recordLogs();
        vm.prank(alice);
        bytes32 emittedHash =
            adapter.counterfactualRegister(IERC8217.Standard.ERC721, address(token721), 1, "ipfs://view");

        Vm.Log[] memory entries = vm.getRecordedLogs();
        assertEq(emittedHash, viewHash);
        assertEq(entries.length, 1);
        assertEq(entries[0].topics[0], IERC8004AdapterCounterfactual.CounterfactualAgentRegistered.selector);
        assertEq(entries[0].topics[1], viewHash);
    }

    function testCounterfactualRegisterEmptyMetadataOverload() external {
        bytes32 expectedHash = keccak256(
            abi.encode(
                adapter.interoperableAddress(address(adapter)),
                uint8(IERC8217.Standard.ERC721),
                address(token721),
                uint256(1)
            )
        );

        vm.prank(alice);
        bytes32 ubi =
            adapter.counterfactualRegister(IERC8217.Standard.ERC721, address(token721), 1, "ipfs://agent/cf");

        assertEq(ubi, expectedHash);
    }

    function testCounterfactualRegisterRejectsZeroTokenContract() external {
        vm.prank(alice);
        vm.expectRevert(Adapter8004.InvalidBoundAddress.selector);
        adapter.counterfactualRegister(
            IERC8217.Standard.ERC721, address(0), 1, "ipfs://agent/cf", _emptyMetadata()
        );
    }

    function testCounterfactualRegisterRejectsNonController() external {
        vm.prank(eve);
        vm.expectRevert(abi.encodeWithSelector(Adapter8004.NotController.selector, eve, type(uint256).max));
        adapter.counterfactualRegister(
            IERC8217.Standard.ERC721, address(token721), 1, "ipfs://agent/cf", _emptyMetadata()
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
        adapter.counterfactualRegister(IERC8217.Standard.ERC721, address(token721), 1, "ipfs://agent/cf", metadata);
    }

    function testCounterfactualRegisterAcceptsCfRegistrationKey() external {
        IERC8004IdentityRegistry.MetadataEntry[] memory metadata = new IERC8004IdentityRegistry.MetadataEntry[](1);
        metadata[0] =
            IERC8004IdentityRegistry.MetadataEntry({metadataKey: "cf-registration", metadataValue: bytes("ok")});

        vm.recordLogs();
        vm.prank(alice);
        adapter.counterfactualRegister(IERC8217.Standard.ERC721, address(token721), 1, "ipfs://agent/cf", metadata);
        assertEq(vm.getRecordedLogs().length, 1, "the claim is emitted rather than reverted");
    }

    function testCounterfactualSetAgentURIEmits() external {
        bytes32 expectedHash = keccak256(
            abi.encode(
                adapter.interoperableAddress(address(adapter)),
                uint8(IERC8217.Standard.ERC721),
                address(token721),
                uint256(1)
            )
        );

        vm.prank(alice);
        vm.expectEmit(true, true, true, true, address(adapter));
        emit IERC8004AdapterCounterfactual.CounterfactualAgentURISet(
            expectedHash, address(token721), 1, IERC8217.Standard.ERC721, "ipfs://updated", alice
        );
        adapter.counterfactualSetAgentURI(IERC8217.Standard.ERC721, address(token721), 1, "ipfs://updated");
    }

    function testCounterfactualSetAgentURIRejectsZeroTokenContract() external {
        vm.prank(alice);
        vm.expectRevert(Adapter8004.InvalidBoundAddress.selector);
        adapter.counterfactualSetAgentURI(IERC8217.Standard.ERC721, address(0), 1, "ipfs://x");
    }

    function testCounterfactualSetAgentURIRejectsNonController() external {
        vm.prank(eve);
        vm.expectRevert(abi.encodeWithSelector(Adapter8004.NotController.selector, eve, type(uint256).max));
        adapter.counterfactualSetAgentURI(IERC8217.Standard.ERC721, address(token721), 1, "ipfs://x");
    }

    function testCounterfactualSetMetadataEmits() external {
        bytes32 expectedHash = keccak256(
            abi.encode(
                adapter.interoperableAddress(address(adapter)),
                uint8(IERC8217.Standard.ERC721),
                address(token721),
                uint256(1)
            )
        );

        vm.prank(alice);
        vm.expectEmit(true, true, true, true, address(adapter));
        emit IERC8004AdapterCounterfactual.CounterfactualMetadataSet(
            expectedHash, address(token721), 1, IERC8217.Standard.ERC721, "description", bytes("hello"), alice
        );
        adapter.counterfactualSetMetadata(
            IERC8217.Standard.ERC721, address(token721), 1, "description", bytes("hello")
        );
    }

    function testCounterfactualSetMetadataRejectsZeroTokenContract() external {
        vm.prank(alice);
        vm.expectRevert(Adapter8004.InvalidBoundAddress.selector);
        adapter.counterfactualSetMetadata(IERC8217.Standard.ERC721, address(0), 1, "k", bytes("v"));
    }

    function testCounterfactualSetMetadataRejectsNonController() external {
        vm.prank(eve);
        vm.expectRevert(abi.encodeWithSelector(Adapter8004.NotController.selector, eve, type(uint256).max));
        adapter.counterfactualSetMetadata(IERC8217.Standard.ERC721, address(token721), 1, "k", bytes("v"));
    }

    function testCounterfactualSetMetadataRejectsReservedBindingMetadataKey() external {
        string memory key = adapter.BINDING_METADATA_KEY();

        vm.expectRevert(abi.encodeWithSelector(Adapter8004.ReservedMetadataKey.selector, key));
        vm.prank(alice);
        adapter.counterfactualSetMetadata(IERC8217.Standard.ERC721, address(token721), 1, key, bytes("bad"));
    }

    function testCounterfactualSetMetadataAcceptsCfRegistrationKey() external {
        vm.recordLogs();
        vm.prank(alice);
        adapter.counterfactualSetMetadata(
            IERC8217.Standard.ERC721, address(token721), 1, "cf-registration", bytes("ok")
        );
        assertEq(vm.getRecordedLogs().length, 1, "the entry is emitted rather than reverted");
    }

    function testCounterfactualSetMetadataBatchEmits() external {
        bytes32 expectedHash = keccak256(
            abi.encode(
                adapter.interoperableAddress(address(adapter)),
                uint8(IERC8217.Standard.ERC721),
                address(token721),
                uint256(1)
            )
        );

        IERC8004IdentityRegistry.MetadataEntry[] memory metadata = new IERC8004IdentityRegistry.MetadataEntry[](2);
        metadata[0] = IERC8004IdentityRegistry.MetadataEntry({metadataKey: "a", metadataValue: bytes("1")});
        metadata[1] = IERC8004IdentityRegistry.MetadataEntry({metadataKey: "b", metadataValue: bytes("2")});

        vm.prank(alice);
        vm.expectEmit(true, true, true, true, address(adapter));
        emit IERC8004AdapterCounterfactual.CounterfactualMetadataBatchSet(
            expectedHash, address(token721), 1, IERC8217.Standard.ERC721, metadata, alice
        );
        adapter.counterfactualSetMetadataBatch(IERC8217.Standard.ERC721, address(token721), 1, metadata);
    }

    function testCounterfactualSetMetadataBatchRejectsZeroTokenContract() external {
        vm.prank(alice);
        vm.expectRevert(Adapter8004.InvalidBoundAddress.selector);
        adapter.counterfactualSetMetadataBatch(IERC8217.Standard.ERC721, address(0), 1, _emptyMetadata());
    }

    function testCounterfactualSetMetadataBatchRejectsNonController() external {
        IERC8004IdentityRegistry.MetadataEntry[] memory metadata = new IERC8004IdentityRegistry.MetadataEntry[](1);
        metadata[0] = IERC8004IdentityRegistry.MetadataEntry({metadataKey: "a", metadataValue: bytes("1")});

        vm.prank(eve);
        vm.expectRevert(abi.encodeWithSelector(Adapter8004.NotController.selector, eve, type(uint256).max));
        adapter.counterfactualSetMetadataBatch(IERC8217.Standard.ERC721, address(token721), 1, metadata);
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
        adapter.counterfactualSetMetadataBatch(IERC8217.Standard.ERC721, address(token721), 1, metadata);
    }

    function testCounterfactualSetMetadataBatchAcceptsCfRegistrationKey() external {
        IERC8004IdentityRegistry.MetadataEntry[] memory metadata = new IERC8004IdentityRegistry.MetadataEntry[](1);
        metadata[0] =
            IERC8004IdentityRegistry.MetadataEntry({metadataKey: "cf-registration", metadataValue: bytes("ok")});

        vm.recordLogs();
        vm.prank(alice);
        adapter.counterfactualSetMetadataBatch(IERC8217.Standard.ERC721, address(token721), 1, metadata);
        assertEq(vm.getRecordedLogs().length, 1, "the batch is emitted rather than reverted");
    }

    function testCounterfactualSetAgentWalletEmits() external {
        bytes32 expectedHash = keccak256(
            abi.encode(
                adapter.interoperableAddress(address(adapter)),
                uint8(IERC8217.Standard.ERC721),
                address(token721),
                uint256(1)
            )
        );

        vm.prank(alice);
        vm.expectEmit(true, true, true, true, address(adapter));
        emit IERC8004AdapterCounterfactual.CounterfactualAgentWalletSet(
            expectedHash, address(token721), 1, IERC8217.Standard.ERC721, wallet, alice
        );
        adapter.counterfactualSetAgentWallet(IERC8217.Standard.ERC721, address(token721), 1, wallet);
    }

    function testCounterfactualSetAgentWalletRejectsZeroTokenContract() external {
        vm.prank(alice);
        vm.expectRevert(Adapter8004.InvalidBoundAddress.selector);
        adapter.counterfactualSetAgentWallet(IERC8217.Standard.ERC721, address(0), 1, wallet);
    }

    function testCounterfactualSetAgentWalletRejectsNonController() external {
        vm.prank(eve);
        vm.expectRevert(abi.encodeWithSelector(Adapter8004.NotController.selector, eve, type(uint256).max));
        adapter.counterfactualSetAgentWallet(IERC8217.Standard.ERC721, address(token721), 1, wallet);
    }

    function testCounterfactualUnsetAgentWalletEmits() external {
        bytes32 expectedHash = keccak256(
            abi.encode(
                adapter.interoperableAddress(address(adapter)),
                uint8(IERC8217.Standard.ERC721),
                address(token721),
                uint256(1)
            )
        );

        vm.prank(alice);
        vm.expectEmit(true, true, true, true, address(adapter));
        emit IERC8004AdapterCounterfactual.CounterfactualAgentWalletUnset(
            expectedHash, address(token721), 1, IERC8217.Standard.ERC721, alice
        );
        adapter.counterfactualUnsetAgentWallet(IERC8217.Standard.ERC721, address(token721), 1);
    }

    function testCounterfactualUnsetAgentWalletRejectsZeroTokenContract() external {
        vm.prank(alice);
        vm.expectRevert(Adapter8004.InvalidBoundAddress.selector);
        adapter.counterfactualUnsetAgentWallet(IERC8217.Standard.ERC721, address(0), 1);
    }

    function testCounterfactualUnsetAgentWalletRejectsNonController() external {
        vm.prank(eve);
        vm.expectRevert(abi.encodeWithSelector(Adapter8004.NotController.selector, eve, type(uint256).max));
        adapter.counterfactualUnsetAgentWallet(IERC8217.Standard.ERC721, address(token721), 1);
    }

    function testCounterfactualRegistrationHashIsStableForSameInputs() external {
        vm.prank(alice);
        bytes32 first = adapter.counterfactualRegister(IERC8217.Standard.ERC721, address(token721), 1, "u1");

        vm.prank(alice);
        bytes32 second = adapter.counterfactualRegister(IERC8217.Standard.ERC721, address(token721), 1, "u2");

        assertEq(first, second);
    }

    function testCounterfactualRegistrationHashChangesWithTokenContract() external {
        vm.prank(alice);
        bytes32 viaToken721 = adapter.counterfactualRegister(IERC8217.Standard.ERC721, address(token721), 1, "u");
        vm.prank(alice);
        bytes32 viaToken1155 =
            adapter.counterfactualRegister(IERC8217.Standard.ERC1155, address(token1155), 10, "u");

        assertTrue(viaToken721 != viaToken1155);
    }

    function testCounterfactualRegistrationHashChangesWithTokenId() external {
        vm.prank(alice);
        bytes32 forId1 = adapter.counterfactualRegister(IERC8217.Standard.ERC721, address(token721), 1, "u");
        vm.prank(bob);
        bytes32 forId2 = adapter.counterfactualRegister(IERC8217.Standard.ERC721, address(token721), 2, "u");

        assertTrue(forId1 != forId2);
    }

    function testCounterfactualRegistrationHashChangesWithChainId() external {
        bytes32 atDefaultChain = adapter.bindingHashFor(IERC8217.Standard.ERC721, address(token721), 1);
        vm.chainId(424242);
        bytes32 atOtherChain = adapter.bindingHashFor(IERC8217.Standard.ERC721, address(token721), 1);
        assertTrue(atDefaultChain != atOtherChain);
        vm.prank(alice);
        bytes32 onAltChain = adapter.counterfactualRegister(IERC8217.Standard.ERC721, address(token721), 1, "u");
        assertEq(onAltChain, atOtherChain);
    }

    function testRegistrationHashIncludesStandard() external view {
        // Inverted at `0.0.17`. Identity is (chain, adapter, standard, boundAddress, tokenId). The
        // standard is both a preimage field and a parameter, so one token resolves to one hash *per
        // standard*, not to one hash overall. The hybrid-contract test covers the claim path.
        assertEq(
            adapter.bindingHashFor(IERC8217.Standard.ERC721, address(token721), 1),
            adapter.bindingHashFor(IERC8217.Standard.ERC721, address(token721), 1),
            "same standard, same pair, same identity"
        );
        assertTrue(
            adapter.bindingHashFor(IERC8217.Standard.ERC721, address(token721), 1)
                != adapter.bindingHashFor(IERC8217.Standard.ERC1155, address(token721), 1),
            "different standard, same pair, different identity"
        );
    }

    function testHybridTokenContractHashIsStandardSpecific() external {
        // Inverted at `0.0.17`. A hybrid contract exposes token 77 under BOTH ERC-721 and ERC-1155.
        // Because the standard is part of the identity, the two claims resolve to DIFFERENT
        // UBIs: two identities, each with its own history, and neither supersedes the
        // other. Before this version they collapsed to one hash and the later claim won.
        HybridERC721ERC1155 hybrid = new HybridERC721ERC1155();
        hybrid.mint721(alice, 77);
        hybrid.mint1155(alice, 77, 1);

        bytes32 h721 = adapter.bindingHashFor(IERC8217.Standard.ERC721, address(hybrid), 77);
        bytes32 h1155 = adapter.bindingHashFor(IERC8217.Standard.ERC1155, address(hybrid), 77);

        vm.startPrank(alice);
        bytes32 cf721 =
            adapter.counterfactualRegister(IERC8217.Standard.ERC721, address(hybrid), 77, "ipfs://cf721");
        bytes32 cf1155 =
            adapter.counterfactualRegister(IERC8217.Standard.ERC1155, address(hybrid), 77, "ipfs://cf1155");
        vm.stopPrank();

        assertEq(cf721, h721);
        assertEq(cf1155, h1155);
        assertTrue(cf721 != cf1155, "one token, two standards, two identities");
    }

    function testCounterfactualRegistrationHashChangesWithAdapterAddress() external {
        Adapter8004 implementation = new Adapter8004(address(registry));
        ERC1967Proxy proxy = new ERC1967Proxy(address(implementation), abi.encodeCall(Adapter8004.initialize, (admin)));
        Adapter8004 secondAdapter = Adapter8004(address(proxy));

        vm.prank(alice);
        bytes32 fromFirst = adapter.counterfactualRegister(IERC8217.Standard.ERC721, address(token721), 1, "u");
        vm.prank(alice);
        bytes32 fromSecond =
            secondAdapter.counterfactualRegister(IERC8217.Standard.ERC721, address(token721), 1, "u");

        assertTrue(fromFirst != fromSecond);
        assertTrue(address(adapter) != address(secondAdapter));
    }

    /// @dev Closes audit finding G2-01. The registry is fixed at construction and there is no
    /// setter, so nobody can repoint the proxy, the owner included. Probed by selector rather than
    /// by a typed call, since a typed call would not compile once the function is gone.
    function testRegistryCannotBeRepointedByAnyone() external {
        bytes memory call = abi.encodeWithSignature("setIdentityRegistry(address)", address(registry2));

        vm.prank(admin);
        (bool byOwner,) = address(adapter).call(call);
        assertFalse(byOwner, "the owner must not be able to repoint the registry");

        vm.prank(alice);
        (bool byStranger,) = address(adapter).call(call);
        assertFalse(byStranger, "nor anyone else");

        assertEq(address(adapter.identityRegistry()), address(registry), "the registry is unchanged");
    }

    /// @dev The getter still answers through the proxy after the field became immutable. It is baked
    /// into the implementation's runtime code, so the proxy's `delegatecall` reads the value from
    /// the implementation rather than from slot 0, which now holds dead bytes.
    function testRegistryGetterAnswersThroughTheProxy() external view {
        assertEq(address(adapter.identityRegistry()), address(registry));
    }

    function testAdminCanUpgradeImplementation() external {
        Adapter8004V2 nextImplementation = new Adapter8004V2(address(registry));

        vm.prank(admin);
        adapter.upgradeToAndCall(address(nextImplementation), bytes(""));

        assertEq(Adapter8004V2(address(adapter)).version(), "2");
        assertEq(address(adapter.identityRegistry()), address(registry));
        assertEq(adapter.owner(), admin);
    }

    /// @dev The guard that makes the registry unchangeable across upgrades too, not just within
    /// one implementation. `upgradeToAndCall` runs against the OUTGOING implementation, so it reads
    /// the incoming one's baked registry and refuses a mismatch. Without this an owner could repoint
    /// the proxy by upgrading, which would put audit finding G2-01 straight back.
    function testUpgradeRejectsAnImplementationBakedWithADifferentRegistry() external {
        Adapter8004V2 wrongRegistry = new Adapter8004V2(address(registry2));
        assertEq(address(wrongRegistry.identityRegistry()), address(registry2), "premise: it carries the other one");

        vm.prank(admin);
        vm.expectRevert(Adapter8004.RegistryMismatch.selector);
        adapter.upgradeToAndCall(address(wrongRegistry), bytes(""));

        assertEq(address(adapter.identityRegistry()), address(registry), "the proxy still names the original");
    }

    /// @dev And accepts one baked with the same registry, so the guard rejects the mismatch rather
    /// than blocking upgrades outright.
    function testUpgradeAcceptsAnImplementationBakedWithTheSameRegistry() external {
        Adapter8004V2 sameRegistry = new Adapter8004V2(address(registry));

        vm.prank(admin);
        adapter.upgradeToAndCall(address(sameRegistry), bytes(""));

        assertEq(Adapter8004V2(address(adapter)).version(), "2", "the upgrade landed");
        assertEq(address(adapter.identityRegistry()), address(registry));
    }

    /// @dev Slot 0 held `identityRegistry` before `0.0.17` made it immutable, and every live proxy
    /// has a real address written there. The field no longer occupies it and nothing else may, so
    /// regular storage starts at slot 1. Read from the compiled layout rather than asserted from
    /// the declarations, so a reordering that moved a mapping into slot 0 fails here.
    /// @dev The layout is exactly two slots: reserved slot 0 and `_bindings` at 1. Slot 0 is
    /// reserved because every live proxy physically holds the old registry address there, so
    /// anything declared into it would read that address as its initial value. Both wallet mappings
    /// were removed at `0.0.17` and their slots were reclaimed rather than reserved, because nothing
    /// has ever been written to them. Changing the order fails this test.
    function testLayoutIsTwoSlotsAndSlotZeroStaysDead() external {
        // Seed the reserved slot with a sentinel standing in for the registry address a live proxy
        // holds there. Nothing the contract does may read or overwrite it.
        bytes32 sentinel = bytes32(uint256(0xdeadbeef));
        vm.store(address(adapter), bytes32(uint256(0)), sentinel);

        vm.prank(alice);
        uint256 agentId =
            adapter.register(IERC8217.Standard.ERC721, address(token721), 1, "ipfs://slots", _emptyMetadata());
        vm.prank(alice);
        adapter.setWalletUBI(IERC8217.Standard.ERC721, address(token721), 1);

        assertEq(vm.load(address(adapter), bytes32(uint256(0))), sentinel, "slot 0 must never be touched");

        // The binding landed in the mapping whose declared base slot it belongs to. Reordering the
        // declarations, or reserving a slot ahead of it, moves this and fails here.
        assertTrue(
            vm.load(address(adapter), keccak256(abi.encode(agentId, uint256(1)))) != bytes32(0), "_bindings at slot 1"
        );

        // The wallet designation is emit-only, so it writes nothing at all, and nothing was appended
        // past the last declared mapping.
        assertEq(vm.load(address(adapter), keccak256(abi.encode(alice, uint256(2)))), bytes32(0), "no wallet mapping");
        assertEq(vm.load(address(adapter), bytes32(uint256(2))), bytes32(0), "regular storage ends at slot 1");
    }

    function testNonAdminCannotUpgradeImplementation() external {
        Adapter8004V2 nextImplementation = new Adapter8004V2(address(registry));

        vm.prank(alice);
        vm.expectRevert();
        adapter.upgradeToAndCall(address(nextImplementation), bytes(""));
    }

    function testRegisterRejectsRegistryAsTokenContract() external {
        vm.prank(alice);
        vm.expectRevert(Adapter8004.BoundAddressIsRegistry.selector);
        adapter.register(IERC8217.Standard.ERC721, address(registry), 0, "", _emptyMetadata());
    }

    function testCounterfactualRegisterRejectsRegistryAsTokenContract() external {
        vm.prank(alice);
        vm.expectRevert(Adapter8004.BoundAddressIsRegistry.selector);
        adapter.counterfactualRegister(
            IERC8217.Standard.ERC721, address(registry), 0, "ipfs://agent/cf", _emptyMetadata()
        );
    }

    function testCounterfactualSetAgentURIRejectsRegistryAsTokenContract() external {
        vm.prank(alice);
        vm.expectRevert(Adapter8004.BoundAddressIsRegistry.selector);
        adapter.counterfactualSetAgentURI(IERC8217.Standard.ERC721, address(registry), 0, "u");
    }

    function testCounterfactualSetMetadataRejectsRegistryAsTokenContract() external {
        vm.prank(alice);
        vm.expectRevert(Adapter8004.BoundAddressIsRegistry.selector);
        adapter.counterfactualSetMetadata(IERC8217.Standard.ERC721, address(registry), 0, "k", bytes("v"));
    }

    function testCounterfactualSetMetadataBatchRejectsRegistryAsTokenContract() external {
        vm.prank(alice);
        vm.expectRevert(Adapter8004.BoundAddressIsRegistry.selector);
        adapter.counterfactualSetMetadataBatch(IERC8217.Standard.ERC721, address(registry), 0, _emptyMetadata());
    }

    function testCounterfactualSetAgentWalletRejectsRegistryAsTokenContract() external {
        vm.prank(alice);
        vm.expectRevert(Adapter8004.BoundAddressIsRegistry.selector);
        adapter.counterfactualSetAgentWallet(IERC8217.Standard.ERC721, address(registry), 0, wallet);
    }

    function testCounterfactualUnsetAgentWalletRejectsRegistryAsTokenContract() external {
        vm.prank(alice);
        vm.expectRevert(Adapter8004.BoundAddressIsRegistry.selector);
        adapter.counterfactualUnsetAgentWallet(IERC8217.Standard.ERC721, address(registry), 0);
    }

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

    function _register1155F(address caller, uint256 tokenId) internal returns (uint256) {
        vm.prank(caller);
        return adapter.register(IERC8217.Standard.ERC1155F, address(token1155F), tokenId, "", _emptyMetadata());
    }

    function _register6909F(address caller, uint256 tokenId) internal returns (uint256) {
        vm.prank(caller);
        return adapter.register(IERC8217.Standard.ERC6909F, address(token6909F), tokenId, "", _emptyMetadata());
    }

    function _emptyMetadata() internal pure returns (IERC8004IdentityRegistry.MetadataEntry[] memory metadata) {
        metadata = new IERC8004IdentityRegistry.MetadataEntry[](0);
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
    constructor(address registry_) Adapter8004(registry_) {}

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
