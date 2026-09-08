// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Script} from "forge-std/Script.sol";
import {console2} from "forge-std/console2.sol";
import {AdapterImplementation} from "../src/AdapterImplementation.sol";
import {IERC8217} from "../src/interfaces/IERC8217.sol";
import {UUPSUpgradeable} from "@openzeppelin/contracts-upgradeable/proxy/utils/UUPSUpgradeable.sol";

/// @notice Safe-owned UUPS upgrade flow for `AdapterImplementation`.
///
/// The production proxies on Ethereum, Base, and Sepolia are owned by a Gnosis Safe
/// (see `deployments/2026-05-15-ownership-transfer-to-safe-report.md`), so the deployer
/// EOA can no longer call `upgradeToAndCall` directly. This script therefore performs
/// ONLY the EOA-side step: it deploys the new implementation contract. It deliberately
/// does NOT call `upgradeToAndCall`.
///
/// After the broadcast, the script prints:
///        - `to`    = the proxy address (`ADAPTER_PROXY_ADDRESS`)
///        - `value` = 0
///        - `data`  = `upgradeToAndCall(newImplementation, "")`
///        - the implementation runtime code hash
///
/// This script does not write a Safe payload. Generate that only after the implementation
/// deployment and runtime code have been independently verified.
///
/// Upgrade data is empty: the active Mainnet/Base and Sepolia implementations both use only
/// regular slots 0/1. Slot 0 is reserved and bindings stay at slot 1. No new storage
/// needs initialization; do not call an initializer or migration during this upgrade.
contract DeployAdapterImplementationScript is Script {
    /// @notice Thrown when this script runs on a chain id outside the production set
    /// (`1` mainnet, `8453` base, `11155111` sepolia). Stops the script before any
    /// deployment can begin on an unknown network.
    error UnsupportedChainId(uint256 chainId);

    /// @notice Thrown when `ADAPTER_PROXY_ADDRESS` does not match the canonical proxy
    /// for `block.chainid`. This prevents deploying against one chain while reading
    /// the registry from another chain's proxy address.
    error MismatchedProxyForChain(uint256 chainId, address expected, address supplied);

    /// @notice Canonical AdapterImplementation UUPS proxy on Ethereum Mainnet (chainId 1).
    address internal constant ADAPTER_PROXY_MAINNET = 0xde152AfB7db5373F34876E1499fbD893A82dD336;
    /// @notice Canonical AdapterImplementation UUPS proxy on Base (chainId 8453).
    address internal constant ADAPTER_PROXY_BASE = 0x270d25D2c59A8bcA1B0f40ad95fF7806c0025c27;
    /// @notice Canonical AdapterImplementation UUPS proxy on Sepolia (chainId 11155111).
    address internal constant ADAPTER_PROXY_SEPOLIA = 0x7621630cB63a73a194f45A3E6801B8C6A7eC2f92;

    /// @notice Event signature strings printed by `run()` so operators can subscribe to the right
    /// topics after the upgrade. They are constants rather than inline literals so a test can hold
    /// them against the compiler's own event selectors. There is exactly one copy of each string,
    /// and `DeployAdapterImplementationEventSignatures.t.sol` fails if any drifts from the contract.
    string internal constant SIG_PRIMARY_COUNTERFACTUAL_AGENT_SET =
        "WalletUBIDSet(address,bytes32,address,uint256,uint8,address)";
    string internal constant SIG_CF_REGISTERED =
        "CounterfactualAgentRegistered(bytes32,address,uint256,uint8,string,(string,bytes)[],address)";
    string internal constant SIG_CF_URI_SET = "CounterfactualAgentURISet(bytes32,address,uint256,uint8,string,address)";
    string internal constant SIG_CF_METADATA_SET =
        "CounterfactualMetadataSet(bytes32,address,uint256,uint8,string,bytes,address)";
    string internal constant SIG_CF_METADATA_BATCH_SET =
        "CounterfactualMetadataBatchSet(bytes32,address,uint256,uint8,(string,bytes)[],address)";
    string internal constant SIG_CF_WALLET_SET =
        "CounterfactualAgentWalletSet(bytes32,address,uint256,uint8,address,address)";
    string internal constant SIG_CF_WALLET_UNSET =
        "CounterfactualAgentWalletUnset(bytes32,address,uint256,uint8,address)";
    string internal constant SIG_AGENT_BOUND = "AgentBound(uint256,uint8,address,uint256,address)";
    string internal constant SIG_ATTESTED = "Attested(address,uint8,bytes32,bytes32,bytes32,bytes)";
    string internal constant SIG_ATTESTATION_REVOKED = "AttestationRevoked(bytes32,address)";

    function run() external returns (address proxy, address implementation, bytes memory upgradeCalldata) {
        proxy = vm.envAddress("ADAPTER_PROXY_ADDRESS");

        // 0. Refuse to proceed unless `ADAPTER_PROXY_ADDRESS` matches the canonical proxy for the
        //    current chain. This prevents writing a chain-named Safe TX JSON whose `to` field
        //    points at a different chain's proxy. Runs BEFORE any broadcast or file write.
        _requireProxyMatchesChain(proxy, block.chainid);

        uint256 deployerKey = vm.envUint("DEPLOYER_PRIVATE_KEY");
        // 1. Preserve the live registry. Both outgoing and current implementations authorize
        //    upgrades by owner only; registry equality is checked here, not enforced on chain.
        //    Safe signers must independently check it before executing the upgrade.
        address liveRegistry = address(AdapterImplementation(payable(proxy)).identityRegistry());
        require(liveRegistry != address(0), "live proxy reports no identity registry");
        require(
            liveRegistry == vm.envAddress("IDENTITY_REGISTRY_ADDRESS"),
            "IDENTITY_REGISTRY_ADDRESS does not match the live proxy registry"
        );

        // 2. EOA-side step: deploy ONLY the new implementation, with the registry baked in. No
        //    upgrade call here.
        vm.startBroadcast(deployerKey);
        implementation = address(new AdapterImplementation(liveRegistry));
        vm.stopBroadcast();

        // 3. Refuse to proceed unless the constructed implementation reports the live registry back.
        //    Reads it from the deployed runtime rather than trusting the argument just passed in.
        require(
            address(AdapterImplementation(payable(implementation)).identityRegistry()) == liveRegistry,
            "deployed implementation reports a different registry"
        );

        // 4. Build the calldata the Safe must execute against the proxy. Empty upgrade data:
        //    Slot 0 remains reserved and bindings remain at slot 1. No initializer or migration.
        upgradeCalldata = abi.encodeCall(UUPSUpgradeable.upgradeToAndCall, (implementation, bytes("")));

        // 5. Print the Safe Transaction Builder parameters for this chain.
        console2.log("=== Safe Transaction Builder parameters ===");
        console2.log("to (proxy address):");
        console2.logAddress(proxy);
        console2.log("value:");
        console2.logUint(0);
        console2.log("new implementation (just deployed):");
        console2.logAddress(implementation);
        console2.log("implementation runtime code hash:");
        console2.logBytes32(implementation.codehash);
        console2.log("data (upgradeToAndCall(newImplementation, 0x)):");
        console2.logBytes(upgradeCalldata);
        bytes memory identifier = _chainIdentifier(block.chainid);
        console2.log("ERC-7930 Chain Identifier expected from proxy after upgrade:");
        console2.logBytes(identifier);
        bytes memory proxyInteroperableAddress = _interoperableAddress(block.chainid, proxy);
        console2.log("ERC-7930 Interoperable Address for proxy:");
        console2.logBytes(proxyInteroperableAddress);
        console2.log("Sample hashBinding(proxy, standard=ERC721, boundAddress=0x1, tokenId=0):");
        console2.logBytes32(_sampleUbid(proxyInteroperableAddress, IERC8217.Standard.ERC721, address(1), 0));

        console2.log("=== New wallet-id event topic[0] hashes ===");
        console2.logBytes32(keccak256(bytes(SIG_PRIMARY_COUNTERFACTUAL_AGENT_SET)));

        console2.log("=== Counterfactual event topic[0] hashes (subscribe to these post-upgrade) ===");
        _logSignature("CounterfactualAgentRegistered", SIG_CF_REGISTERED);
        _logSignature("CounterfactualAgentURISet", SIG_CF_URI_SET);
        _logSignature("CounterfactualMetadataSet", SIG_CF_METADATA_SET);
        _logSignature("CounterfactualMetadataBatchSet", SIG_CF_METADATA_BATCH_SET);
        _logSignature("CounterfactualAgentWalletSet", SIG_CF_WALLET_SET);
        _logSignature("CounterfactualAgentWalletUnset", SIG_CF_WALLET_UNSET);
        console2.log("AgentBound (existing):");
        console2.logBytes32(keccak256(bytes(SIG_AGENT_BOUND)));

        console2.log("=== New attestation event topic[0] hashes (subscribe to these post-upgrade) ===");
        _logSignature("Attested", SIG_ATTESTED);
        _logSignature("AttestationRevoked", SIG_ATTESTATION_REVOKED);
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
    function _sampleUbid(
        bytes memory proxyInteroperableAddress,
        IERC8217.Standard standard,
        address boundAddress,
        uint256 tokenId
    ) internal pure returns (bytes32) {
        return keccak256(abi.encode(proxyInteroperableAddress, standard, boundAddress, tokenId));
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
