// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Script, console2} from "forge-std/Script.sol";
import {AdapterImplementation} from "../src/AdapterImplementation.sol";
import {ERC1967Proxy} from "@openzeppelin/contracts/proxy/ERC1967/ERC1967Proxy.sol";

import {VanityChainConfig} from "./VanityChainConfig.sol";

/// @notice Compute CREATE2 inputs using the same chain selection as deployment.
/// @dev Proxy construction atomically initializes the Safe owner. Registry is an implementation
/// constructor argument. Addresses match across chains only when all CREATE2 inputs match.
/// Run offline: forge script script/ComputeVanityInputs.s.sol:ComputeVanityInputs --chain 4663
contract ComputeVanityInputs is Script {
    bytes32 constant IMPL_SALT = bytes32(0);
    /// Safe owner fixed for the approved rollout.
    address constant OWNER = 0x03302Df40186D9B85faEA4fbb6cC5da028B23149;

    function run() external view {
        address registry = _registryForChain();
        // The registry is a constructor argument since `0.0.17`, so it is part of the
        // implementation init code and therefore part of the implementation's vanity address.
        bytes32 implInitCodeHash =
            keccak256(abi.encodePacked(type(AdapterImplementation).creationCode, abi.encode(registry)));
        address impl = vm.computeCreate2Address(IMPL_SALT, implInitCodeHash, CREATE2_FACTORY);

        // Bake initialize() into the proxy constructor so deployment is atomic
        // (no front-run window) and the init code is identical on every chain that
        // shares REGISTRY + OWNER (Ethereum + Base + Robinhood) -> same vanity address there.
        bytes memory initData = abi.encodeCall(AdapterImplementation.initialize, (OWNER));
        bytes memory proxyInitCode = abi.encodePacked(type(ERC1967Proxy).creationCode, abi.encode(impl, initData));
        bytes32 proxyInitCodeHash = keccak256(proxyInitCode);

        console2.log("CREATE2 factory (deployer):", CREATE2_FACTORY);
        console2.log("registry baked in:", registry);
        console2.log("owner baked in:", OWNER);
        console2.log("impl deterministic address:", impl);
        console2.log("impl init code hash:");
        console2.logBytes32(implInitCodeHash);
        console2.log("");
        console2.log(">>> mine against this proxy init code hash:");
        console2.logBytes32(proxyInitCodeHash);
    }

    function _registryForChain() internal view returns (address) {
        return VanityChainConfig.registryForChain(block.chainid);
    }
}
