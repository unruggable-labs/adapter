// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Script, console2} from "forge-std/Script.sol";
import {Adapter8004} from "../src/Adapter8004.sol";
import {ERC1967Proxy} from "@openzeppelin/contracts/proxy/ERC1967/ERC1967Proxy.sol";

/// @notice Computes the CREATE2 inputs for the vanity miner.
///
/// **These scripts describe a deployment that was never performed.** As of 2026-08-19 the live
/// proxies and implementations sit at unrelated addresses on all three chains:
/// implementations `0xa6D23f27…` (Mainnet), `0x0f81bd4E…` (Base), `0x31a68E5b…` (Sepolia), and
/// proxies `0xde152AfB…`, `0x270d25D2…`, `0x7621630c…`. Mainnet and Base run identical source, so
/// CREATE2 at a fixed salt would have put their implementations at one address; it did not. The
/// 2026-04-05 report records why — each chain got "a fresh implementation contract and a fresh
/// `ERC1967Proxy`" — and `DeployAdapterImplementation.s.sol`, the script upgrades actually use,
/// calls plain `new Adapter8004()` with no salt, so every future implementation is nonce-derived
/// and per-chain by construction. Cross-chain address determinism is therefore a property this
/// deployment has never had, and no change to the contract can cost it something it does not hold.
/// Treat the paragraphs below as a design sketch for a future redeployment, not a description of
/// what is live.
///
/// The canonical proxy is deployed as `ERC1967Proxy(impl, "")` — empty init data —
/// so its init code is byte-identical on every chain, which is what lets one mined
/// salt produce the same vanity address everywhere. `initialize(registry, owner)`
/// is called separately, per chain.
///
/// The implementation would be deployed deterministically (CREATE2 salt 0) so its
/// address is identical across chains; that address is baked into the proxy init code.
/// The live implementations are NOT deployed this way and sit at three unrelated
/// addresses; see `DeployVanityProxy.s.sol` for the evidence.
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
        // The registry is a constructor argument since `0.0.17`, so it is part of the
        // implementation init code and therefore part of the implementation's vanity address.
        bytes32 implInitCodeHash = keccak256(abi.encodePacked(type(Adapter8004).creationCode, abi.encode(REGISTRY)));
        address impl = vm.computeCreate2Address(IMPL_SALT, implInitCodeHash, CREATE2_FACTORY);

        // Bake initialize() into the proxy constructor so deployment is atomic
        // (no front-run window) and the init code is identical on every chain that
        // shares REGISTRY + OWNER (Mainnet + Base) -> same vanity address there.
        bytes memory initData = abi.encodeCall(Adapter8004.initialize, (OWNER));
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
