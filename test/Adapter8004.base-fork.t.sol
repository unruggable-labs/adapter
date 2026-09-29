// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {PrepareChainUpgradeScript} from "../script/PrepareChainUpgrade.s.sol";
import {Test} from "forge-std/Test.sol";
import {Vm} from "forge-std/Vm.sol";
import {AdapterImplementation} from "../src/AdapterImplementation.sol";
import {IERC8004IdentityRegistry} from "../src/interfaces/IERC8004IdentityRegistry.sol";
import {IERC8217} from "../src/interfaces/IERC8217.sol";
import {MockERC721} from "./mocks/MockERC721.sol";
import {IRobinhoodSafe, IRobinhoodDelegate} from "./Adapter8004.robinhood-fork.t.sol";

interface IBaseLegacy {
    function registrationHash(address target, uint256 tokenId) external view returns (bytes32);
    function setIdentityRegistry(address registry) external;
    function rewriteBindingMetadata(uint256 id) external;
}

/// All mutations are local fork execution; live dependency code and storage are never replaced.
contract Adapter8004BaseForkTest is Test {
    address constant PROXY = 0x270d25D2c59A8bcA1B0f40ad95fF7806c0025c27;
    address constant BASELINE = 0x0f81bd4EDD4879734361A1A44460264CBf6F94c9;
    address constant SAFE = 0x03302Df40186D9B85faEA4fbb6cC5da028B23149;
    address constant REGISTRY = 0x8004A169FB4a3325136EB29fA0ceB6D2e539a432;
    bytes32 constant SLOT = 0x360894a13ba1a3210667c828492db98dca3e2076cc3735a920a3ca505d382bbc;
    AdapterImplementation adapter = AdapterImplementation(PROXY);

    function testBaseLiveBaselineUpgradeThroughThreeOwnerSafe() external {
        string memory rpc = vm.envOr("BASE_FORK_RPC_URL", string(""));
        if (bytes(rpc).length == 0) {
            vm.skip(true);
            return;
        }
        vm.createSelectFork(rpc, vm.envUint("BASE_FORK_BLOCK"));
        assertEq(block.chainid, 8453);
        assertEq(address(uint160(uint256(vm.load(PROXY, SLOT)))), BASELINE);
        assertEq(BASELINE.codehash, 0xe41935cf07fd522c59c7d317ebef5d540e22d38fe76ad5a59d44458036fe2200);
        assertEq(adapter.owner(), SAFE);
        assertEq(address(adapter.identityRegistry()), REGISTRY);
        bytes32 slot0 = vm.load(PROXY, bytes32(0));
        assertEq(address(uint160(uint256(slot0))), REGISTRY);
        assertEq(IRobinhoodSafe(SAFE).getThreshold(), 3);
        assertEq(IRobinhoodSafe(SAFE).getOwners().length, 4);
        uint256 nonce = IRobinhoodSafe(SAFE).nonce();
        bytes memory historical = _historicalSnapshot();
        _mustRevert(abi.encodeWithSignature("DELEGATE_REGISTRY()"));
        _mustRevert(abi.encodeWithSignature("DELEGATE_RIGHTS()"));
        _mustRevert(abi.encodeWithSignature("counterfactualPayloadVersion()"));
        MockERC721 token = new MockERC721();
        address holder = address(0xa11ce);
        address delegate = address(0xb0b);
        token.mint(holder, 1);
        vm.prank(holder);
        uint256 id = adapter.register(IERC8217.Standard.ERC721, address(token), 1, "ipfs://before");
        vm.prank(holder);
        adapter.setMetadata(id, "acceptance", hex"1234");
        // Removed owner-only calls really exist on a20035c.
        vm.startPrank(SAFE);
        IBaseLegacy(PROXY).setIdentityRegistry(REGISTRY);
        IBaseLegacy(PROXY).rewriteBindingMetadata(id);
        vm.stopPrank();
        _metadataBatch(id, holder, false);
        bytes memory beforeState = _snapshot(id);
        bytes32 oldHash = IBaseLegacy(PROXY).registrationHash(address(token), 1);
        assertEq(oldHash, keccak256(abi.encode(block.chainid, PROXY, address(token), uint256(1))));
        bytes32 oldTopic = _counterfactual(token, holder, oldHash, false);
        vm.prank(holder);
        IRobinhoodDelegate(0x00000000000000447e69651d841bD8D104Bed493).delegateERC721(
            delegate, address(token), 1, keccak256("adapter8004.manage"), true
        );
        assertFalse(adapter.isController(id, delegate));
        address candidate = vm.envOr("BASE_IMPLEMENTATION_ADDRESS", address(0));
        AdapterImplementation next =
            candidate == address(0) ? new AdapterImplementation(REGISTRY) : AdapterImplementation(candidate);
        _checkGenerator(address(next));
        vm.prank(holder);
        vm.expectRevert();
        adapter.upgradeToAndCall(address(next), "");
        _safeCall(abi.encodeCall(adapter.upgradeToAndCall, (address(token), bytes(""))), false);
        _safeCall(abi.encodeCall(adapter.upgradeToAndCall, (address(next), bytes(""))), true);
        assertEq(IRobinhoodSafe(SAFE).nonce(), nonce + 1);
        assertEq(IRobinhoodSafe(SAFE).getThreshold(), 3);
        assertEq(vm.load(PROXY, bytes32(0)), slot0);
        assertEq(address(uint160(uint256(vm.load(PROXY, SLOT)))), address(next));
        assertEq(adapter.owner(), SAFE);
        assertEq(address(adapter.identityRegistry()), REGISTRY);
        assertEq(_historicalSnapshot(), historical);
        assertEq(_snapshot(id), beforeState);
        _metadataBatch(id, holder, true);
        assertTrue(adapter.isController(id, holder));
        assertTrue(adapter.isController(id, delegate));
        vm.prank(delegate);
        adapter.setAgentURI(id, "ipfs://delegated");
        assertEq(adapter.tokenURI(id), "ipfs://delegated");
        _mustRevert(abi.encodeWithSignature("registrationHash(address,uint256)", address(token), 1));
        vm.startPrank(SAFE);
        _mustRevert(abi.encodeWithSignature("setIdentityRegistry(address)", REGISTRY));
        _mustRevert(abi.encodeWithSignature("rewriteBindingMetadata(uint256)", id));
        _mustRevert(abi.encodeWithSignature("initialize(address,address)", REGISTRY, SAFE));
        vm.stopPrank();
        _mustRevert(abi.encodeWithSignature("counterfactualPayloadVersion()"));
        bytes32 ubid = adapter.hashBinding(IERC8217.Standard.ERC721, address(token), 1);
        assertEq(
            ubid,
            keccak256(
                abi.encode(adapter.interoperableAddress(PROXY), IERC8217.Standard.ERC721, address(token), uint256(1))
            )
        );
        assertEq(adapter.bindingHashOf(id), ubid);
        assertNotEq(ubid, oldHash);
        // Registration topic is IDENTICAL across this cutover, while indexed key semantics change.
        assertEq(_counterfactual(token, holder, ubid, true), oldTopic);
        vm.prank(holder);
        uint256 accountId = adapter.register(IERC8217.Standard.ACCOUNT, holder, 0, "ipfs://new");
        assertEq(adapter.ownerOf(accountId), PROXY);
        assertEq(adapter.getAgentWallet(accountId), address(0));
        assertEq(adapter.getMetadata(accountId, "agent-binding"), abi.encodePacked(PROXY));
        vm.expectRevert();
        adapter.initialize(SAFE);
    }

    function _checkGenerator(address next) internal {
        uint256 snapshot = vm.snapshotState();
        PrepareChainUpgradeScript generator = new PrepareChainUpgradeScript();
        (string memory json, bytes memory data) = generator.prepare(next, next.codehash);
        assertEq(vm.parseJsonString(json, ".chainId"), "8453");
        assertEq(vm.parseJsonAddress(json, ".transactions[0].to"), PROXY);
        assertEq(vm.parseJsonString(json, ".transactions[0].value"), "0");
        assertEq(vm.parseJsonBytes(json, ".transactions[0].data"), data);
        assertEq(data, abi.encodeCall(adapter.upgradeToAndCall, (next, bytes(""))));
        assertTrue(vm.revertToState(snapshot));
    }

    function _counterfactual(MockERC721 token, address holder, bytes32 hash, bool current)
        internal
        returns (bytes32 topic)
    {
        vm.startPrank(holder);
        vm.recordLogs();
        assertEq(adapter.counterfactualRegister(IERC8217.Standard.ERC721, address(token), 1, "ipfs://cf"), hash);
        Vm.Log[] memory logs = vm.getRecordedLogs();
        assertEq(logs.length, 1);
        assertEq(logs[0].emitter, PROXY);
        topic = logs[0].topics[0];
        assertEq(
            topic,
            keccak256("CounterfactualAgentRegistered(bytes32,address,uint256,uint8,string,(string,bytes)[],address)")
        );
        assertEq(logs[0].topics[1], hash);
        _setter(
            abi.encodeWithSignature(
                "counterfactualSetAgentURI(uint8,address,uint256,string)",
                uint8(0),
                address(token),
                uint256(1),
                "ipfs://cf-update"
            ),
            hash,
            current,
            "CounterfactualAgentURISet(bytes32,address,uint256,string,address)",
            "CounterfactualAgentURISet(bytes32,address,uint256,uint8,string,address)"
        );
        _setter(
            abi.encodeWithSignature(
                "counterfactualSetMetadata(uint8,address,uint256,string,bytes)",
                uint8(0),
                address(token),
                uint256(1),
                "acceptance",
                hex"1234"
            ),
            hash,
            current,
            "CounterfactualMetadataSet(bytes32,address,uint256,string,bytes,address)",
            "CounterfactualMetadataSet(bytes32,address,uint256,uint8,string,bytes,address)"
        );
        IERC8004IdentityRegistry.MetadataEntry[] memory metadata = new IERC8004IdentityRegistry.MetadataEntry[](1);
        metadata[0] = IERC8004IdentityRegistry.MetadataEntry("acceptance", hex"1234");
        _setter(
            abi.encodeWithSignature(
                "counterfactualSetMetadataBatch(uint8,address,uint256,(string,bytes)[])",
                uint8(0),
                address(token),
                uint256(1),
                metadata
            ),
            hash,
            current,
            "CounterfactualMetadataBatchSet(bytes32,address,uint256,(string,bytes)[],address)",
            "CounterfactualMetadataBatchSet(bytes32,address,uint256,uint8,(string,bytes)[],address)"
        );
        _setter(
            abi.encodeWithSignature(
                "counterfactualSetAgentWallet(uint8,address,uint256,address)",
                uint8(0),
                address(token),
                uint256(1),
                holder
            ),
            hash,
            current,
            "CounterfactualAgentWalletSet(bytes32,address,uint256,address,address)",
            "CounterfactualAgentWalletSet(bytes32,address,uint256,uint8,address,address)"
        );
        _setter(
            abi.encodeWithSignature(
                "counterfactualUnsetAgentWallet(uint8,address,uint256)", uint8(0), address(token), uint256(1)
            ),
            hash,
            current,
            "CounterfactualAgentWalletUnset(bytes32,address,uint256,address)",
            "CounterfactualAgentWalletUnset(bytes32,address,uint256,uint8,address)"
        );
        vm.stopPrank();
    }

    function _setter(bytes memory data, bytes32 hash, bool current, string memory oldEvent, string memory newEvent)
        internal
    {
        vm.recordLogs();
        (bool ok, bytes memory result) = PROXY.call(data);
        assertTrue(ok);
        if (current) assertEq(abi.decode(result, (bytes32)), hash);
        else assertEq(result.length, 0);
        Vm.Log[] memory logs = vm.getRecordedLogs();
        assertEq(logs.length, 1);
        assertEq(logs[0].emitter, PROXY);
        assertEq(logs[0].topics[1], hash);
        assertEq(logs[0].topics[0], keccak256(bytes(current ? newEvent : oldEvent)));
    }

    function _metadataBatch(uint256 id, address holder, bool current) internal {
        IERC8004IdentityRegistry.MetadataEntry[] memory entries = new IERC8004IdentityRegistry.MetadataEntry[](2);
        entries[0] = IERC8004IdentityRegistry.MetadataEntry("batch-one", hex"11");
        entries[1] = IERC8004IdentityRegistry.MetadataEntry("batch-two", hex"22");
        vm.recordLogs();
        vm.prank(holder);
        adapter.setMetadataBatch(id, entries);
        Vm.Log[] memory logs = vm.getRecordedLogs();
        uint256 count;
        for (uint256 i; i < logs.length; ++i) {
            if (logs[i].emitter != PROXY) continue;
            assertEq(logs[i].topics[1], bytes32(id));
            assertEq(logs[i].topics[2], bytes32(uint256(uint160(holder))));
            if (current) {
                assertEq(logs[i].topics[0], keccak256("MetadataSet(uint256,string,bytes,address)"));
                assertEq(logs[i].data, abi.encode(entries[count].metadataKey, entries[count].metadataValue));
            } else {
                assertEq(logs[i].topics[0], keccak256("MetadataBatchSet(uint256,uint256,address)"));
                assertEq(abi.decode(logs[i].data, (uint256)), 2);
            }
            ++count;
        }
        assertEq(count, current ? 2 : 1);
        assertEq(adapter.getMetadata(id, "batch-one"), hex"11");
        assertEq(adapter.getMetadata(id, "batch-two"), hex"22");
    }

    function _snapshot(uint256 id) internal view returns (bytes memory) {
        bytes32 location = keccak256(abi.encode(id, uint256(1)));
        return abi.encode(
            adapter.bindingOf(id),
            adapter.ownerOf(id),
            adapter.tokenURI(id),
            adapter.getAgentWallet(id),
            adapter.getMetadata(id, "agent-binding"),
            adapter.getMetadata(id, "acceptance"),
            vm.load(PROXY, location),
            vm.load(PROXY, bytes32(uint256(location) + 1))
        );
    }

    function _historicalSnapshot() internal view returns (bytes memory result) {
        // IDs authenticated by AgentBound logs saved in output/base-agentbound-sample.json.
        _assertHistorical(
            54940,
            0,
            address(uint160(0x00a98741b7ee20b096a6262a705a088f8c0563dfa4)),
            15937932100925991812325947910190003186689914071532898381037119799454990286095
        );
        result = abi.encode(result, _snapshot(54940));
        _assertHistorical(
            54941,
            0,
            address(uint160(0x00c7aff3b228b8353d1811802f90f389815431a194)),
            113894107648431373942783369801897505824575245817250239423426313965162785169992
        );
        result = abi.encode(result, _snapshot(54941));
        _assertHistorical(
            54943,
            0,
            address(uint160(0x00a98741b7ee20b096a6262a705a088f8c0563dfa4)),
            99806881593247729731991958847568802536162247078085896632120378196459987573958
        );
        result = abi.encode(result, _snapshot(54943));
        _assertHistorical(54977, 0, address(uint160(0x00a99c4b08201f2913db8d28e71d020c4298f29dbf)), 22470);
        result = abi.encode(result, _snapshot(54977));
        _assertHistorical(61381, 0, address(uint160(0x00555555555c68dfee1288c4372e8bbaf272062f4e)), 8259);
        result = abi.encode(result, _snapshot(61381));
        _assertHistorical(61384, 0, address(uint160(0x00016df4c52fb5c0e1cb3432ebd6071a90b1f6dcd9)), 2406);
        result = abi.encode(result, _snapshot(61384));
    }

    function _assertHistorical(uint256 id, uint8 standard, address target, uint256 tokenId) internal view {
        IERC8217.Binding memory binding = adapter.bindingOf(id);
        assertEq(uint8(binding.standard), standard);
        assertEq(binding.boundAddress, target);
        assertEq(binding.tokenId, tokenId);
        assertEq(adapter.ownerOf(id), PROXY);
    }

    function _mustRevert(bytes memory data) internal {
        (bool ok,) = PROXY.call(data);
        assertFalse(ok);
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
        for (uint256 i; i < 3; ++i) {
            vm.prank(owners[i]);
            safe.approveHash(hash);
            signatures =
                bytes.concat(signatures, abi.encodePacked(bytes32(uint256(uint160(owners[i]))), bytes32(0), uint8(1)));
        }
        // Two approvals are insufficient at the live Base threshold of three.
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
            bytes.concat(
                abi.encodePacked(bytes32(uint256(uint160(owners[0]))), bytes32(0), uint8(1)),
                abi.encodePacked(bytes32(uint256(uint160(owners[1]))), bytes32(0), uint8(1))
            )
        );
        if (!succeeds) vm.expectRevert();
        bool ok =
            safe.execTransaction(address(adapter), 0, data, 0, 0, 0, 0, address(0), payable(address(0)), signatures);
        if (succeeds) assertTrue(ok);
    }
}
