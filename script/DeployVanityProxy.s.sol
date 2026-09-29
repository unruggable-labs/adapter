// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Script, console2} from "forge-std/Script.sol";
import {AdapterImplementation} from "../src/AdapterImplementation.sol";
import {ERC1967Proxy} from "@openzeppelin/contracts/proxy/ERC1967/ERC1967Proxy.sol";

import {VanityChainConfig} from "./VanityChainConfig.sol";

/// @notice Deploy a fresh vanity proxy; existing Base/Ethereum proxies upgrade in place.
/// @dev Two CREATE2 factory calls: salt-zero implementation, then mined-salt proxy.
/// Implementation addresses depend on registry, bytecode and factory. Proxy addresses also
/// depend on owner and salt. Matching inputs can be reused on Ethereum, Base and Robinhood;
/// Sepolia has a different registry and requires separate mining.
/// The proxy constructor atomically calls initialize(owner); ownership goes to the Safe.
/// Only the implementation deployment is idempotent; an existing proxy is rejected.
/// Simulate: PROXY_SALT=0x... forge script script/DeployVanityProxy.s.sol --rpc-url <url>
contract DeployVanityProxy is Script {
    bytes32 constant IMPL_SALT = bytes32(0);

    /// Safe multisig owner, fixed for the approved rollout.
    address constant OWNER = 0x03302Df40186D9B85faEA4fbb6cC5da028B23149;

    function run() external {
        bytes32 proxySalt = vm.envBytes32("PROXY_SALT");
        address registry = _registryForChain();

        // 1. Predict + (idempotently) deploy the implementation.
        bytes32 implInitCodeHash =
            keccak256(abi.encodePacked(type(AdapterImplementation).creationCode, abi.encode(registry)));
        address predictedImpl = vm.computeCreate2Address(IMPL_SALT, implInitCodeHash, CREATE2_FACTORY);

        // 2. Predict the proxy address from the baked init code. The registry is now a constructor
        //    argument rather than an initializer one, so it moved from `initData` into the
        //    implementation init code hash above.
        bytes memory initData = abi.encodeCall(AdapterImplementation.initialize, (OWNER));
        bytes memory proxyInitCode =
            abi.encodePacked(type(ERC1967Proxy).creationCode, abi.encode(predictedImpl, initData));
        address predictedProxy = vm.computeCreate2Address(proxySalt, keccak256(proxyInitCode), CREATE2_FACTORY);

        console2.log("chain id:", block.chainid);
        console2.log("registry:", registry);
        console2.log("owner (Safe):", OWNER);
        console2.log("predicted impl:", predictedImpl);
        console2.log("predicted proxy:", predictedProxy);
        console2.log("proxy leading zero nibbles:", _leadingZeroNibbles(predictedProxy));

        vm.startBroadcast();

        address impl = predictedImpl;
        if (predictedImpl.code.length == 0) {
            impl = address(new AdapterImplementation{salt: IMPL_SALT}(registry));
            require(impl == predictedImpl, "impl address mismatch");
            console2.log("deployed impl");
        } else {
            console2.log("impl already deployed; reusing");
        }

        require(predictedProxy.code.length == 0, "proxy already deployed at vanity address");
        ERC1967Proxy proxy = new ERC1967Proxy{salt: proxySalt}(impl, initData);
        require(address(proxy) == predictedProxy, "proxy address mismatch");

        vm.stopBroadcast();

        // 3. Post-deploy verification.
        AdapterImplementation adapter = AdapterImplementation(address(proxy));
        require(adapter.owner() == OWNER, "owner not set to Safe");
        require(address(adapter.identityRegistry()) == registry, "registry not set");

        console2.log("deployed proxy:", address(proxy));
        console2.log("verified owner == Safe and identityRegistry == registry");
    }

    function _registryForChain() internal view returns (address) {
        return VanityChainConfig.registryForChain(block.chainid);
    }

    function _leadingZeroNibbles(address a) internal pure returns (uint256 n) {
        bytes20 b = bytes20(a);
        for (uint256 i; i < 20; ++i) {
            uint8 byteVal = uint8(b[i]);
            if (byteVal == 0) {
                n += 2;
            } else if (byteVal < 0x10) {
                n += 1;
                break;
            } else {
                break;
            }
        }
    }
}
