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
///      `deployments/2026-07-29-primary-split-erc7930-safe-tx-<network>.json`,
///      where `<network>` is derived from `block.chainid` via `_networkNames`. The Safe
///      signers can drag-and-drop that file into the Transaction Builder instead of
///      copy-pasting raw calldata. The JSON description includes the implementation
///      EXTCODEHASH so signers can independently compare it against
///      `keccak256(eth_getCode(<implementation>))`.
///
/// Upgrade data is empty: the active Mainnet/Base and Sepolia implementations both use only
/// regular slots 0/1. Adapter8004 appends three mappings directly at slots 2-4. New mappings
/// begin empty naturally; no migration or `reinitializer` is permitted.
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

    /// @notice Event signature strings printed by `run()` so operators can subscribe to the right
    /// topics after the upgrade. They are constants rather than inline literals so a test can hold
    /// them against the compiler's own event selectors. There is exactly one copy of each string,
    /// and `DeployAdapterImplementationEventSignatures.t.sol` fails if any drifts from the contract.
    string internal constant SIG_PRIMARY_AGENT_SET = "PrimaryAgentSet(address,uint256,address)";
    string internal constant SIG_PRIMARY_COUNTERFACTUAL_AGENT_SET =
        "PrimaryCounterfactualAgentSet(address,bytes32,address,uint256,bytes32,address)";
    string internal constant SIG_CF_REGISTERED =
        "CounterfactualAgentRegistered(bytes32,address,uint256,bytes32,uint8,string,(string,bytes)[],address)";
    string internal constant SIG_CF_URI_SET =
        "CounterfactualAgentURISet(bytes32,address,uint256,bytes32,string,address)";
    string internal constant SIG_CF_METADATA_SET =
        "CounterfactualMetadataSet(bytes32,address,uint256,bytes32,string,bytes,address)";
    string internal constant SIG_CF_METADATA_BATCH_SET =
        "CounterfactualMetadataBatchSet(bytes32,address,uint256,bytes32,(string,bytes)[],address)";
    string internal constant SIG_CF_WALLET_SET =
        "CounterfactualAgentWalletSet(bytes32,address,uint256,bytes32,address,address)";
    string internal constant SIG_CF_WALLET_UNSET =
        "CounterfactualAgentWalletUnset(bytes32,address,uint256,bytes32,address)";
    string internal constant SIG_AGENT_BOUND = "AgentBound(uint256,uint8,address,uint256,address)";

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

        // 2. Build the calldata the Safe must execute against the proxy. Empty upgrade data:
        //    The implementation upgrades directly from the active slot-0/1 baselines and uses
        //    naturally empty append-only mappings, with no initializer, reinitializer, or migration.
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
        bytes memory identifier = _chainIdentifier(block.chainid);
        console2.log("ERC-7930 Chain Identifier expected from proxy after upgrade:");
        console2.logBytes(identifier);
        bytes memory proxyInteroperableAddress = _interoperableAddress(block.chainid, proxy);
        console2.log("ERC-7930 Interoperable Address for proxy:");
        console2.logBytes(proxyInteroperableAddress);
        console2.log("Sample registrationHash(proxy, tokenContract=0x1, tokenId=0):");
        console2.logBytes32(_sampleRegistrationHash(proxyInteroperableAddress, address(1), 0));

        console2.log("=== New primary-agent event topic[0] hashes ===");
        console2.logBytes32(keccak256(bytes(SIG_PRIMARY_AGENT_SET)));
        console2.logBytes32(keccak256(bytes(SIG_PRIMARY_COUNTERFACTUAL_AGENT_SET)));

        console2.log("=== Counterfactual event topic[0] hashes (subscribe to these post-upgrade) ===");
        _logSignature("CounterfactualAgentRegistered", SIG_CF_REGISTERED);
        _logSignature("CounterfactualAgentURISet", SIG_CF_URI_SET);
        _logSignature("CounterfactualMetadataSet", SIG_CF_METADATA_SET);
        _logSignature("CounterfactualMetadataBatchSet", SIG_CF_METADATA_BATCH_SET);
        _logSignature("CounterfactualAgentWalletSet", SIG_CF_WALLET_SET);
        _logSignature("CounterfactualAgentWalletUnset", SIG_CF_WALLET_UNSET);
        console2.log("AgentBound (existing, also emitted by bindExisting):");
        console2.logBytes32(keccak256(bytes(SIG_AGENT_BOUND)));

        // 4. Persist a Safe Transaction Builder JSON next to the existing per-chain artifacts.
        _writeSafeTxJson(proxy, implementation, upgradeCalldata, networkSlug, networkDisplayName);
    }

    /// @dev Prints one event's signature and its topic[0], so an operator can paste either into a
    /// subscription without deriving the hash themselves.
    function _logSignature(string memory name, string memory signature) internal pure {
        console2.log(string.concat(name, " signature: ", signature));
        console2.log(string.concat(name, ":"));
        console2.logBytes32(keccak256(bytes(signature)));
    }

    /// @dev The sample counterfactual identity printed by `run()`. It mirrors the contract's own
    /// preimage, and the accompanying test holds it against the contract so the two cannot diverge.
    function _sampleRegistrationHash(bytes memory proxyInteroperableAddress, address tokenContract, uint256 tokenId)
        internal
        pure
        returns (bytes32)
    {
        return keccak256(abi.encode(proxyInteroperableAddress, tokenContract, tokenId, bytes32(0)));
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
            string.concat("deployments/2026-07-29-primary-split-erc7930-safe-tx-", networkSlug, ".json");
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
            '    "name": "Adapter8004 v0.0.16 - split primaries, ERC-7930 hashes with reserved extraData, contract-binding authority - ',
            networkDisplayName,
            '",\n',
            '    "description": "Upgrade the Adapter8004 UUPS proxy directly from its active deployed implementation to v0.0.16. Separates full uint256 and counterfactual bytes32 primary-agent mappings/nonces/events, and changes every counterfactual registration hash to keccak256(abi.encode(ERC-7930 interoperableAddress(proxy), tokenContract, tokenId, extraData)), where extraData is a reserved discriminator fixed at bytes32(0) in this release. Three mappings append directly after the live layout at slots 2-4. Renames TokenStandard value 5 from CONTRACT to ACCOUNT and relaxes it to accept any address, with or without runtime code, since its authority is a bare msg.sender comparison that never calls the address; the enum position, all event topic0 values and every registrationHash are unchanged, but the NonZeroTokenIdForContract error is renamed NonZeroTokenIdForAccount and its selector changes. Two consequences of that relaxation a signer should see: the zero address is now rejected explicitly under every standard including ACCOUNT, because a zero tokenContract is the unbound sentinel, and a contract can now bind itself as ACCOUNT from its own constructor, which stays rejected for all seven other standards. ACCOUNT authority remains exactly msg.sender == tokenContract with no delegate.xyz route. Adds two contract-level binding standards, CONTRACT_OWNABLE (6) and CONTRACT_ADMIN (7), whose authority is the bound contract owner() or a DEFAULT_ADMIN_ROLE holder respectively and never the bound contract itself. Removes the MetadataBatchSet event; setMetadataBatch now emits one MetadataSet per entry. Compiled with solc 0.8.30 targeting the prague EVM, so the implementation EXTCODEHASH differs from any earlier build. Implementation deployed at ',
            vm.toString(implementation),
            " (bytecode hash ",
            vm.toString(implementationCodehash),
            ') by DeployAdapterImplementation.s.sol. Empty upgrade data (append-only mappings begin empty; no initializer, migration, or reinitializer).",\n',
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

    function _chainIdentifier(uint256 chainId) internal pure returns (bytes memory identifier) {
        uint256 length;
        uint256 remaining = chainId;
        while (remaining != 0) {
            ++length;
            remaining >>= 8;
        }
        identifier = new bytes(length + 6);
        identifier[1] = 0x01;
        identifier[4] = bytes1(uint8(length));
        for (uint256 i; i < length; ++i) {
            identifier[5 + length - 1 - i] = bytes1(uint8(chainId >> (i * 8)));
        }
    }

    function _interoperableAddress(uint256 chainId, address account)
        internal
        pure
        returns (bytes memory interoperable)
    {
        bytes memory identifier = _chainIdentifier(chainId);
        interoperable = new bytes(identifier.length + 20);
        for (uint256 i; i < identifier.length - 1; ++i) {
            interoperable[i] = identifier[i];
        }
        interoperable[identifier.length - 1] = 0x14;
        bytes20 rawAddress = bytes20(account);
        for (uint256 i; i < 20; ++i) {
            interoperable[identifier.length + i] = rawAddress[i];
        }
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
