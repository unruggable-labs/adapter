// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Test} from "forge-std/Test.sol";
import {ERC1967Proxy} from "@openzeppelin/contracts/proxy/ERC1967/ERC1967Proxy.sol";

import {Adapter8004} from "../../src/Adapter8004.sol";
import {IERC8217} from "../../src/interfaces/IERC8217.sol";
import {IERC8004IdentityRegistry} from "../../src/interfaces/IERC8004IdentityRegistry.sol";

import {MockIdentityRegistry} from "../mocks/MockIdentityRegistry.sol";
import {MockERC721} from "../mocks/MockERC721.sol";
import {MockERC1155} from "../mocks/MockERC1155.sol";
import {MockERC6909} from "../mocks/MockERC6909.sol";

/// @notice Fuzz / property tests that fill the invariant gaps identified by
/// the security-testing specialist against MEMORY.md section 6. All tests
/// here only add coverage — they do not modify any existing test or source.
contract SecurityAdapter8004InvariantsTest is Test {
    MockIdentityRegistry internal registry;
    Adapter8004 internal adapter;
    MockERC721 internal token721;
    MockERC1155 internal token1155;
    MockERC6909 internal token6909;

    address internal admin = makeAddr("invariantsAdmin");

    function setUp() external {
        registry = new MockIdentityRegistry();
        Adapter8004 impl = new Adapter8004(address(registry));
        ERC1967Proxy proxy = new ERC1967Proxy(address(impl), abi.encodeCall(Adapter8004.initialize, (admin)));
        adapter = Adapter8004(address(proxy));

        token721 = new MockERC721();
        token1155 = new MockERC1155();
        token6909 = new MockERC6909();
    }

    // ---------------------------------------------------------------------
    // MEMORY.md § 6 invariant 3: initial wallet cleared after register.
    // Fuzz the holder/tokenId to show the property holds across the whole
    // input domain rather than a single hand-picked case.
    // ---------------------------------------------------------------------
    function testFuzzInitialWalletClearedAfterRegister(address holder, uint256 tokenId) external {
        holder = _sanitizeHolder(holder);
        token721.mint(holder, tokenId);

        vm.prank(holder);
        uint256 agentId =
            adapter.register(IERC8217.TokenStandard.ERC721, address(token721), tokenId, "", _emptyMetadata());

        // The mock (and the real registry) set agentWallet = msg.sender during
        // register; the adapter must clear it as step 7 of register.
        assertEq(registry.getAgentWallet(agentId), address(0), "wallet not cleared after register");
    }

    // ---------------------------------------------------------------------
    // MEMORY.md § 6 invariant 9: binding is immutable once set.
    // Post-register, every externally-callable gated function must leave
    // bindingOf(agentId) byte-for-byte unchanged.
    // ---------------------------------------------------------------------
    function testFuzzBindingImmutableAcrossAllWrites(address holder, uint256 tokenId, bytes calldata payload)
        external
    {
        holder = _sanitizeHolder(holder);
        token721.mint(holder, tokenId);

        vm.prank(holder);
        uint256 agentId =
            adapter.register(IERC8217.TokenStandard.ERC721, address(token721), tokenId, "", _emptyMetadata());

        IERC8217.Binding memory beforeBinding = adapter.bindingOf(agentId);

        // Exercise every non-reverting controller path and re-check the
        // binding. These calls should never touch _bindings[agentId].
        vm.startPrank(holder);
        adapter.setAgentURI(agentId, "ipfs://new");
        adapter.setMetadata(agentId, "k", payload);

        IERC8004IdentityRegistry.MetadataEntry[] memory batch = new IERC8004IdentityRegistry.MetadataEntry[](2);
        batch[0] = IERC8004IdentityRegistry.MetadataEntry("a", bytes("1"));
        batch[1] = IERC8004IdentityRegistry.MetadataEntry("b", bytes("2"));
        adapter.setMetadataBatch(agentId, batch);

        adapter.unsetAgentWallet(agentId);
        vm.stopPrank();

        IERC8217.Binding memory afterBinding = adapter.bindingOf(agentId);
        assertEq(uint256(afterBinding.standard), uint256(beforeBinding.standard), "standard mutated");
        assertEq(afterBinding.boundAddress, beforeBinding.boundAddress, "boundAddress mutated");
        assertEq(afterBinding.tokenId, beforeBinding.tokenId, "tokenId mutated");
    }

    // ---------------------------------------------------------------------
    // MEMORY.md § 6 invariant 4 + 14: the canonical agent-binding metadata
    // is written at register time as exactly 20 bytes (ERC-8217
    // `abi.encodePacked(bindingContract)`).
    // ---------------------------------------------------------------------
    function testFuzzCanonicalBindingMetadataMatchesEncoder(address holder, uint256 tokenId) external {
        holder = _sanitizeHolder(holder);
        token721.mint(holder, tokenId);

        vm.prank(holder);
        uint256 agentId =
            adapter.register(IERC8217.TokenStandard.ERC721, address(token721), tokenId, "", _emptyMetadata());

        bytes memory stored = registry.getMetadata(agentId, adapter.BINDING_METADATA_KEY());
        bytes memory expected = abi.encodePacked(address(adapter));
        assertEq(stored, expected, "canonical binding metadata drift");
        assertEq(stored.length, 20, "binding metadata must be 20 bytes");
    }

    // ---------------------------------------------------------------------
    // MEMORY.md § 6 invariant 7: unknown-agent discrimination. Every gated
    // write reverts with UnknownAgent(id); bindingOf reverts; isController
    // returns false. Fuzzes agentId across the whole uint256 domain so any
    // off-by-one (e.g., id = 0 default) surfaces.
    // ---------------------------------------------------------------------
    function testFuzzUnknownAgentRevertsAcrossAllGatedReads(uint256 agentId) external {
        // With no register ever called, every agentId is unknown.
        vm.expectRevert(abi.encodeWithSelector(Adapter8004.UnknownAgent.selector, agentId));
        adapter.bindingOf(agentId);

        assertFalse(adapter.isController(agentId, makeAddr("anyone")));

        vm.expectRevert(abi.encodeWithSelector(Adapter8004.UnknownAgent.selector, agentId));
        adapter.setAgentURI(agentId, "x");

        vm.expectRevert(abi.encodeWithSelector(Adapter8004.UnknownAgent.selector, agentId));
        adapter.setMetadata(agentId, "k", bytes("v"));

        vm.expectRevert(abi.encodeWithSelector(Adapter8004.UnknownAgent.selector, agentId));
        adapter.setMetadataBatch(agentId, _emptyMetadata());

        vm.expectRevert(abi.encodeWithSelector(Adapter8004.UnknownAgent.selector, agentId));
        adapter.setAgentWallet(agentId, makeAddr("w"), block.timestamp + 1, "");

        vm.expectRevert(abi.encodeWithSelector(Adapter8004.UnknownAgent.selector, agentId));
        adapter.unsetAgentWallet(agentId);
    }

    // ---------------------------------------------------------------------
    // Register atomicity: when the registry side fails mid-register,
    // `_bindings` must not be left populated. The registry accepts the
    // two-argument register() and reverts on the follow-up setMetadata, so
    // the adapter has written _bindings[id] by the time the failure lands.
    //
    // The write order does not matter here and there is no atomicity gap to
    // document: the adapter does not catch the registry's revert, so the
    // whole call reverts and every state change it made is discarded with
    // it. This test asserts exactly that, rather than only that the call
    // reverted, which is what an earlier revision of this comment claimed
    // it checked and did not.
    // ---------------------------------------------------------------------
    function testRegisterRevertsCleanlyWhenRegistryFails() external {
        // Build an adapter on a registry whose setMetadata always reverts. This used to swap the
        // registry under the live adapter; the registry is fixed at construction since `0.0.17`.
        FailingMetadataRegistry badRegistry = new FailingMetadataRegistry();
        Adapter8004 failing = Adapter8004(
            address(
                new ERC1967Proxy(
                    address(new Adapter8004(address(badRegistry))), abi.encodeCall(Adapter8004.initialize, (admin))
                )
            )
        );

        token721.mint(address(this), 99);

        // Non-empty metadata on purpose. Empty metadata routes to the single-argument
        // `register(string)` overload, which this mock refuses outright, so the call would revert
        // before reaching the binding write and this test would prove nothing about rollback.
        IERC8004IdentityRegistry.MetadataEntry[] memory metadata = new IERC8004IdentityRegistry.MetadataEntry[](1);
        metadata[0] = IERC8004IdentityRegistry.MetadataEntry({metadataKey: "k", metadataValue: bytes("v")});

        vm.expectRevert(bytes("metadata write disabled"));
        failing.register(IERC8217.TokenStandard.ERC721, address(token721), 99, "", metadata);

        // Nothing persisted. The registry issued id 0 and the adapter wrote `_bindings[0]` before
        // the failure arrived, so this is the assertion that the revert rolled that write back.
        vm.expectRevert(abi.encodeWithSelector(Adapter8004.UnknownAgent.selector, uint256(0)));
        failing.bindingOf(0);
    }

    // ---------------------------------------------------------------------
    // Ownership-transfer two-step gap (Semgrep finding: use-ownable2step):
    // a transferOwnership to a wrong address cannot be recovered. This
    // test documents the behavior for now; flag as Low in findings.
    // ---------------------------------------------------------------------
    function testOwnershipTransferIsSingleStepAndIrreversible() external {
        address badNewOwner = makeAddr("typoOwner");

        vm.prank(admin);
        adapter.transferOwnership(badNewOwner);

        assertEq(adapter.owner(), badNewOwner);

        // The old admin cannot reclaim — this is the hazard.
        vm.prank(admin);
        vm.expectRevert();
        adapter.transferOwnership(admin);
    }

    // ---------------------------------------------------------------------
    // helpers
    // ---------------------------------------------------------------------

    function _sanitizeHolder(address a) internal returns (address) {
        if (
            a == address(0) || a == address(adapter) || a == address(registry) || a == address(token721)
                || a == address(token1155) || a == address(token6909) || a == address(this)
        ) {
            return makeAddr("fuzzHolder");
        }
        if (a.code.length > 0) {
            return makeAddr("fuzzEoa");
        }
        return a;
    }

    function _emptyMetadata() internal pure returns (IERC8004IdentityRegistry.MetadataEntry[] memory) {
        return new IERC8004IdentityRegistry.MetadataEntry[](0);
    }
}

