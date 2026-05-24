// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Test} from "forge-std/Test.sol";
import {ERC1967Proxy} from "@openzeppelin/contracts/proxy/ERC1967/ERC1967Proxy.sol";
import {Adapter8004} from "../src/Adapter8004.sol";
import {IERCAgentBindings} from "../src/interfaces/IERCAgentBindings.sol";
import {IERC8004IdentityRegistry} from "../src/interfaces/IERC8004IdentityRegistry.sol";
import {MockIdentityRegistry} from "./mocks/MockIdentityRegistry.sol";
import {MockERC721} from "./mocks/MockERC721.sol";
import {MockERC1155} from "./mocks/MockERC1155.sol";
import {MockERC1155F} from "./mocks/MockERC1155F.sol";
import {MockERC6909} from "./mocks/MockERC6909.sol";
import {MockERC6909F} from "./mocks/MockERC6909F.sol";
import {MockDelegateRegistry} from "./mocks/MockDelegateRegistry.sol";

/// @notice delegate.xyz v2 integration tests for the ERC-721 control path. A cold wallet holds the
/// NFT and delegates Adapter8004 management to a hot wallet; the hot wallet can then drive both the
/// on-chain register/management surface and the counterfactual surface. ERC-1155 / ERC-6909 paths
/// are asserted unchanged (no delegate inference on the no-vault API).
contract Adapter8004DelegateTest is Test {
    bytes32 internal constant DOMAIN_TYPEHASH =
        keccak256("EIP712Domain(string name,string version,uint256 chainId,address verifyingContract)");
    bytes32 internal constant AGENT_WALLET_SET_TYPEHASH =
        keccak256("AgentWalletSet(uint256 agentId,address newWallet,address owner,uint256 deadline)");

    MockIdentityRegistry internal registry;
    Adapter8004 internal adapter;
    MockERC721 internal token721;
    MockERC1155 internal token1155;
    MockERC1155F internal token1155F;
    MockERC6909 internal token6909;
    MockERC6909F internal token6909F;
    MockDelegateRegistry internal delegateRegistry;

    address internal cold = makeAddr("cold");
    address internal hot = makeAddr("hot");
    address internal eve = makeAddr("eve");
    address internal admin = makeAddr("admin");

    uint256 internal walletPk = 0xCAFE;
    address internal wallet;

    bytes32 internal rights;

    function setUp() external {
        wallet = vm.addr(walletPk);

        registry = new MockIdentityRegistry();
        Adapter8004 implementation = new Adapter8004();
        ERC1967Proxy proxy = new ERC1967Proxy(
            address(implementation), abi.encodeCall(Adapter8004.initialize, (address(registry), admin))
        );
        adapter = Adapter8004(address(proxy));
        rights = adapter.DELEGATE_RIGHTS();

        token721 = new MockERC721();
        token1155 = new MockERC1155();
        token1155F = new MockERC1155F();
        token6909 = new MockERC6909();
        token6909F = new MockERC6909F();

        token721.mint(cold, 1);
        token1155.mint(cold, 10, 5);
        token1155F.mint(cold, 50);
        token6909.mint(cold, 42, 3);
        token6909F.mint(cold, 60);

        // Place the mock delegate registry at the canonical hardcoded v2 address so the adapter's
        // `DELEGATE_REGISTRY` constant resolves to it under test.
        MockDelegateRegistry mockImpl = new MockDelegateRegistry();
        vm.etch(adapter.DELEGATE_REGISTRY(), address(mockImpl).code);
        delegateRegistry = MockDelegateRegistry(adapter.DELEGATE_REGISTRY());
    }

    // -----------------------------------------------------------------
    // Direct owner — unchanged behavior
    // -----------------------------------------------------------------

    function testDirectOwnerStillRegistersAndManages() external {
        vm.prank(cold);
        uint256 agentId =
            adapter.register(IERCAgentBindings.TokenStandard.ERC721, address(token721), 1, "", _emptyMetadata());

        vm.startPrank(cold);
        adapter.setAgentURI(agentId, "ipfs://owner");
        adapter.setMetadata(agentId, "k", bytes("v"));
        vm.stopPrank();

        assertEq(registry.tokenURI(agentId), "ipfs://owner");
        assertEq(string(registry.getMetadata(agentId, "k")), "v");
    }

    // -----------------------------------------------------------------
    // Valid delegate — token / contract / all-wallet / empty rights
    // -----------------------------------------------------------------

    function testTokenLevelDelegateCanRegister() external {
        delegateRegistry.delegateERC721(hot, cold, address(token721), 1, rights, true);

        vm.prank(hot);
        uint256 agentId = adapter.register(
            IERCAgentBindings.TokenStandard.ERC721, address(token721), 1, "ipfs://hot", _emptyMetadata()
        );

        assertEq(registry.tokenURI(agentId), "ipfs://hot");
        assertTrue(adapter.isController(agentId, hot));
    }

    function testTokenLevelDelegateCanManageEveryControllerGatedFunction() external {
        uint256 agentId = _registerByCold();
        delegateRegistry.delegateERC721(hot, cold, address(token721), 1, rights, true);

        vm.startPrank(hot);
        adapter.setAgentURI(agentId, "ipfs://hot-uri");
        adapter.setMetadata(agentId, "desc", bytes("hot"));

        IERC8004IdentityRegistry.MetadataEntry[] memory batch = new IERC8004IdentityRegistry.MetadataEntry[](1);
        batch[0] = IERC8004IdentityRegistry.MetadataEntry({metadataKey: "b", metadataValue: bytes("1")});
        adapter.setMetadataBatch(agentId, batch);

        uint256 deadline = block.timestamp + 4 minutes;
        bytes memory sig = _signAgentWallet(agentId, wallet, address(adapter), deadline, walletPk);
        adapter.setAgentWallet(agentId, wallet, deadline, sig);
        adapter.unsetAgentWallet(agentId);
        vm.stopPrank();

        assertEq(registry.tokenURI(agentId), "ipfs://hot-uri");
        assertEq(string(registry.getMetadata(agentId, "desc")), "hot");
        assertEq(string(registry.getMetadata(agentId, "b")), "1");
        assertEq(registry.getAgentWallet(agentId), address(0));
    }

    function testEmptyRightsDelegateWorks() external {
        uint256 agentId = _registerByCold();
        // Delegation registered with empty rights still authorizes a DELEGATE_RIGHTS-scoped check.
        delegateRegistry.delegateERC721(hot, cold, address(token721), 1, bytes32(0), true);

        vm.prank(hot);
        adapter.setAgentURI(agentId, "ipfs://empty-rights");
        assertEq(registry.tokenURI(agentId), "ipfs://empty-rights");
    }

    function testContractLevelDelegateWorks() external {
        uint256 agentId = _registerByCold();
        delegateRegistry.delegateContract(hot, cold, address(token721), rights, true);

        vm.prank(hot);
        adapter.setAgentURI(agentId, "ipfs://contract-level");
        assertEq(registry.tokenURI(agentId), "ipfs://contract-level");
    }

    function testAllWalletDelegateWorks() external {
        uint256 agentId = _registerByCold();
        delegateRegistry.delegateAll(hot, cold, rights, true);

        vm.prank(hot);
        adapter.setAgentURI(agentId, "ipfs://all-wallet");
        assertEq(registry.tokenURI(agentId), "ipfs://all-wallet");
    }

    // -----------------------------------------------------------------
    // Invalid / revoked / stale delegate
    // -----------------------------------------------------------------

    function testNonDelegateRevertsNotController() external {
        uint256 agentId = _registerByCold();

        vm.prank(eve);
        vm.expectRevert(abi.encodeWithSelector(Adapter8004.NotController.selector, eve, agentId));
        adapter.setAgentURI(agentId, "ipfs://eve");
    }

    function testWrongRightsValueFails() external {
        uint256 agentId = _registerByCold();
        // A delegation scoped to some other nonzero rights must not authorize adapter8004.manage.
        delegateRegistry.delegateERC721(hot, cold, address(token721), 1, keccak256("some.other.right"), true);

        vm.prank(hot);
        vm.expectRevert(abi.encodeWithSelector(Adapter8004.NotController.selector, hot, agentId));
        adapter.setAgentURI(agentId, "ipfs://wrong-rights");
    }

    function testRevokedDelegationReverts() external {
        uint256 agentId = _registerByCold();
        delegateRegistry.delegateERC721(hot, cold, address(token721), 1, rights, true);

        vm.prank(hot);
        adapter.setAgentURI(agentId, "ipfs://before-revoke");

        // Cold wallet revokes; the hot wallet immediately loses control.
        delegateRegistry.delegateERC721(hot, cold, address(token721), 1, rights, false);

        vm.prank(hot);
        vm.expectRevert(abi.encodeWithSelector(Adapter8004.NotController.selector, hot, agentId));
        adapter.setAgentURI(agentId, "ipfs://after-revoke");
    }

    function testPriorOwnerDelegationFailsAfterTransfer() external {
        uint256 agentId = _registerByCold();
        delegateRegistry.delegateERC721(hot, cold, address(token721), 1, rights, true);

        // NFT moves to a new owner; the delegation is still keyed to the prior owner `cold`.
        vm.prank(cold);
        token721.transferFrom(cold, eve, 1);

        vm.prank(hot);
        vm.expectRevert(abi.encodeWithSelector(Adapter8004.NotController.selector, hot, agentId));
        adapter.setAgentURI(agentId, "ipfs://stale");

        // The new owner controls directly without any delegation.
        vm.prank(eve);
        adapter.setAgentURI(agentId, "ipfs://new-owner");
        assertEq(registry.tokenURI(agentId), "ipfs://new-owner");
    }

    function testIsControllerReflectsDelegateLifecycle() external {
        uint256 agentId = _registerByCold();

        assertFalse(adapter.isController(agentId, hot));

        delegateRegistry.delegateERC721(hot, cold, address(token721), 1, rights, true);
        assertTrue(adapter.isController(agentId, hot));
        assertTrue(adapter.isController(agentId, cold));

        delegateRegistry.delegateERC721(hot, cold, address(token721), 1, rights, false);
        assertFalse(adapter.isController(agentId, hot));

        // Unknown agent: isController returns false, never reverts.
        assertFalse(adapter.isController(999, hot));
    }

    function testUnknownAgentStillRevertsForDelegatePath() external {
        delegateRegistry.delegateERC721(hot, cold, address(token721), 1, rights, true);

        vm.prank(hot);
        vm.expectRevert(abi.encodeWithSelector(Adapter8004.UnknownAgent.selector, 999));
        adapter.setAgentURI(999, "ipfs://x");
    }

    // -----------------------------------------------------------------
    // No-code registry — fail closed
    // -----------------------------------------------------------------

    function testNoCodeRegistryDirectOwnerWorksDelegateFails() external {
        // Wipe the etched delegate registry: the canonical address now has no code.
        vm.etch(adapter.DELEGATE_REGISTRY(), "");

        vm.prank(cold);
        uint256 agentId =
            adapter.register(IERCAgentBindings.TokenStandard.ERC721, address(token721), 1, "", _emptyMetadata());

        // Direct owner still works with no registry.
        vm.prank(cold);
        adapter.setAgentURI(agentId, "ipfs://owner-nocode");
        assertEq(registry.tokenURI(agentId), "ipfs://owner-nocode");

        // A hot wallet that would be delegated cannot be authorized when the registry is absent.
        vm.prank(hot);
        vm.expectRevert(abi.encodeWithSelector(Adapter8004.NotController.selector, hot, agentId));
        adapter.setAgentURI(agentId, "ipfs://hot-nocode");
    }

    // -----------------------------------------------------------------
    // ERC-1155 / ERC-6909 — unchanged, no delegate inference
    // -----------------------------------------------------------------

    function testERC1155DelegateIsNotController() external {
        vm.prank(cold);
        uint256 agentId =
            adapter.register(IERCAgentBindings.TokenStandard.ERC1155, address(token1155), 10, "", _emptyMetadata());

        // Even a full all-wallet delegation must not grant ERC-1155 control: the no-vault API
        // cannot map a delegation to a specific holder.
        delegateRegistry.delegateAll(hot, cold, bytes32(0), true);

        assertFalse(adapter.isController(agentId, hot));
        vm.prank(hot);
        vm.expectRevert(abi.encodeWithSelector(Adapter8004.NotController.selector, hot, agentId));
        adapter.setAgentURI(agentId, "ipfs://hot1155");

        // Direct positive-balance holder still controls.
        vm.prank(cold);
        adapter.setAgentURI(agentId, "ipfs://cold1155");
        assertEq(registry.tokenURI(agentId), "ipfs://cold1155");
    }

    function testERC6909DelegateIsNotController() external {
        vm.prank(cold);
        uint256 agentId =
            adapter.register(IERCAgentBindings.TokenStandard.ERC6909, address(token6909), 42, "", _emptyMetadata());

        delegateRegistry.delegateAll(hot, cold, bytes32(0), true);

        assertFalse(adapter.isController(agentId, hot));
        vm.prank(hot);
        vm.expectRevert(abi.encodeWithSelector(Adapter8004.NotController.selector, hot, agentId));
        adapter.setAgentURI(agentId, "ipfs://hot6909");

        vm.prank(cold);
        adapter.setAgentURI(agentId, "ipfs://cold6909");
        assertEq(registry.tokenURI(agentId), "ipfs://cold6909");
    }

    function testERC1155FDelegateCanRegisterAndManage() external {
        delegateRegistry.delegateERC721(hot, cold, address(token1155F), 50, rights, true);

        vm.prank(hot);
        uint256 agentId = adapter.register(
            IERCAgentBindings.TokenStandard.ERC1155F, address(token1155F), 50, "ipfs://hot1155f", _emptyMetadata()
        );

        assertTrue(adapter.isController(agentId, hot));

        vm.prank(hot);
        adapter.setAgentURI(agentId, "ipfs://hot1155f-updated");
        assertEq(registry.tokenURI(agentId), "ipfs://hot1155f-updated");
    }

    function testERC6909FDelegateCanRegisterAndManage() external {
        delegateRegistry.delegateERC721(hot, cold, address(token6909F), 60, rights, true);

        vm.prank(hot);
        uint256 agentId = adapter.register(
            IERCAgentBindings.TokenStandard.ERC6909F, address(token6909F), 60, "ipfs://hot6909f", _emptyMetadata()
        );

        assertTrue(adapter.isController(agentId, hot));

        vm.prank(hot);
        adapter.setAgentURI(agentId, "ipfs://hot6909f-updated");
        assertEq(registry.tokenURI(agentId), "ipfs://hot6909f-updated");
    }

    function testCounterfactualFTypeDelegateCanEmit() external {
        delegateRegistry.delegateERC721(hot, cold, address(token1155F), 50, rights, true);
        delegateRegistry.delegateERC721(hot, cold, address(token6909F), 60, rights, true);

        vm.startPrank(hot);
        adapter.counterfactualRegister(
            IERCAgentBindings.TokenStandard.ERC1155F, address(token1155F), 50, "ipfs://cf1155f"
        );
        adapter.counterfactualSetAgentURI(
            IERCAgentBindings.TokenStandard.ERC6909F, address(token6909F), 60, "ipfs://cf6909f"
        );
        vm.stopPrank();
    }

    // -----------------------------------------------------------------
    // Counterfactual ERC-721 surface
    // -----------------------------------------------------------------

    function testCounterfactualERC721DelegateCanEmitEveryFunction() external {
        delegateRegistry.delegateERC721(hot, cold, address(token721), 1, rights, true);

        IERC8004IdentityRegistry.MetadataEntry[] memory batch = new IERC8004IdentityRegistry.MetadataEntry[](1);
        batch[0] = IERC8004IdentityRegistry.MetadataEntry({metadataKey: "b", metadataValue: bytes("1")});

        vm.startPrank(hot);
        adapter.counterfactualRegister(IERCAgentBindings.TokenStandard.ERC721, address(token721), 1, "ipfs://cf");
        adapter.counterfactualRegister(
            IERCAgentBindings.TokenStandard.ERC721, address(token721), 1, "ipfs://cf", _emptyMetadata()
        );
        adapter.counterfactualSetAgentURI(IERCAgentBindings.TokenStandard.ERC721, address(token721), 1, "ipfs://cf-uri");
        adapter.counterfactualSetMetadata(IERCAgentBindings.TokenStandard.ERC721, address(token721), 1, "k", bytes("v"));
        adapter.counterfactualSetMetadataBatch(IERCAgentBindings.TokenStandard.ERC721, address(token721), 1, batch);
        adapter.counterfactualSetAgentWallet(
            IERCAgentBindings.TokenStandard.ERC721, address(token721), 1, address(0xBEEF)
        );
        adapter.counterfactualUnsetAgentWallet(IERCAgentBindings.TokenStandard.ERC721, address(token721), 1);
        vm.stopPrank();
    }

    function testCounterfactualWrongDelegateRevertsNotController() external {
        // No delegation for eve.
        vm.prank(eve);
        vm.expectRevert(abi.encodeWithSelector(Adapter8004.NotController.selector, eve, type(uint256).max));
        adapter.counterfactualSetAgentURI(IERCAgentBindings.TokenStandard.ERC721, address(token721), 1, "ipfs://x");

        // Revoked delegation also reverts on the counterfactual pre-binding check.
        delegateRegistry.delegateERC721(hot, cold, address(token721), 1, rights, true);
        delegateRegistry.delegateERC721(hot, cold, address(token721), 1, rights, false);
        vm.prank(hot);
        vm.expectRevert(abi.encodeWithSelector(Adapter8004.NotController.selector, hot, type(uint256).max));
        adapter.counterfactualSetAgentURI(IERCAgentBindings.TokenStandard.ERC721, address(token721), 1, "ipfs://x");
    }

    // -----------------------------------------------------------------
    // Reserved-key protection still applies to delegated callers
    // -----------------------------------------------------------------

    function testReservedMetadataKeyStillRejectedForDelegate() external {
        uint256 agentId = _registerByCold();
        delegateRegistry.delegateERC721(hot, cold, address(token721), 1, rights, true);

        string memory key = adapter.BINDING_METADATA_KEY();
        vm.prank(hot);
        vm.expectRevert(abi.encodeWithSelector(Adapter8004.ReservedMetadataKey.selector, key));
        adapter.setMetadata(agentId, key, bytes("bad"));
    }

    // -----------------------------------------------------------------
    // Helpers
    // -----------------------------------------------------------------

    function _registerByCold() internal returns (uint256 agentId) {
        vm.prank(cold);
        agentId = adapter.register(IERCAgentBindings.TokenStandard.ERC721, address(token721), 1, "", _emptyMetadata());
    }

    function _emptyMetadata() internal pure returns (IERC8004IdentityRegistry.MetadataEntry[] memory metadata) {
        metadata = new IERC8004IdentityRegistry.MetadataEntry[](0);
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
