// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Script, console2} from "forge-std/Script.sol";
import {Adapter8004} from "../src/Adapter8004.sol";
import {ERC1967Proxy} from "@openzeppelin/contracts/proxy/ERC1967/ERC1967Proxy.sol";

/// @notice Deploys the canonical Adapter8004 proxy at a CREATE2 vanity address.
///
/// Two CREATE2 deploys via the canonical factory (forge-std `CREATE2_FACTORY`,
/// 0x4e59...), both idempotent:
///   1. The implementation at a fixed salt (deterministic, same address on every
///      chain). The address is cosmetic; the proxy stays upgradeable via UUPS.
///   2. The proxy at the mined `PROXY_SALT`, with `initialize(registry, owner)`
///      baked into the constructor data so deployment is atomic (no front-run
///      window). On chains that share REGISTRY + OWNER (Mainnet + Base) the init
///      code is identical, so the same salt yields the same vanity address.
///
/// The deploy is permissionless: any funded EOA can run it; ownership is set to
/// the Safe by the baked initializer, not by the deployer.
///
/// Usage (simulate):  PROXY_SALT=0x... forge script script/DeployVanityProxy.s.sol --rpc-url <url>
/// Usage (broadcast): PROXY_SALT=0x... forge script script/DeployVanityProxy.s.sol --rpc-url <url> --broadcast
contract DeployVanityProxy is Script {
    bytes32 constant IMPL_SALT = bytes32(0);

    /// Safe multisig owner, identical across all three chains.
    address constant OWNER = 0x03302Df40186D9B85faEA4fbb6cC5da028B23149;

    address constant REGISTRY_MAINNET_BASE = 0x8004A169FB4a3325136EB29fA0ceB6D2e539a432;
    address constant REGISTRY_SEPOLIA = 0x8004A818BFB912233c491871b3d84c89A494BD9e;

    function run() external {
        bytes32 proxySalt = vm.envBytes32("PROXY_SALT");
        address registry = _registryForChain();

        // 1. Predict + (idempotently) deploy the implementation.
        bytes32 implInitCodeHash = keccak256(type(Adapter8004).creationCode);
        address predictedImpl = vm.computeCreate2Address(IMPL_SALT, implInitCodeHash, CREATE2_FACTORY);

        // 2. Predict the proxy address from the baked init code.
        bytes memory initData = abi.encodeCall(Adapter8004.initialize, (registry, OWNER));
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
            impl = address(new Adapter8004{salt: IMPL_SALT}());
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
        Adapter8004 adapter = Adapter8004(address(proxy));
        require(adapter.owner() == OWNER, "owner not set to Safe");
        require(address(adapter.identityRegistry()) == registry, "registry not set");

        console2.log("deployed proxy:", address(proxy));
        console2.log("verified owner == Safe and identityRegistry == registry");
    }

    function _registryForChain() internal view returns (address) {
        if (block.chainid == 1 || block.chainid == 8453) {
            return REGISTRY_MAINNET_BASE;
        }
        if (block.chainid == 11155111) {
            // NOTE: Sepolia's registry differs, so a salt mined for Mainnet/Base
            // will NOT produce the same vanity address here. Mine a Sepolia-specific
            // salt against the Sepolia init code if a testnet vanity is wanted.
            return REGISTRY_SEPOLIA;
        }
        revert("unsupported chain");
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
