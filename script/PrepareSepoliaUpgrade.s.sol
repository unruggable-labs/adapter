// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Script} from "forge-std/Script.sol";
import {VmSafe} from "forge-std/Vm.sol";
import {console2} from "forge-std/console2.sol";
import {AdapterImplementation} from "../src/AdapterImplementation.sol";
import {UUPSUpgradeable} from "@openzeppelin/contracts-upgradeable/proxy/utils/UUPSUpgradeable.sol";

/// @notice Prepares calldata for an ALREADY DEPLOYED and independently verified implementation.
/// Never broadcasts, signs, deploys, or submits a Safe proposal. The upgrade is simulated locally.
contract PrepareSepoliaUpgradeScript is Script {
    address internal constant PROXY = 0x7621630cB63a73a194f45A3E6801B8C6A7eC2f92;
    address internal constant BASELINE = 0x31a68E5bc0224ad081d6Ec20229B05F558609257;
    bytes32 internal constant BASELINE_CODEHASH = 0x73456940889758c5f2c923f33f189845658b4702127496dc52533eeaa1bae528;
    address internal constant SAFE = 0x03302Df40186D9B85faEA4fbb6cC5da028B23149;
    address internal constant REGISTRY = 0x8004A818BFB912233c491871b3d84c89A494BD9e;
    bytes32 internal constant IMPLEMENTATION_SLOT = 0x360894a13ba1a3210667c828492db98dca3e2076cc3735a920a3ca505d382bbc;

    function run() external returns (bytes memory data) {
        require(!vm.isContext(VmSafe.ForgeContext.ScriptBroadcast), "do not use --broadcast");
        require(!vm.isContext(VmSafe.ForgeContext.ScriptResume), "do not use --resume");
        require(block.chainid == 11155111, "Sepolia only");
        address implementation = vm.envAddress("ADAPTER_IMPLEMENTATION_ADDRESS");
        bytes32 approvedCodehash = vm.envBytes32("EXPECTED_IMPLEMENTATION_CODEHASH");
        require(implementation != BASELINE && implementation != PROXY, "not a new implementation");
        require(implementation.code.length != 0, "implementation is not deployed");
        require(implementation.codehash == approvedCodehash, "implementation codehash mismatch");
        require(BASELINE.codehash == BASELINE_CODEHASH, "baseline code changed");
        require(address(uint160(uint256(vm.load(PROXY, IMPLEMENTATION_SLOT)))) == BASELINE, "baseline changed");
        AdapterImplementation adapter = AdapterImplementation(PROXY);
        require(adapter.owner() == SAFE, "proxy owner changed");
        require(address(adapter.identityRegistry()) == REGISTRY, "proxy registry changed");
        require(
            address(AdapterImplementation(implementation).identityRegistry()) == REGISTRY,
            "implementation registry mismatch"
        );
        require(AdapterImplementation(implementation).proxiableUUID() == IMPLEMENTATION_SLOT, "not UUPS compatible");
        data = abi.encodeCall(UUPSUpgradeable.upgradeToAndCall, (implementation, bytes("")));

        // Exercise the exact call locally. This is not a Safe signature/nonce validation.
        bytes memory bindingBefore = abi.encode(adapter.bindingOf(9124));
        vm.prank(SAFE);
        (bool success, bytes memory result) = PROXY.call(data);
        if (!success) {
            assembly {
                revert(add(result, 32), mload(result))
            }
        }
        require(address(uint160(uint256(vm.load(PROXY, IMPLEMENTATION_SLOT)))) == implementation, "upgrade failed");
        require(adapter.owner() == SAFE, "owner not preserved");
        require(address(adapter.identityRegistry()) == REGISTRY, "registry not preserved");
        require(keccak256(abi.encode(adapter.bindingOf(9124))) == keccak256(bindingBefore), "binding not preserved");

        string memory json = string.concat(
            '{"version":"1.0","chainId":"11155111","createdAt":',
            vm.toString(block.timestamp * 1000),
            ',"meta":{"name":"AdapterImplementation v0.0.17 Sepolia upgrade","description":"Upgrade only. No initializer. Verified implementation runtime hash: ',
            vm.toString(approvedCodehash),
            '. Preserve registry and existing bindings. Counterfactual indexer cutover required.","txBuilderVersion":"1.18.0","createdFromSafeAddress":"',
            vm.toString(SAFE),
            '","createdFromOwnerAddress":""},"transactions":[{"to":"',
            vm.toString(PROXY),
            '","value":"0","data":"',
            vm.toString(data),
            '","contractMethod":null,"contractInputsValues":null}]}'
        );
        vm.writeFile("deployments/v0.0.17-safe-tx-sepolia-verified.json", json);
        console2.log("Safe target:");
        console2.logAddress(PROXY);
        console2.log("Safe calldata (value 0, CALL operation):");
        console2.logBytes(data);
    }
}
