// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Test, Vm} from "forge-std/Test.sol";
import {ERC1967Proxy} from "@openzeppelin/contracts/proxy/ERC1967/ERC1967Proxy.sol";

import {Adapter8004} from "../../src/Adapter8004.sol";
import {IERCAgentBindings} from "../../src/interfaces/IERCAgentBindings.sol";
import {IERC8004IdentityRegistry} from "../../src/interfaces/IERC8004IdentityRegistry.sol";

import {MockIdentityRegistry} from "../mocks/MockIdentityRegistry.sol";
import {MockERC721} from "../mocks/MockERC721.sol";

import {ReentrantERC721} from "./mocks/ReentrantERC721.sol";

interface ICounterfactualReentrancyErrors {
    error ReentrancyGuardReentrantCall();
}

/// @notice Counterfactual surface security tests: prove the broadcast-only claim functions cannot
/// mutate ERC-8004 registry state, cannot mutate adapter storage, and cannot create a wallet binding
/// without a signature. Indexer policy (latest event per (tokenContract, tokenId) wins) is documented
/// here as an off-chain behavior — the chain only emits events, it does not enforce ordering.
contract CounterfactualSecurityTest is Test {
    MockIdentityRegistry internal registry;
    Adapter8004 internal adapter;
    MockERC721 internal token721;

    address internal admin = makeAddr("admin");
    address internal alice = makeAddr("alice");
    address internal eve = makeAddr("eve");

    function setUp() external {
        registry = new MockIdentityRegistry();
        Adapter8004 impl = new Adapter8004();
        ERC1967Proxy proxy =
            new ERC1967Proxy(address(impl), abi.encodeCall(Adapter8004.initialize, (address(registry), admin)));
        adapter = Adapter8004(address(proxy));

        token721 = new MockERC721();
        token721.mint(alice, 1);
    }

    /// Counterfactual register must not mint in the ERC-8004 registry.
    function testCounterfactualRegisterDoesNotMintRegistryAgent() external {
        uint256 registryBefore = _registryNextId();

        vm.prank(alice);
        adapter.counterfactualRegister(IERCAgentBindings.TokenStandard.ERC721, address(token721), 1, "ipfs://cf");

        assertEq(_registryNextId(), registryBefore, "registry must not mint a new agent");
    }

    /// Counterfactual register must not write the canonical binding for any agent id.
    function testCounterfactualRegisterDoesNotWriteBindingMetadata() external {
        vm.prank(alice);
        adapter.counterfactualRegister(IERCAgentBindings.TokenStandard.ERC721, address(token721), 1, "ipfs://cf");

        bytes memory stored = registry.getMetadata(0, adapter.BINDING_METADATA_KEY());
        assertEq(stored.length, 0, "registry must hold no binding metadata for agent 0");
    }

    /// `bindingOf` must continue to revert with UnknownAgent after a counterfactual claim — no
    /// adapter storage may be persisted by the counterfactual path.
    function testCounterfactualRegisterDoesNotWriteAdapterBindingStorage() external {
        vm.prank(alice);
        adapter.counterfactualRegister(IERCAgentBindings.TokenStandard.ERC721, address(token721), 1, "ipfs://cf");

        vm.expectRevert(abi.encodeWithSelector(Adapter8004.UnknownAgent.selector, 0));
        adapter.bindingOf(0);
    }

    /// All counterfactual setters likewise must not mint in the registry, nor write metadata, nor
    /// write any adapter storage.
    function testAllCounterfactualSettersHaveNoRegistryOrAdapterSideEffects() external {
        uint256 registryBefore = _registryNextId();

        vm.startPrank(alice);
        adapter.counterfactualSetAgentURI(IERCAgentBindings.TokenStandard.ERC721, address(token721), 1, "ipfs://u");
        adapter.counterfactualSetMetadata(IERCAgentBindings.TokenStandard.ERC721, address(token721), 1, "k", bytes("v"));
        IERC8004IdentityRegistry.MetadataEntry[] memory metadata = new IERC8004IdentityRegistry.MetadataEntry[](1);
        metadata[0] = IERC8004IdentityRegistry.MetadataEntry({metadataKey: "k2", metadataValue: bytes("v2")});
        adapter.counterfactualSetMetadataBatch(IERCAgentBindings.TokenStandard.ERC721, address(token721), 1, metadata);
        adapter.counterfactualSetAgentWallet(
            IERCAgentBindings.TokenStandard.ERC721, address(token721), 1, address(0xBEEF)
        );
        adapter.counterfactualUnsetAgentWallet(IERCAgentBindings.TokenStandard.ERC721, address(token721), 1);
        vm.stopPrank();

        assertEq(_registryNextId(), registryBefore, "registry must not mint anything during counterfactual setters");
        assertEq(registry.getMetadata(0, "k").length, 0, "registry must hold no metadata for unminted agent 0");
        assertEq(registry.getMetadata(0, "k2").length, 0, "registry must hold no batch metadata for unminted agent 0");

        vm.expectRevert(abi.encodeWithSelector(Adapter8004.UnknownAgent.selector, 0));
        adapter.bindingOf(0);
    }

    /// Counterfactual setAgentWallet must not require a signature/deadline and must not surface a
    /// wallet binding in the ERC-8004 registry.
    function testCounterfactualSetAgentWalletRequiresNoSignatureAndCannotMutateRegistry() external {
        address newWallet = address(0xBEEF);

        vm.prank(alice);
        adapter.counterfactualSetAgentWallet(IERCAgentBindings.TokenStandard.ERC721, address(token721), 1, newWallet);

        // The registry never minted agent 0 so its agentWallet stays the zero address.
        assertEq(registry.getAgentWallet(0), address(0), "registry wallet must not change via counterfactual path");
    }

    /// Hostile caller without current token control cannot emit any counterfactual event, even with a
    /// well-formed signature input the function ignores.
    function testCounterfactualSurfaceRefusesNonController() external {
        vm.startPrank(eve);

        vm.expectRevert(abi.encodeWithSelector(Adapter8004.NotController.selector, eve, type(uint256).max));
        adapter.counterfactualRegister(IERCAgentBindings.TokenStandard.ERC721, address(token721), 1, "u");

        vm.expectRevert(abi.encodeWithSelector(Adapter8004.NotController.selector, eve, type(uint256).max));
        adapter.counterfactualSetAgentURI(IERCAgentBindings.TokenStandard.ERC721, address(token721), 1, "u");

        vm.expectRevert(abi.encodeWithSelector(Adapter8004.NotController.selector, eve, type(uint256).max));
        adapter.counterfactualSetMetadata(IERCAgentBindings.TokenStandard.ERC721, address(token721), 1, "k", bytes("v"));

        IERC8004IdentityRegistry.MetadataEntry[] memory empty = new IERC8004IdentityRegistry.MetadataEntry[](0);
        vm.expectRevert(abi.encodeWithSelector(Adapter8004.NotController.selector, eve, type(uint256).max));
        adapter.counterfactualSetMetadataBatch(IERCAgentBindings.TokenStandard.ERC721, address(token721), 1, empty);

        vm.expectRevert(abi.encodeWithSelector(Adapter8004.NotController.selector, eve, type(uint256).max));
        adapter.counterfactualSetAgentWallet(
            IERCAgentBindings.TokenStandard.ERC721, address(token721), 1, address(0xBEEF)
        );

        vm.expectRevert(abi.encodeWithSelector(Adapter8004.NotController.selector, eve, type(uint256).max));
        adapter.counterfactualUnsetAgentWallet(IERCAgentBindings.TokenStandard.ERC721, address(token721), 1);

        vm.stopPrank();
    }

    /// Indexer policy guard: the same controller may re-emit any number of counterfactual updates,
    /// and the chain happily emits each one — ordering and last-write-wins is enforced off-chain.
    function testCounterfactualReclaimEmitsRepeatedEventsAndChainDoesNotDedupe() external {
        vm.recordLogs();

        vm.startPrank(alice);
        adapter.counterfactualSetAgentURI(IERCAgentBindings.TokenStandard.ERC721, address(token721), 1, "ipfs://1");
        adapter.counterfactualSetAgentURI(IERCAgentBindings.TokenStandard.ERC721, address(token721), 1, "ipfs://2");
        adapter.counterfactualSetAgentURI(IERCAgentBindings.TokenStandard.ERC721, address(token721), 1, "ipfs://3");
        vm.stopPrank();

        Vm.Log[] memory logs = vm.getRecordedLogs();
        bytes32 topic = keccak256("CounterfactualAgentURISet(bytes32,address,uint256,uint8,string,address)");
        bytes32 expectedHash = keccak256(
            abi.encode(
                block.chainid, address(adapter), IERCAgentBindings.TokenStandard.ERC721, address(token721), uint256(1)
            )
        );
        bytes32 expectedTokenContract = bytes32(uint256(uint160(address(token721))));
        bytes32 expectedTokenId = bytes32(uint256(1));
        uint256 matches;
        for (uint256 i; i < logs.length; ++i) {
            if (logs[i].topics.length > 0 && logs[i].topics[0] == topic) {
                assertEq(logs[i].topics[1], expectedHash);
                assertEq(logs[i].topics[2], expectedTokenContract);
                assertEq(logs[i].topics[3], expectedTokenId);
                // Decode the non-indexed payload (uint8 version, string newURI, address emitter)
                // and confirm the schema version is the v1 baseline.
                (uint8 version,,) = abi.decode(logs[i].data, (uint8, string, address));
                assertEq(version, uint8(1), "version must be 1 on every counterfactual event");
                ++matches;
            }
        }
        assertEq(matches, 3, "every re-emit must produce a fresh log entry");
    }

    /// The adapter's `counterfactualPayloadVersion()` view MUST return the same `1` that every
    /// counterfactual event carries in its `uint8 version` field.
    function testCounterfactualPayloadVersionIsOne() external view {
        assertEq(adapter.counterfactualPayloadVersion(), uint8(1));
    }

    /// Counterfactual setter reentrancy: a malicious ERC-721 attempts to reenter
    /// `adapter.counterfactualSetAgentURI(...)` during its own `ownerOf` staticcall (the only
    /// external call the counterfactual setter makes). The adapter's `nonReentrant` guard fires on
    /// the SLOAD entry check (allowed in the static frame), reverting the inner frame with
    /// `ReentrancyGuardReentrantCall()`. The mock propagates that selector verbatim and the outer
    /// call surfaces it — proving the guard covers the counterfactual surface too.
    function testCounterfactualSetAgentURIReentryRevertsWithReentrancyGuardReentrantCall() external {
        ReentrantERC721 mal = new ReentrantERC721();
        mal.setOwner(1, alice);
        mal.setReentry(
            address(adapter),
            abi.encodeWithSignature(
                "counterfactualSetAgentURI(uint8,address,uint256,string)",
                IERCAgentBindings.TokenStandard.ERC721,
                address(mal),
                1,
                "ipfs://reentrant"
            )
        );

        vm.prank(alice);
        vm.expectRevert(ICounterfactualReentrancyErrors.ReentrancyGuardReentrantCall.selector);
        adapter.counterfactualSetAgentURI(IERCAgentBindings.TokenStandard.ERC721, address(mal), 1, "ipfs://outer");
    }

    function _registryNextId() internal view returns (uint256 next) {
        // ERC721URIStorage in MockIdentityRegistry exposes `ownerOf` per minted id; we can detect the
        // next id by probing until it reverts. For our small-token suite we only mint 0/1/2 at most so
        // a tight scan is enough.
        next = 0;
        while (true) {
            try registry.ownerOf(next) returns (address) {
                ++next;
            } catch {
                return next;
            }
        }
    }
}
