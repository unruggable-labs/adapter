// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Test} from "forge-std/Test.sol";
import {Vm} from "forge-std/Vm.sol";
import {ERC1967Proxy} from "@openzeppelin/contracts/proxy/ERC1967/ERC1967Proxy.sol";
import {Adapter8004} from "../../src/Adapter8004.sol";
import {IERC8004AdapterAttestation} from "../../src/interfaces/IERC8004AdapterAttestation.sol";
import {IERC8217} from "../../src/interfaces/IERC8217.sol";
import {MockIdentityRegistry} from "../mocks/MockIdentityRegistry.sol";

/// R1 #17 was revoke-before-attest. This is type/data preimage: CONFIRM vs RATING with empty payload.
contract GrokR2_15_AttestationTypePreimage is Test {
    /// Success condition: confirmAdditionalAccount and attest(RATING, empty) share an attestationId.
    function test_defense_confirmAndRatingDoNotShareAnIdentifier() external {
        MockIdentityRegistry registry = new MockIdentityRegistry();
        Adapter8004 adapter = Adapter8004(
            address(
                new ERC1967Proxy(
                    address(new Adapter8004(address(registry))),
                    abi.encodeCall(Adapter8004.initialize, (makeAddr("admin")))
                )
            )
        );
        address alice = makeAddr("alice");
        bytes32 ubid = adapter.hashBinding(IERC8217.Standard.ACCOUNT, alice, 0);

        vm.recordLogs();
        vm.startPrank(alice);
        adapter.confirmAdditionalAccount(ubid);
        adapter.attest(IERC8004AdapterAttestation.AttestationType.RATING, ubid, bytes32(0), "");
        vm.stopPrank();
        Vm.Log[] memory logs = vm.getRecordedLogs();

        bytes32 topic = IERC8004AdapterAttestation.Attested.selector;
        bytes32 idConfirm;
        bytes32 idRating;
        uint256 n;
        for (uint256 i; i < logs.length; ++i) {
            if (logs[i].topics[0] != topic) continue;
            (bytes32 id,,) = abi.decode(logs[i].data, (bytes32, bytes32, bytes));
            if (n == 0) idConfirm = id;
            if (n == 1) idRating = id;
            ++n;
        }
        assertEq(n, 2);
        assertTrue(idConfirm != idRating, "attestationType is in the preimage");
    }
}
