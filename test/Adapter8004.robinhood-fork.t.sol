// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Test} from "forge-std/Test.sol";
import {Vm} from "forge-std/Vm.sol";
import {AdapterImplementation} from "../src/AdapterImplementation.sol";
import {ERC1967Proxy} from "@openzeppelin/contracts/proxy/ERC1967/ERC1967Proxy.sol";
import {IERC8217} from "../src/interfaces/IERC8217.sol";
import {IERC8004AdapterAttestation} from "../src/interfaces/IERC8004AdapterAttestation.sol";
import {MockERC721} from "./mocks/MockERC721.sol";
import {MockERC1155} from "./mocks/MockERC1155.sol";
import {MockERC6909} from "./mocks/MockERC6909.sol";
import {MockERC1155F} from "./mocks/MockERC1155F.sol";
import {MockERC6909F} from "./mocks/MockERC6909F.sol";
import {ISafe} from "./Adapter8004.sepolia-fork.t.sol";

interface IRobinhoodSafe is ISafe {
    function getThreshold() external view returns (uint256);
    function getOwners() external view returns (address[] memory);
    function getModulesPaginated(address start, uint256 size) external view returns (address[] memory, address);
    function VERSION() external view returns (string memory);
}

interface IRobinhoodDelegate {
    function delegateERC721(address to, address contract_, uint256 id, bytes32 rights, bool enable)
        external
        payable
        returns (bytes32);
    function delegateAll(address to, bytes32 rights, bool enable) external payable returns (bytes32);
    function delegateContract(address to, address contract_, bytes32 rights, bool enable)
        external
        payable
        returns (bytes32);
}

/// @dev Test wallet only. Real registry validates the EIP-712 digest via ERC-1271; no keys.
contract RobinhoodWalletFixture {
    bytes32 public expected;

    function expectDigest(bytes32 digest) external {
        expected = digest;
    }

    function isValidSignature(bytes32 digest, bytes calldata signature) external view returns (bytes4) {
        return
            digest == expected && keccak256(signature) == keccak256(hex"1234") ? bytes4(0x1626ba7e) : bytes4(0xffffffff);
    }
}

contract RobinhoodControllerFixture {
    address public owner;

    constructor(address holder) {
        owner = holder;
    }

    function hasRole(bytes32 role, address who) external view returns (bool) {
        return role == 0 && who == owner;
    }
}
/// @dev A distinct future implementation, preserving layout and registry for the real Safe upgrade.

contract RobinhoodFutureImplementation is AdapterImplementation {
    constructor(address registry) AdapterImplementation(registry) {}

    function rehearsalVersion() external pure returns (uint256) {
        return 2;
    }
}
/// @dev All writes execute only in Foundry's local fork. Never replaces dependency code/storage.

