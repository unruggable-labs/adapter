// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Test} from "forge-std/Test.sol";
import {AdapterImplementation} from "../src/AdapterImplementation.sol";
import {IERC8217} from "../src/interfaces/IERC8217.sol";
import {MockERC721} from "./mocks/MockERC721.sol";

interface IDelegateWriter {
    function delegateERC721(address to, address contract_, uint256 tokenId, bytes32 rights, bool enable)
        external
        payable
        returns (bytes32);
}

interface ISafe {
    function nonce() external view returns (uint256);
    function getTransactionHash(
        address to,
        uint256 value,
        bytes calldata data,
        uint8 operation,
        uint256 safeTxGas,
        uint256 baseGas,
        uint256 gasPrice,
        address gasToken,
        address refundReceiver,
        uint256 nonce_
    ) external view returns (bytes32);
    function approveHash(bytes32 hashToApprove) external;
    function execTransaction(
        address to,
        uint256 value,
        bytes calldata data,
        uint8 operation,
        uint256 safeTxGas,
        uint256 baseGas,
        uint256 gasPrice,
        address gasToken,
        address payable refundReceiver,
        bytes calldata signatures
    ) external payable returns (bool success);
}

/// @dev Opt-in, read-only RPC rehearsal. All writes happen only in Foundry's local fork.
/// Run with SEPOLIA_FORK_RPC_URL set. No private key, broadcast, or Safe signature is used.
contract Adapter8004SepoliaForkTest is Test {
    address constant PROXY = 0x7621630cB63a73a194f45A3E6801B8C6A7eC2f92;
    address constant BASELINE = 0x31a68E5bc0224ad081d6Ec20229B05F558609257;
    address constant SAFE = 0x03302Df40186D9B85faEA4fbb6cC5da028B23149;
    address constant SAFE_OWNER_1 = 0x28996f7DECe7E058EBfC56dFa9371825fBfa515A;
    address constant SAFE_OWNER_2 = 0x8b1f85a93Ac6E4F62695Ea8EF2410d248605FEff;
    address constant REGISTRY = 0x8004A818BFB912233c491871b3d84c89A494BD9e;
    bytes32 constant IMPLEMENTATION_SLOT = 0x360894a13ba1a3210667c828492db98dca3e2076cc3735a920a3ca505d382bbc;

    function testSepoliaUpgradeAgainstLiveContracts() external {
        string memory rpc = vm.envOr("SEPOLIA_FORK_RPC_URL", string(""));
        if (bytes(rpc).length == 0) {
            vm.skip(true);
            return;
        }
        vm.createSelectFork(rpc, vm.envOr("SEPOLIA_FORK_BLOCK", uint256(11658120)));
        assertEq(block.chainid, 11155111);
        AdapterImplementation adapter = AdapterImplementation(PROXY);
        assertEq(address(uint160(uint256(vm.load(PROXY, IMPLEMENTATION_SLOT)))), BASELINE);
        assertEq(adapter.owner(), SAFE);
        assertEq(address(adapter.identityRegistry()), REGISTRY);
        bytes32 oldSlotZero = vm.load(PROXY, bytes32(0));
        bytes memory historicalBindings = _historicalSnapshot(adapter);

        // Create a pre-upgrade binding through the actual outgoing implementation and live registry.
        // Only this NFT is a local mock; neither registry nor proxy code is replaced.
        MockERC721 token = new MockERC721();
        address holder = makeAddr("sepolia-fork-holder");
        address delegate = makeAddr("sepolia-fork-delegate");
        token.mint(holder, 1);
        vm.prank(holder);
        uint256 agentId = adapter.register(IERC8217.Standard.ERC721, address(token), 1, "ipfs://before");
        IERC8217.Binding memory beforeBinding = adapter.bindingOf(agentId);
        bytes memory beforeMetadata = adapter.getMetadata(agentId, "agent-binding");
        address delegateRegistry = adapter.DELEGATE_REGISTRY();
        bytes32 rights = adapter.DELEGATE_RIGHTS();
        vm.prank(holder);
        IDelegateWriter(delegateRegistry).delegateERC721(delegate, address(token), 1, rights, true);
        assertTrue(adapter.isController(agentId, delegate));

        AdapterImplementation implementation = new AdapterImplementation(REGISTRY);
        assertEq(implementation.proxiableUUID(), IMPLEMENTATION_SLOT);
        vm.prank(holder);
        vm.expectRevert();
        adapter.upgradeToAndCall(address(implementation), "");
        _executeUpgradeThroughSafe(address(implementation));
        assertEq(address(uint160(uint256(vm.load(PROXY, IMPLEMENTATION_SLOT)))), address(implementation));
        assertEq(vm.load(PROXY, bytes32(0)), oldSlotZero);
        assertEq(adapter.owner(), SAFE);
        assertEq(address(adapter.identityRegistry()), REGISTRY);
        assertEq(_historicalSnapshot(adapter), historicalBindings);
        assertEq(abi.encode(adapter.bindingOf(agentId)), abi.encode(beforeBinding));
        assertEq(adapter.getMetadata(agentId, "agent-binding"), beforeMetadata);
        assertEq(adapter.ownerOf(agentId), PROXY);
        assertEq(adapter.tokenURI(agentId), "ipfs://before");
        assertTrue(adapter.isController(agentId, holder));
        assertTrue(adapter.isController(agentId, delegate));
        vm.prank(delegate);
        adapter.setAgentURI(agentId, "ipfs://after");
        assertEq(adapter.tokenURI(agentId), "ipfs://after");
        assertEq(adapter.bindingHashOf(agentId), adapter.hashBinding(IERC8217.Standard.ERC721, address(token), 1));

        // Exercise the new registration path against the real registry, including wallet cleanup.
        vm.prank(holder);
        uint256 newId = adapter.register(IERC8217.Standard.ACCOUNT, holder, 0, "ipfs://new");
        assertEq(adapter.ownerOf(newId), PROXY);
        assertEq(adapter.getAgentWallet(newId), address(0));
        assertEq(adapter.getMetadata(newId, "agent-binding"), abi.encodePacked(PROXY));
        vm.prank(holder);
        adapter.setWalletUBID(IERC8217.Standard.ACCOUNT, holder, 0);
        vm.prank(holder);
        adapter.clearWalletUBID();

        vm.expectRevert();
        adapter.initialize(SAFE);
        // Registry equality is an operator check, not an on-chain restriction on future upgrades.
        assertEq(address(implementation.identityRegistry()), REGISTRY);
    }

    function _historicalSnapshot(AdapterImplementation adapter) internal view returns (bytes memory snapshot) {
        // Real bindings from tx 0x8117fb3679291b0f8a3e14d03e385059cfaf57971ab195702354f894538ace45.
        for (uint256 id = 9122; id <= 9124; ++id) {
            snapshot = abi.encode(
                snapshot,
                adapter.bindingOf(id),
                adapter.ownerOf(id),
                adapter.tokenURI(id),
                adapter.getMetadata(id, "agent-binding"),
                adapter.getAgentWallet(id)
            );
        }
    }

    function _executeUpgradeThroughSafe(address implementation) internal {
        ISafe safe = ISafe(SAFE);
        bytes memory data = abi.encodeWithSignature("upgradeToAndCall(address,bytes)", implementation, bytes(""));
        bytes32 safeTxHash = safe.getTransactionHash(PROXY, 0, data, 0, 0, 0, 0, address(0), address(0), safe.nonce());
        vm.prank(SAFE_OWNER_1);
        safe.approveHash(safeTxHash);
        vm.prank(SAFE_OWNER_2);
        safe.approveHash(safeTxHash);
        bytes memory signatures =
            bytes.concat(_approvedHashSignature(SAFE_OWNER_1), _approvedHashSignature(SAFE_OWNER_2));
        assertTrue(safe.execTransaction(PROXY, 0, data, 0, 0, 0, 0, address(0), payable(address(0)), signatures));
    }

    function _approvedHashSignature(address owner) internal pure returns (bytes memory) {
        return abi.encodePacked(bytes32(uint256(uint160(owner))), bytes32(0), uint8(1));
    }
}
