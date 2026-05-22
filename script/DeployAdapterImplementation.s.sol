// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Script} from "forge-std/Script.sol";
import {console2} from "forge-std/console2.sol";
import {Adapter8004} from "../src/Adapter8004.sol";
import {UUPSUpgradeable} from "@openzeppelin/contracts-upgradeable/proxy/utils/UUPSUpgradeable.sol";

/// @notice Safe-owned UUPS upgrade flow for `Adapter8004`.
///
/// The production proxies on Ethereum, Base, and Sepolia are owned by a Gnosis Safe
/// (see `deployments/2026-05-15-ownership-transfer-to-safe-report.md`), so the deployer
/// EOA can no longer call `upgradeToAndCall` directly. This script therefore performs
/// ONLY the EOA-side step: it deploys the new implementation contract. It deliberately
/// does NOT call `upgradeToAndCall`.
///
/// After the broadcast, the script:
///   1. Prints the exact transaction the Safe signers must submit through the Safe
///      Transaction Builder:
///        - `to`    = the proxy address (`ADAPTER_PROXY_ADDRESS`)
///        - `value` = 0
///        - `data`  = `upgradeToAndCall(newImplementation, "")`
///   2. Writes a ready-to-import Safe Transaction Builder JSON to
///      `deployments/2026-05-20-bindexisting-counterfactual-v1-safe-tx-<network>.json`,
///      where `<network>` is derived from `block.chainid` via `_networkNames`. The Safe
///      signers can drag-and-drop that file into the Transaction Builder instead of
///      copy-pasting raw calldata. The JSON description includes the implementation
///      EXTCODEHASH so signers can independently compare it against
///      `keccak256(eth_getCode(<implementation>))`.
///
/// Initializer bytes are empty: the bindExisting + counterfactual v1 changes add only
/// constants, a new function, and event/interface surface changes — no new storage and
/// no `reinitializer`, so the proxy needs no post-upgrade initialization call.
contract DeployAdapterImplementationScript is Script {
    /// @notice Thrown when this script runs on a chain id outside the production set
    /// (`1` mainnet, `8453` base, `11155111` sepolia). Stops the script before any
    /// JSON artifact is written under an unknown filename.
    error UnsupportedChainId(uint256 chainId);

    /// @notice Thrown when `ADAPTER_PROXY_ADDRESS` does not match the canonical proxy
    /// for `block.chainid`. Without this guard, an operator running the script on
    /// Mainnet with the Base proxy in their env would write a Mainnet-named Safe TX
    /// JSON whose `to` field points at the Base proxy, misrouting the upgrade.
    error MismatchedProxyForChain(uint256 chainId, address expected, address supplied);

    /// @notice Safe-owner address used in the JSON `meta.createdFromSafeAddress` field.
    /// The Safe Transaction Builder uses this only for display; signers MUST still
    /// open the Safe app for the matching chain and submit against this Safe.
    address internal constant SAFE_ADDRESS = 0x03302Df40186D9B85faEA4fbb6cC5da028B23149;

    /// @notice Canonical Adapter8004 UUPS proxy on Ethereum Mainnet (chainId 1).
    address internal constant ADAPTER_PROXY_MAINNET = 0xde152AfB7db5373F34876E1499fbD893A82dD336;
    /// @notice Canonical Adapter8004 UUPS proxy on Base (chainId 8453).
    address internal constant ADAPTER_PROXY_BASE = 0x270d25D2c59A8bcA1B0f40ad95fF7806c0025c27;
    /// @notice Canonical Adapter8004 UUPS proxy on Sepolia (chainId 11155111).
    address internal constant ADAPTER_PROXY_SEPOLIA = 0x7621630cB63a73a194f45A3E6801B8C6A7eC2f92;

    function run() external returns (address proxy, address implementation, bytes memory upgradeCalldata) {
        proxy = vm.envAddress("ADAPTER_PROXY_ADDRESS");

        // 0. Refuse to proceed unless `ADAPTER_PROXY_ADDRESS` matches the canonical proxy for the
        //    current chain. This prevents writing a chain-named Safe TX JSON whose `to` field
        //    points at a different chain's proxy. Runs BEFORE any broadcast or file write.
        _requireProxyMatchesChain(proxy, block.chainid);

        uint256 deployerKey = vm.envUint("DEPLOYER_PRIVATE_KEY");
        (string memory networkSlug, string memory networkDisplayName) = _networkNames(block.chainid);

        // 1. EOA-side step: deploy ONLY the new implementation. No upgrade call here.
        vm.startBroadcast(deployerKey);
        implementation = address(new Adapter8004());
        vm.stopBroadcast();

        // 2. Build the calldata the Safe must execute against the proxy. Empty initializer
        //    bytes — the bindExisting + counterfactual v1 change is constants, logic, and
        //    event/interface surface only, no storage migration.
        upgradeCalldata = abi.encodeCall(UUPSUpgradeable.upgradeToAndCall, (implementation, bytes("")));

        // 3. Print the Safe Transaction Builder parameters for this chain.
        console2.log("=== Safe Transaction Builder parameters ===");
        console2.log("to (proxy address):");
        console2.logAddress(proxy);
        console2.log("value:");
        console2.logUint(0);
        console2.log("new implementation (just deployed):");
        console2.logAddress(implementation);
        console2.log("data (upgradeToAndCall(newImplementation, 0x)):");
        console2.logBytes(upgradeCalldata);

        console2.log("=== Counterfactual event topic[0] hashes (subscribe to these post-upgrade) ===");
        console2.log(
            "CounterfactualAgentRegistered signature: CounterfactualAgentRegistered(bytes32,address,uint256,uint8,uint8,string,(string,bytes)[],address)"
        );
        console2.log("CounterfactualAgentRegistered:");
        console2.logBytes32(
            keccak256(
                bytes(
                    "CounterfactualAgentRegistered(bytes32,address,uint256,uint8,uint8,string,(string,bytes)[],address)"
                )
            )
        );
        console2.log(
            "CounterfactualAgentURISet signature: CounterfactualAgentURISet(bytes32,address,uint256,uint8,string,address)"
        );
        console2.log("CounterfactualAgentURISet:");
        console2.logBytes32(keccak256(bytes("CounterfactualAgentURISet(bytes32,address,uint256,uint8,string,address)")));
        console2.log(
            "CounterfactualMetadataSet signature: CounterfactualMetadataSet(bytes32,address,uint256,uint8,string,bytes,address)"
        );
        console2.log("CounterfactualMetadataSet:");
        console2.logBytes32(
            keccak256(bytes("CounterfactualMetadataSet(bytes32,address,uint256,uint8,string,bytes,address)"))
        );
        console2.log(
            "CounterfactualMetadataBatchSet signature: CounterfactualMetadataBatchSet(bytes32,address,uint256,uint8,(string,bytes)[],address)"
        );
        console2.log("CounterfactualMetadataBatchSet:");
        console2.logBytes32(
            keccak256(bytes("CounterfactualMetadataBatchSet(bytes32,address,uint256,uint8,(string,bytes)[],address)"))
        );
        console2.log(
            "CounterfactualAgentWalletSet signature: CounterfactualAgentWalletSet(bytes32,address,uint256,uint8,address,address)"
        );
        console2.log("CounterfactualAgentWalletSet:");
        console2.logBytes32(
            keccak256(bytes("CounterfactualAgentWalletSet(bytes32,address,uint256,uint8,address,address)"))
        );
        console2.log(
            "CounterfactualAgentWalletUnset signature: CounterfactualAgentWalletUnset(bytes32,address,uint256,uint8,address)"
        );
        console2.log("CounterfactualAgentWalletUnset:");
        console2.logBytes32(keccak256(bytes("CounterfactualAgentWalletUnset(bytes32,address,uint256,uint8,address)")));
        console2.log("AgentBound (existing, also emitted by bindExisting):");
        console2.logBytes32(keccak256(bytes("AgentBound(uint256,uint8,address,uint256,address)")));

        // 4. Persist a Safe Transaction Builder JSON next to the existing per-chain artifacts.
        _writeSafeTxJson(proxy, implementation, upgradeCalldata, networkSlug, networkDisplayName);
    }

    /// @dev Writes the Safe Transaction Builder JSON for this chain. The chain id is
    /// mapped to a stable network slug used as the filename suffix; any other chain
    /// id reverts with `UnsupportedChainId` so the file is never written under an
    /// unknown name.
    function _writeSafeTxJson(
        address proxy,
        address implementation,
        bytes memory data,
        string memory networkSlug,
        string memory networkDisplayName
    ) internal {
        // Defense-in-depth: re-assert chainid↔proxy before the file write itself, in case the
        // caller (or a future refactor) reaches this helper without going through `run()`.
        _requireProxyMatchesChain(proxy, block.chainid);

        string memory path =
            string.concat("deployments/2026-05-20-bindexisting-counterfactual-v1-safe-tx-", networkSlug, ".json");
        bytes32 implementationCodehash;
        assembly {
            implementationCodehash := extcodehash(implementation)
        }

        // Safe Transaction Builder ingests this minimal shape: `version`, `chainId`,
        // `createdAt` (epoch milliseconds), `meta`, and a `transactions` array. Each
        // transaction is exposed as a raw / custom tx (`contractMethod = null`) with
        // `data` set to the upgradeToAndCall calldata bytes.
        string memory json = string.concat(
            "{\n",
            '  "version": "1.0",\n',
            '  "chainId": "',
            vm.toString(block.chainid),
            '",\n',
            '  "createdAt": ',
            vm.toString(block.timestamp * 1000),
            ",\n",
            '  "meta": {\n',
            '    "name": "Adapter8004 v0.0.6 - bindExisting + counterfactual v1 upgrade - ',
            networkDisplayName,
            '",\n',
            '    "description": "Upgrade the Adapter8004 UUPS proxy to v0.0.6, adding bindExisting and the versioned counterfactual event family (uint8 version, cf-registration reserved key). Implementation deployed at ',
            vm.toString(implementation),
            " (bytecode hash ",
            vm.toString(implementationCodehash),
            ') by DeployAdapterImplementation.s.sol. Empty initializer (constants + new function only, no new storage).",\n',
            '    "txBuilderVersion": "1.18.0",\n',
            '    "createdFromSafeAddress": "',
            vm.toString(SAFE_ADDRESS),
            '",\n',
            '    "createdFromOwnerAddress": ""\n',
            "  },\n",
            '  "transactions": [\n',
            "    {\n",
            '      "to": "',
            vm.toString(proxy),
            '",\n',
            '      "value": "0",\n',
            '      "data": "',
            vm.toString(data),
            '",\n',
            '      "contractMethod": null,\n',
            '      "contractInputsValues": null\n',
            "    }\n",
            "  ]\n",
            "}\n"
        );

        vm.writeFile(path, json);

        console2.log("Safe Transaction Builder JSON written to:");
        console2.log(path);
    }

    /// @dev Maps the production chain ids to the slug used in the JSON filename. Any
    /// other chain id reverts with `UnsupportedChainId` rather than writing a file
    /// under an unknown name.
    function _networkNames(uint256 chainId) internal pure returns (string memory slug, string memory displayName) {
        if (chainId == 1) return ("mainnet", "Mainnet");
        if (chainId == 8453) return ("base", "Base");
        if (chainId == 11155111) return ("sepolia", "Sepolia");
        revert UnsupportedChainId(chainId);
    }

    /// @dev Returns the canonical proxy address for `chainId`, or reverts with
    /// `UnsupportedChainId` for an unknown chain.
    function _expectedProxy(uint256 chainId) internal pure returns (address) {
        if (chainId == 1) return ADAPTER_PROXY_MAINNET;
        if (chainId == 8453) return ADAPTER_PROXY_BASE;
        if (chainId == 11155111) return ADAPTER_PROXY_SEPOLIA;
        revert UnsupportedChainId(chainId);
    }

    /// @dev Reverts with `MismatchedProxyForChain` if `proxy` is not the canonical proxy
    /// for `chainId`. Runs BEFORE any broadcast or file write so a misconfigured env
    /// cannot produce a malformed Safe TX JSON.
    function _requireProxyMatchesChain(address proxy, uint256 chainId) internal pure {
        address expected = _expectedProxy(chainId);
        if (proxy != expected) {
            revert MismatchedProxyForChain(chainId, expected, proxy);
        }
    }
}