contract Adapter8004RobinhoodForkTest is Test {
    address constant SAFE = 0x03302Df40186D9B85faEA4fbb6cC5da028B23149;
    address constant REGISTRY = 0x8004A169FB4a3325136EB29fA0ceB6D2e539a432;
    address constant FACTORY = 0x4e59b44847b379578588920cA78FbF26c0B4956C;
    address constant IMPL = 0x3d74ff0c1E0A78C5a291fA91F82f15bd54335231;
    address constant DEPLOYER = 0xF8e03bd4436371E0e2F7C02E529b2172fe72b4EF;
    bytes32 constant SLOT = 0x360894a13ba1a3210667c828492db98dca3e2076cc3735a920a3ca505d382bbc;
    AdapterImplementation adapter;
    address holder = address(0xa11ce);
    address delegate = address(0xb0b);
    uint256[8] ids;
    address[8] targets;

    function testRobinhoodFactoryRegistryDelegatesAndRealSafeUpgrade() external {
        string memory rpc = vm.envOr("ROBINHOOD_FORK_RPC_URL", string(""));
        if (bytes(rpc).length == 0) {
            vm.skip(true);
            return;
        }
        uint256 pinned = vm.envUint("ROBINHOOD_FORK_BLOCK");
        vm.createSelectFork(rpc, pinned);
        assertEq(block.chainid, 4663);
        assertEq(block.number, pinned);
        assertEq(FACTORY.codehash, 0x2fa86add0aed31f33a762c9d88e807c475bd51d0f52bd0955754b2608f7e4989);
        assertEq(SAFE.codehash, 0xd7d408ebcd99b2b70be43e20253d6d92a8ea8fab29bd3be7f55b10032331fb4c);
        assertEq(REGISTRY.codehash, 0xd0e45b1d89fa9b6cc7e97c1f155d64180e5c232aaccf9900ef9d4fd738c02b41);
        address registryImpl = address(uint160(uint256(vm.load(REGISTRY, SLOT))));
        assertEq(registryImpl, 0x7274e874CA62410a93Bd8bf61c69d8045E399c02);
        assertEq(registryImpl.codehash, 0xa5f9624ea85e45b3f4b8558581f03bfb3e6cefab278d7bf0500ec9bd065dc16f);
        assertEq(IRobinhoodSafe(SAFE).VERSION(), "1.4.1");
        (address[] memory modules, address end) = IRobinhoodSafe(SAFE).getModulesPaginated(address(1), 100);
        assertEq(modules.length, 0);
        assertEq(end, address(1));
        assertEq(vm.load(SAFE, 0x4a204f620c8c5ccdca3fd54d003badd85ba500436a431f0cbda4f558c93c34c8), bytes32(0));
        address singleton = address(uint160(uint256(vm.load(SAFE, bytes32(0)))));
        assertEq(singleton.codehash, 0xb1f926978a0f44a2c0ec8fe822418ae969bd8c3f18d61e5103100339894f81ff);
        address fallbackHandler =
            address(uint160(uint256(vm.load(SAFE, 0x6c9a6c4a39284e37ed1cf53d337577d14212a4870fb976a4366c693b939918d5))));
        assertEq(fallbackHandler.codehash, 0x7c6007a5d711cea8dfd5d91f5940ec29c7f200fe511eb1fc1397b367af3c42f9);
        assertEq(IRobinhoodSafe(SAFE).getThreshold(), 2);
        assertEq(IRobinhoodSafe(SAFE).getOwners().length, 4);
        assertEq(IRobinhoodSafe(SAFE).nonce(), 0);
        _deploy();
        _matrix();
        _walletSignaturePath();
        _upgrade();
        assertEq(adapter.owner(), SAFE);
        assertEq(address(adapter.identityRegistry()), REGISTRY);
        for (uint256 i; i < 8; ++i) {
            assertEq(adapter.ownerOf(ids[i]), address(adapter));
            assertEq(adapter.tokenURI(ids[i]), "ipfs://updated");
            assertEq(adapter.getMetadata(ids[i], "rehearsal"), hex"1234");
            assertEq(adapter.getAgentWallet(ids[i]), address(0));
            assertEq(adapter.bindingOf(ids[i]).boundAddress, targets[i]);
            assertTrue(adapter.isController(ids[i], holder));
        }
        assertTrue(adapter.isController(ids[0], delegate));
        vm.prank(delegate);
        adapter.setAgentURI(ids[0], "ipfs://after-upgrade");
        assertEq(adapter.tokenURI(ids[0]), "ipfs://after-upgrade");
        vm.expectRevert();
        adapter.initialize(SAFE);
    }

    function _deploy() internal {
        bytes memory implInit = abi.encodePacked(type(AdapterImplementation).creationCode, abi.encode(REGISTRY));
        assertEq(keccak256(implInit), 0x5b3785cf0fbcd80f67ead4953f7a775604ad6f9bbbba55040810e25f1aef1558);
        assertEq(IMPL.code.length, 0);
        assertEq(vm.getNonce(IMPL), 0);
        vm.prank(DEPLOYER);
        (bool ok, bytes memory result) = FACTORY.call(abi.encodePacked(bytes32(0), implInit));
        assertTrue(ok);
        assertEq(result, abi.encodePacked(IMPL));
        vm.expectRevert();
        AdapterImplementation(IMPL).initialize(SAFE);
        bytes memory init = abi.encodeCall(AdapterImplementation.initialize, (SAFE));
        bytes memory proxyInit = abi.encodePacked(type(ERC1967Proxy).creationCode, abi.encode(IMPL, init));
        assertEq(keccak256(proxyInit), 0xbb43a76de1130e845b39e4d6ff11934b8ccf9b4aae11084e955d7f7219cc9953);
        bytes32 salt = vm.envOr("ROBINHOOD_PROXY_SALT", bytes32(uint256(42)));
        address predicted =
            address(uint160(uint256(keccak256(abi.encodePacked(bytes1(0xff), FACTORY, salt, keccak256(proxyInit))))));
        assertEq(predicted.code.length, 0);
        assertEq(vm.getNonce(predicted), 0);
        vm.prank(DEPLOYER);
        (ok, result) = FACTORY.call(abi.encodePacked(salt, proxyInit));
        assertTrue(ok);
        assertEq(result, abi.encodePacked(predicted));
        assertEq(IMPL.codehash, 0x89df8d1ddb712742b9d7bdfa4048cbcdb651e5abc204b8e1714f8a431c5dad90);
        adapter = AdapterImplementation(predicted);
        assertEq(adapter.owner(), SAFE);
        assertEq(address(adapter.identityRegistry()), REGISTRY);
        assertEq(address(uint160(uint256(vm.load(predicted, SLOT)))), IMPL);
        emit log_named_address("rehearsed proxy", predicted);
    }

    function _matrix() internal {
        MockERC721 t0 = new MockERC721();
        t0.mint(holder, 1);
        targets[0] = address(t0);
        MockERC1155 t1 = new MockERC1155();
        t1.mint(holder, 1, 1);
        targets[1] = address(t1);
        MockERC6909 t2 = new MockERC6909();
        t2.mint(holder, 1, 1);
        targets[2] = address(t2);
        MockERC1155F t3 = new MockERC1155F();
        t3.mint(holder, 1);
        targets[3] = address(t3);
        MockERC6909F t4 = new MockERC6909F();
        t4.mint(holder, 1);
        targets[4] = address(t4);
        targets[5] = holder;
        targets[6] = address(new RobinhoodControllerFixture(holder));
        targets[7] = address(new RobinhoodControllerFixture(holder));
        for (uint256 i; i < 8; ++i) {
            IERC8217.Standard standard = IERC8217.Standard(i);
            uint256 tokenId = i < 5 ? 1 : 0;
            vm.prank(address(0xbad));
            vm.expectRevert();
            adapter.register(standard, targets[i], tokenId, "bad");
            vm.prank(holder);
            ids[i] = adapter.register(standard, targets[i], tokenId, "ipfs://new");
            assertEq(adapter.ownerOf(ids[i]), address(adapter));
            assertEq(adapter.getAgentWallet(ids[i]), address(0));
            assertEq(adapter.getMetadata(ids[i], "agent-binding"), abi.encodePacked(address(adapter)));
            assertTrue(adapter.isController(ids[i], holder));
            assertFalse(adapter.isController(ids[i], address(0xbad)));
            vm.prank(address(0xbad));
            vm.expectRevert();
            adapter.setAgentURI(ids[i], "bad");
            vm.startPrank(holder);
            adapter.setAgentURI(ids[i], "ipfs://updated");
            adapter.setMetadata(ids[i], "rehearsal", hex"1234");
            adapter.unsetAgentWallet(ids[i]);
            bytes32 ubid = adapter.counterfactualRegister(standard, targets[i], tokenId, "ipfs://counterfactual");
            assertEq(ubid, adapter.bindingHashOf(ids[i]));
            assertEq(ubid, adapter.hashBinding(standard, targets[i], tokenId));
            vm.recordLogs();
            adapter.setWalletUBID(standard, targets[i], tokenId);
            adapter.clearWalletUBID();
            Vm.Log[] memory logs = vm.getRecordedLogs();
            assertEq(logs.length, 2);
            assertEq(logs[0].emitter, address(adapter));
            assertEq(logs[0].topics[0], keccak256("WalletUBIDSet(address,bytes32,address,uint256,uint8,address)"));
            assertEq(logs[0].topics[2], ubid);
            assertEq(logs[1].topics[0], keccak256("WalletUBIDCleared(address,address)"));
            vm.recordLogs();
            adapter.attest(IERC8004AdapterAttestation.AttestationType.STAR, ubid, bytes32(0), hex"01");
            logs = vm.getRecordedLogs();
            (bytes32 attestationId,,) = abi.decode(logs[0].data, (bytes32, bytes32, bytes));
            assertEq(
                attestationId,
                keccak256(
                    abi.encode(
                        adapter.interoperableAddress(address(adapter)),
                        holder,
                        ubid,
                        IERC8004AdapterAttestation.AttestationType.STAR,
                        block.number,
                        bytes32(0),
                        hex"01"
                    )
                )
            );
            adapter.confirmAdditionalAccount(ubid);
            vm.recordLogs();
            adapter.revoke(attestationId);
            logs = vm.getRecordedLogs();
            assertEq(logs[0].topics[1], attestationId);
            assertEq(logs[0].topics[2], bytes32(uint256(uint160(holder))));
            vm.stopPrank();
        }
        IRobinhoodDelegate registry = IRobinhoodDelegate(adapter.DELEGATE_REGISTRY());
        assertEq(address(registry).codehash, 0x9deccbdeb08111dbf1c31292cbd0be06a662688ddcca594f681a7de809b61ba9);
        bytes32 rights = adapter.DELEGATE_RIGHTS();
        for (uint256 i; i < 5; ++i) {
            vm.prank(holder);
            registry.delegateERC721(delegate, targets[i], 1, rights, true);
            assertEq(adapter.isController(ids[i], delegate), i == 0 || i == 3 || i == 4);
        }
        vm.prank(holder);
        registry.delegateAll(delegate, rights, true);
        assertTrue(adapter.isController(ids[5], delegate));
        vm.prank(holder);
        registry.delegateAll(delegate, rights, false);
        assertFalse(adapter.isController(ids[5], delegate));
        vm.prank(holder);
        registry.delegateContract(delegate, targets[6], rights, true);
        assertTrue(adapter.isController(ids[6], delegate));
        assertFalse(adapter.isController(ids[7], delegate));
    }

    function _walletSignaturePath() internal {
        RobinhoodWalletFixture wallet = new RobinhoodWalletFixture();
        uint256 deadline = block.timestamp + 60;
        bytes32 domain = keccak256(
            abi.encode(
                keccak256("EIP712Domain(string name,string version,uint256 chainId,address verifyingContract)"),
                keccak256("ERC8004IdentityRegistry"),
                keccak256("1"),
                block.chainid,
                REGISTRY
            )
        );
        bytes32 body = keccak256(
            abi.encode(
                keccak256("AgentWalletSet(uint256 agentId,address newWallet,address owner,uint256 deadline)"),
                ids[0],
                address(wallet),
                address(adapter),
                deadline
            )
        );
        wallet.expectDigest(keccak256(abi.encodePacked(hex"1901", domain, body)));
        vm.prank(holder);
        vm.expectRevert();
        adapter.setAgentWallet(ids[0], address(wallet), deadline, hex"bad0");
        vm.prank(address(0xbad));
        vm.expectRevert();
        adapter.setAgentWallet(ids[0], address(wallet), deadline, hex"1234");
        vm.prank(holder);
        adapter.setAgentWallet(ids[0], address(wallet), deadline, hex"1234");
        assertEq(adapter.getAgentWallet(ids[0]), address(wallet));
        vm.prank(holder);
        adapter.unsetAgentWallet(ids[0]);
        assertEq(adapter.getAgentWallet(ids[0]), address(0));
    }

    function _upgrade() internal {
        RobinhoodFutureImplementation next = new RobinhoodFutureImplementation(REGISTRY);
        vm.prank(holder);
        vm.expectRevert();
        adapter.upgradeToAndCall(address(next), "");
        bytes32 oldSlot0 = vm.load(address(adapter), bytes32(0));
        // An invalid UUPS target must fail through the real Safe, too (GS013 with zero gas fields).
        _safeCall(abi.encodeCall(adapter.upgradeToAndCall, (targets[0], bytes(""))), false);
        vm.recordLogs();
        bytes32 txHash = _safeCall(abi.encodeCall(adapter.upgradeToAndCall, (address(next), bytes(""))), true);
        Vm.Log[] memory logs = vm.getRecordedLogs();
        bool success;
        bool upgraded;
        for (uint256 i; i < logs.length; ++i) {
            if (logs[i].emitter == SAFE && logs[i].topics[0] == keccak256("ExecutionSuccess(bytes32,uint256)")) {
                assertEq(logs[i].topics[1], txHash);
                success = true;
            }
            if (logs[i].emitter == address(adapter) && logs[i].topics[0] == keccak256("Upgraded(address)")) {
                assertEq(address(uint160(uint256(logs[i].topics[1]))), address(next));
                upgraded = true;
            }
        }
        assertTrue(success);
        assertTrue(upgraded);
        assertEq(IRobinhoodSafe(SAFE).nonce(), 1);
        assertEq(IRobinhoodSafe(SAFE).getThreshold(), 2);
        assertEq(vm.load(address(adapter), bytes32(0)), oldSlot0);
        assertEq(address(uint160(uint256(vm.load(address(adapter), SLOT)))), address(next));
        assertEq(RobinhoodFutureImplementation(address(adapter)).rehearsalVersion(), 2);
    }

    function _safeCall(bytes memory data, bool succeeds) internal returns (bytes32 hash) {
        IRobinhoodSafe safe = IRobinhoodSafe(SAFE);
        address[] memory owners = safe.getOwners();
        for (uint256 i; i < owners.length; ++i) {
            for (uint256 j = i + 1; j < owners.length; ++j) {
                if (uint160(owners[j]) < uint160(owners[i])) (owners[i], owners[j]) = (owners[j], owners[i]);
            }
        }
        hash = safe.getTransactionHash(address(adapter), 0, data, 0, 0, 0, 0, address(0), address(0), safe.nonce());
        bytes memory signatures;
        for (uint256 i; i < 2; ++i) {
            vm.prank(owners[i]);
            safe.approveHash(hash);
            signatures =
                bytes.concat(signatures, abi.encodePacked(bytes32(uint256(uint160(owners[i]))), bytes32(0), uint8(1)));
        }
        // A single approved owner is insufficient under the intended 2-of-4 policy.
        vm.expectRevert();
        safe.execTransaction(
            address(adapter),
            0,
            data,
            0,
            0,
            0,
            0,
            address(0),
            payable(address(0)),
            abi.encodePacked(bytes32(uint256(uint160(owners[0]))), bytes32(0), uint8(1))
        );
        if (!succeeds) vm.expectRevert();
        bool ok =
            safe.execTransaction(address(adapter), 0, data, 0, 0, 0, 0, address(0), payable(address(0)), signatures);
        if (succeeds) assertTrue(ok);
    }
}
