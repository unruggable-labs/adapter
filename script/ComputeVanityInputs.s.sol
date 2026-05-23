// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Script, console2} from "forge-std/Script.sol";
import {Adapter8004} from "../src/Adapter8004.sol";
import {ERC1967Proxy} from "@openzeppelin/contracts/proxy/ERC1967/ERC1967Proxy.sol";

/// @notice Computes the CREATE2 inputs for the vanity miner.
///
/// The canonical proxy is deployed as `ERC1967Proxy(impl, "")` — empty init data —
/// so its init code is byte-identical on every chain, which is what lets one mined
/// salt produce the same vanity address everywhere. `initialize(registry, owner)`
/// is called separately, per chain.
///
/// The implementation is deployed deterministically (CREATE2 salt 0) so its address
/// is identical across chains; that address is baked into the proxy init code.
///
/// Run: forge script script/ComputeVanityInputs.s.sol:ComputeVanityInputs
contract ComputeVanityInputs is Script {
    /// Canonical Arachnid CREATE2 deployer (forge-std provides `CREATE2_FACTORY`
    /// = 0x4e59b44847b379578588920cA78FbF26c0B4956C), present on Mainnet, Base, Sepolia.
    bytes32 constant IMPL_SALT = bytes32(0);

    /// ERC-8004 IdentityRegistry, identical on Mainnet and Base. (Sepolia differs:
    /// 0x8004A818BFB912233c491871b3d84c89A494BD9e — it would get a different proxy
    /// address and should be deployed separately.)
    address constant REGISTRY = 0x8004A169FB4a3325136EB29fA0ceB6D2e539a432;

    /// Safe multisig owner, identical across all three chains.
    address constant OWNER = 0x03302Df40186D9B85faEA4fbb6cC5da028B23149;

    function run() external pure {
        bytes32 implInitCodeHash = keccak256(type(Adapter8004).creationCode);
        address impl = vm.computeCreate2Address(IMPL_SALT, implInitCodeHash, CREATE2_FACTORY);

        // Bake initialize() into the proxy constructor so deployment is atomic
        // (no front-run window) and the init code is identical on every chain that
        // shares REGISTRY + OWNER (Mainnet + Base) -> same vanity address there.
        bytes memory initData = abi.encodeCall(Adapter8004.initialize, (REGISTRY, OWNER));
        bytes memory proxyInitCode = abi.encodePacked(type(ERC1967Proxy).creationCode, abi.encode(impl, initData));
        bytes32 proxyInitCodeHash = keccak256(proxyInitCode);

        console2.log("CREATE2 factory (deployer):", CREATE2_FACTORY);
        console2.log("registry baked in:", REGISTRY);
        console2.log("owner baked in:", OWNER);
        console2.log("impl deterministic address:", impl);
        console2.log("impl init code hash:");
        console2.logBytes32(implInitCodeHash);
        console2.log("");
        console2.log(">>> mine against this proxy init code hash:");
        console2.logBytes32(proxyInitCodeHash);
    }
}
