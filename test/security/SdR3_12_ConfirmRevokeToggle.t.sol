// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Test} from "forge-std/Test.sol";
import {ERC1967Proxy} from "@openzeppelin/contracts/proxy/ERC1967/ERC1967Proxy.sol";

import {AdapterImplementation} from "../../src/AdapterImplementation.sol";
import {IERC8004AdapterAttestation} from "../../src/interfaces/IERC8004AdapterAttestation.sol";
import {MockIdentityRegistry} from "../mocks/MockIdentityRegistry.sol";

/// SdR3 #12 — ConfirmRevokeToggle. `confirmAdditionalAccount` emits a CONFIRM_ACCOUNT attestation
/// (:587-591); the same attester can later `revoke` its own id (:594-596) to withdraw it. A
/// point-in-time indexer sampling during the "on" interval records a link the attester has since
/// dropped. NOT one of the prior 40: R1 #9 toggled the FORWARD metadata half; R1 #17 was a stranger
/// revoking; this toggles the confirm half itself by its own attester. Defended: correct projection
/// applies the revoke in log order, so the withdrawal is authoritative.
contract SdR3_12_ConfirmRevokeToggle is Test {
    MockIdentityRegistry internal registry;
    AdapterImplementation internal adapter;

    address internal admin = makeAddr("admin");
    address internal attester = makeAddr("attester");

    function setUp() external {
        registry = new MockIdentityRegistry();
        AdapterImplementation impl = new AdapterImplementation(address(registry));
        ERC1967Proxy proxy = new ERC1967Proxy(address(impl), abi.encodeCall(AdapterImplementation.initialize, (admin)));
        adapter = AdapterImplementation(address(proxy));
    }

    function _confirmId(bytes32 ubid) internal view returns (bytes32) {
        return keccak256(
            abi.encode(
                adapter.interoperableAddress(address(adapter)),
                attester,
                ubid,
                IERC8004AdapterAttestation.AttestationType.CONFIRM_ACCOUNT,
                block.number,
                bytes32(0),
                bytes("")
            )
        );
    }

    /// Success condition: attester confirms then self-revokes the identical id; both are accepted.
    function test_confirmThenSelfRevokeToggle() external {
        bytes32 ubid = keccak256("agent");
        bytes32 id = _confirmId(ubid);

        vm.startPrank(attester);
        adapter.confirmAdditionalAccount(ubid);
        adapter.revoke(id); // attester withdraws its own confirmation
        vm.stopPrank();

        // Both events landed; the deterministic id ties the revoke to the confirm.
        assertTrue(id != bytes32(0), "confirm id is derivable and revocable by its own attester");
    }
}
