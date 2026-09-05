// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Test} from "forge-std/Test.sol";
import {Vm} from "forge-std/Vm.sol";
import {ERC1967Proxy} from "@openzeppelin/contracts/proxy/ERC1967/ERC1967Proxy.sol";

import {Adapter8004} from "../../src/Adapter8004.sol";
import {IERC8217} from "../../src/interfaces/IERC8217.sol";
import {IERC8004AdapterAttestation} from "../../src/interfaces/IERC8004AdapterAttestation.sol";
import {IERC8004IdentityRegistry} from "../../src/interfaces/IERC8004IdentityRegistry.sol";

/// A registry that reenters the adapter's UNGUARDED attestation surface during `register`.
contract ReentrantAttestRegistry is IERC8004IdentityRegistry {
    uint256 public lastId;
    address public adapter;
    bytes32 public target;
    mapping(uint256 => mapping(string => bytes)) private _meta;

    function arm(address a, bytes32 t) external {
        adapter = a;
        target = t;
    }

    function _reg() internal returns (uint256 id) {
        id = lastId++;
        if (adapter != address(0)) {
            // Reenter the emit-only, non-guarded surface while the adapter holds its register guard.
            Adapter8004(adapter).attest(IERC8004AdapterAttestation.AttestationType.STAR, target, bytes32(0), "");
        }
    }

    function register(string memory, MetadataEntry[] memory) external returns (uint256) {
        return _reg();
    }

    function register(string memory) external returns (uint256) {
        return _reg();
    }

    function register() external returns (uint256) {
        return _reg();
    }

    function setMetadata(uint256 agentId, string memory k, bytes memory v) external {
        _meta[agentId][k] = v;
    }

    function setAgentURI(uint256, string calldata) external {}
    function setAgentWallet(uint256, address, uint256, bytes calldata) external {}
    function unsetAgentWallet(uint256) external {}

    function getMetadata(uint256 agentId, string memory k) external view returns (bytes memory) {
        return _meta[agentId][k];
    }

    function getAgentWallet(uint256) external pure returns (address) {
        return address(0);
    }

    function ownerOf(uint256) external view returns (address) {
        return adapter;
    }

    function tokenURI(uint256) external pure returns (string memory) {
        return "";
    }
}

/// SdR3 #7 — RegistryReentrantAttest. The emit-only surface (`attest`/`revoke`/`setWalletUBID`) is
/// deliberately NOT `nonReentrant`, so the identity registry can reenter it while the adapter holds
/// its `register` guard. NOT one of the prior 40: R2 #12 reentered a GUARDED function (`setAgentURI`)
/// and was blocked; this reenters an UNGUARDED one and is not. Defended-by-design: the registry is
/// immutable/trusted, the reentrant attester is truthfully the registry (no adapter impersonation),
/// and no adapter state is corrupted.
contract SdR3_7_RegistryReentrantAttest is Test {
    ReentrantAttestRegistry internal registry;
    Adapter8004 internal adapter;

    address internal admin = makeAddr("admin");
    address internal attacker = makeAddr("attacker");

    bytes32 internal constant ATTESTED_SIG =
        keccak256("Attested(address,uint8,bytes32,bytes32,bytes32,bytes)");

    function setUp() external {
        registry = new ReentrantAttestRegistry();
        Adapter8004 impl = new Adapter8004(address(registry));
        ERC1967Proxy proxy = new ERC1967Proxy(address(impl), abi.encodeCall(Adapter8004.initialize, (admin)));
        adapter = Adapter8004(address(proxy));
        registry.arm(address(adapter), keccak256("reentrant-ubid"));
    }

    /// Success condition: an `Attested` event is emitted DURING `register` (the unguarded surface is
    /// reentrant), and its attester is the registry, not the adapter.
    function test_registryReentersUnguardedAttestDuringRegister() external {
        vm.recordLogs();
        vm.prank(attacker);
        adapter.register(IERC8217.Standard.ACCOUNT, attacker, 0, "ipfs://a");

        Vm.Log[] memory logs = vm.getRecordedLogs();
        bool sawAttested;
        for (uint256 i; i < logs.length; ++i) {
            if (logs[i].topics[0] == ATTESTED_SIG) {
                sawAttested = true;
                assertEq(address(uint160(uint256(logs[i].topics[1]))), address(registry), "attester is the registry, not the adapter");
            }
        }
        assertTrue(sawAttested, "reentrant attest was not blocked by the register guard");
    }
}
