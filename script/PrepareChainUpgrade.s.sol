// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Script} from "forge-std/Script.sol";
import {VmSafe} from "forge-std/Vm.sol";
import {AdapterImplementation} from "../src/AdapterImplementation.sol";

interface IUpgradeSafe {
    function getThreshold() external view returns (uint256);
    function getOwners() external view returns (address[] memory);
    function nonce() external view returns (uint256);
    function getTransactionHash(
        address,
        uint256,
        bytes calldata,
        uint8,
        uint256,
        uint256,
        uint256,
        address,
        address,
        uint256
    ) external view returns (bytes32);
    function approveHash(bytes32) external;
    function execTransaction(
        address,
        uint256,
        bytes calldata,
        uint8,
        uint256,
        uint256,
        uint256,
        address,
        address payable,
        bytes calldata
    ) external payable returns (bool);
}

/// @notice Base/Ethereum preparation only. Does not broadcast, sign, or submit proposals.
/// Run only after the actual implementation is deployed and independently verified.
contract PrepareChainUpgradeScript is Script {
    address constant SAFE = 0x03302Df40186D9B85faEA4fbb6cC5da028B23149;
    address constant REGISTRY = 0x8004A169FB4a3325136EB29fA0ceB6D2e539a432;
    bytes32 constant SLOT = 0x360894a13ba1a3210667c828492db98dca3e2076cc3735a920a3ca505d382bbc;

    function run() external returns (bytes memory data) {
        (string memory json, bytes memory callData) =
            prepare(vm.envAddress("ADAPTER_IMPLEMENTATION_ADDRESS"), vm.envBytes32("EXPECTED_IMPLEMENTATION_CODEHASH"));
        vm.writeFile(string.concat("deployments/v0.0.17-safe-tx-", vm.toString(block.chainid), "-verified.json"), json);
        return callData;
    }

    function prepare(address implementation, bytes32 approvedHash)
        public
        returns (string memory json, bytes memory data)
    {
        require(!vm.isContext(VmSafe.ForgeContext.ScriptBroadcast), "do not use --broadcast");
        require(!vm.isContext(VmSafe.ForgeContext.ScriptResume), "do not use --resume");
        (address proxy, address baseline, bytes32 baselineHash) = _chain();
        require(implementation != baseline && implementation != proxy, "not a new implementation");
        require(implementation.code.length != 0, "implementation is not deployed");
        require(implementation.codehash == approvedHash, "implementation codehash mismatch");
        require(implementation.codehash == expectedRuntimeHash(implementation), "runtime differs from local build");
        require(baseline.codehash == baselineHash, "baseline code changed");
        require(address(uint160(uint256(vm.load(proxy, SLOT)))) == baseline, "baseline changed");
        AdapterImplementation adapter = AdapterImplementation(proxy);
        require(adapter.owner() == SAFE, "owner changed");
        require(address(adapter.identityRegistry()) == REGISTRY, "registry changed");
        bytes32 slot0 = vm.load(proxy, bytes32(0));
        require(address(uint160(uint256(slot0))) == REGISTRY, "legacy slot zero changed");
        require(
            address(AdapterImplementation(implementation).identityRegistry()) == REGISTRY,
            "implementation registry mismatch"
        );
        require(AdapterImplementation(implementation).proxiableUUID() == SLOT, "not UUPS");
        data = abi.encodeCall(adapter.upgradeToAndCall, (implementation, bytes("")));
        uint256 nonce = _execute(proxy, data);
        require(address(uint160(uint256(vm.load(proxy, SLOT)))) == implementation, "upgrade failed");
        require(
            vm.load(proxy, bytes32(0)) == slot0 && adapter.owner() == SAFE
                && address(adapter.identityRegistry()) == REGISTRY,
            "state not preserved"
        );
        json = _json(proxy, data, nonce, approvedHash);
    }

    function _execute(address proxy, bytes memory data) internal returns (uint256 nonce) {
        IUpgradeSafe safe = IUpgradeSafe(SAFE);
        require(safe.getThreshold() == 3, "expected live 3-of-4");
        address[] memory owners = safe.getOwners();
        require(owners.length == 4, "expected four owners");
        for (uint256 i; i < owners.length; ++i) {
            for (uint256 j = i + 1; j < owners.length; ++j) {
                if (uint160(owners[j]) < uint160(owners[i])) (owners[i], owners[j]) = (owners[j], owners[i]);
            }
        }
        nonce = safe.nonce();
        bytes32 txHash = safe.getTransactionHash(proxy, 0, data, 0, 0, 0, 0, address(0), address(0), nonce);
        bytes memory signatures;
        for (uint256 i; i < 3; ++i) {
            vm.prank(owners[i]);
            safe.approveHash(txHash);
            signatures =
                bytes.concat(signatures, abi.encodePacked(bytes32(uint256(uint160(owners[i]))), bytes32(0), uint8(1)));
        }
        require(
            safe.execTransaction(proxy, 0, data, 0, 0, 0, 0, address(0), payable(address(0)), signatures),
            "Safe execution failed"
        );
        require(safe.nonce() == nonce + 1 && safe.getThreshold() == 3, "Safe state mismatch");
    }

    function _json(address proxy, bytes memory data, uint256 nonce, bytes32 approvedHash)
        internal
        view
        returns (string memory json)
    {
        json = string.concat(
            '{"version":"1.0","chainId":"',
            vm.toString(block.chainid),
            '","createdAt":',
            vm.toString(block.timestamp * 1000),
            ',"meta":{"name":"Adapter v0.0.17 upgrade","description":"Upgrade only; no initializer. Rehearsed Safe nonce ',
            vm.toString(nonce),
            " at block ",
            vm.toString(block.number),
            "; runtime ",
            vm.toString(approvedHash),
            '. Recheck nonce/configuration before signing. Indexer cutover required.","txBuilderVersion":"1.18.0","createdFromSafeAddress":"',
            vm.toString(SAFE),
            '","createdFromOwnerAddress":""},"transactions":[{"to":"',
            vm.toString(proxy),
            '","value":"0","data":"',
            vm.toString(data),
            '","contractMethod":null,"contractInputsValues":null}]}'
        );
    }

    /// The registry immutable is already populated by the constructor. Patch only the three
    /// UUPS __self words from this local reference's address to the real implementation address.
    /// This fails closed if compiler/source changes alter the expected self-reference count.
    function expectedRuntimeHash(address implementation) public returns (bytes32) {
        address referenceImpl = address(new AdapterImplementation(REGISTRY));
        bytes memory expected = referenceImpl.code;
        bytes32 referenceWord = bytes32(uint256(uint160(referenceImpl)));
        bytes32 actualWord = bytes32(uint256(uint160(implementation)));
        uint256 replaced;
        for (uint256 i; i + 32 <= expected.length; ++i) {
            bytes32 word;
            assembly {
                word := mload(add(add(expected, 32), i))
            }
            if (word == referenceWord) {
                assembly {
                    mstore(add(add(expected, 32), i), actualWord)
                }
                ++replaced;
                i += 31;
            }
        }
        require(replaced == 3, "unexpected UUPS immutable layout");
        return keccak256(expected);
    }

    function _chain() internal view returns (address, address, bytes32) {
        if (block.chainid == 8453) {
            return (
                0x270d25D2c59A8bcA1B0f40ad95fF7806c0025c27,
                0x0f81bd4EDD4879734361A1A44460264CBf6F94c9,
                0xe41935cf07fd522c59c7d317ebef5d540e22d38fe76ad5a59d44458036fe2200
            );
        }
        if (block.chainid == 1) {
            return (
                0xde152AfB7db5373F34876E1499fbD893A82dD336,
                0xa6D23f27D3b1780B12488482a008cB3c3787135f,
                0x6dffd09f335889c7b2a7a1407c28dfdf8e49cabf5a76ae14a31e266ab8f105c8
            );
        }
        revert("unsupported chain");
    }
}