/// @dev Minimal adversarial registry: accepts register() but reverts on
/// setMetadata. Used only by the atomicity test above. Implements just
/// enough of IERC8004IdentityRegistry to be pointed at by the adapter.
contract FailingMetadataRegistry is IERC8004IdentityRegistry {
    uint256 private _nextId;
    mapping(uint256 => address) private _owners;

    function register(string memory, MetadataEntry[] memory) external override returns (uint256 agentId) {
        agentId = _nextId++;
        _owners[agentId] = msg.sender;
    }

    function register(string memory) external pure override returns (uint256) {
        revert("not used");
    }

    function register() external pure override returns (uint256) {
        revert("not used");
    }

    function setMetadata(uint256, string memory, bytes memory) external pure override {
        revert("metadata write disabled");
    }

    function setAgentURI(uint256, string calldata) external pure override {
        revert("uri write disabled");
    }

    function setAgentWallet(uint256, address, uint256, bytes calldata) external pure override {
        revert("wallet write disabled");
    }

    function unsetAgentWallet(uint256) external pure override {
        revert("wallet write disabled");
    }

    function getMetadata(uint256, string memory) external pure override returns (bytes memory) {
        return "";
    }

    function getAgentWallet(uint256) external pure override returns (address) {
        return address(0);
    }

    function ownerOf(uint256 agentId) external view override returns (address) {
        return _owners[agentId];
    }

    function tokenURI(uint256) external pure override returns (string memory) {
        return "";
    }
}
