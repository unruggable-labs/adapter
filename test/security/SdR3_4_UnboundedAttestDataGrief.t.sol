// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Test} from "forge-std/Test.sol";
import {Vm} from "forge-std/Vm.sol";
import {ERC1967Proxy} from "@openzeppelin/contracts/proxy/ERC1967/ERC1967Proxy.sol";

import {Adapter8004} from "../../src/Adapter8004.sol";
import {IERC8004AdapterAttestation} from "../../src/interfaces/IERC8004AdapterAttestation.sol";
import {MockIdentityRegistry} from "../mocks/MockIdentityRegistry.sol";

/// SdR3 #4 — UnboundedAttestDataGrief. `attest` (:582-619) applies no length cap to `data`, so an
/// attacker can emit arbitrarily large `Attested` logs to grief indexers/log storage. NOT one of the
/// prior 40: no prior scenario tests calldata/log-size economics. A pure revert would be accepted;
/// this documents that no cap exists (economic griefing, attacker pays gas — defended by design).
contract SdR3_4_UnboundedAttestDataGrief is Test {
    MockIdentityRegistry internal registry;
    Adapter8004 internal adapter;

    address internal admin = makeAddr("admin");
    address internal attacker = makeAddr("attacker");

    function setUp() external {
        registry = new MockIdentityRegistry();
        Adapter8004 impl = new Adapter8004(address(registry));
        ERC1967Proxy proxy = new ERC1967Proxy(address(impl), abi.encodeCall(Adapter8004.initialize, (admin)));
        adapter = Adapter8004(address(proxy));
    }

    /// Success condition: a very large `data` payload is accepted and emitted, uncapped.
    function test_largeAttestationPayloadIsUncapped() external {
        bytes memory big = new bytes(40_000);
        vm.recordLogs();
        vm.prank(attacker);
        adapter.attest(IERC8004AdapterAttestation.AttestationType.REVIEW, keccak256("ubid"), bytes32(0), big);

        Vm.Log[] memory logs = vm.getRecordedLogs();
        assertEq(logs.length, 1, "the oversized attestation was emitted, not rejected");
    }
}
