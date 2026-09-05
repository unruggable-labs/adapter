// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Test} from "forge-std/Test.sol";
import {ERC1967Proxy} from "@openzeppelin/contracts/proxy/ERC1967/ERC1967Proxy.sol";

import {Adapter8004} from "../../src/Adapter8004.sol";
import {IERC8004AdapterAttestation} from "../../src/interfaces/IERC8004AdapterAttestation.sol";
import {MockIdentityRegistry} from "../mocks/MockIdentityRegistry.sol";

/// SdR3 #10 — SameBlockReemitAfterRevoke. `attestationId` includes `block.number` and `variant`
/// (:610-614). Attest, self-revoke, then re-attest identical fields IN THE SAME BLOCK reproduce the
/// exact same id, so the log carries that id as attested-revoked-attested with only log order to
/// resolve it; changing `variant` is the on-chain escape. NOT one of the prior 40: R1 #17 was a
/// stranger revoking BEFORE the attest (ordering); R2 #15 was type-in-preimage. Neither re-emits an
/// identical statement after revoking it within one block. Defended: correct projection uses log
/// order and the attester can force a fresh id via `variant`.
contract SdR3_10_SameBlockReemitAfterRevoke is Test {
    MockIdentityRegistry internal registry;
    Adapter8004 internal adapter;

    address internal admin = makeAddr("admin");
    address internal attester = makeAddr("attester");

    function setUp() external {
        registry = new MockIdentityRegistry();
        Adapter8004 impl = new Adapter8004(address(registry));
        ERC1967Proxy proxy = new ERC1967Proxy(address(impl), abi.encodeCall(Adapter8004.initialize, (admin)));
        adapter = Adapter8004(address(proxy));
    }

    function _id(bytes32 ubid, bytes32 variant, bytes memory data) internal view returns (bytes32) {
        return keccak256(
            abi.encode(
                adapter.interoperableAddress(address(adapter)),
                attester,
                ubid,
                IERC8004AdapterAttestation.AttestationType.STAR,
                block.number,
                variant,
                data
            )
        );
    }

    /// Success condition: same-block re-attest reproduces the revoked id; a different variant escapes it.
    function test_sameBlockReemitCollidesWithRevokedId() external {
        bytes32 ubid = keccak256("ubid");
        bytes32 idSame = _id(ubid, bytes32(0), "");
        bytes32 idVariant = _id(ubid, bytes32("v2"), "");

        vm.startPrank(attester);
        adapter.attest(IERC8004AdapterAttestation.AttestationType.STAR, ubid, bytes32(0), "");
        adapter.revoke(idSame);
        adapter.attest(IERC8004AdapterAttestation.AttestationType.STAR, ubid, bytes32(0), ""); // same id, now ambiguous
        adapter.attest(IERC8004AdapterAttestation.AttestationType.STAR, ubid, bytes32("v2"), ""); // fresh id
        vm.stopPrank();

        assertTrue(idSame != idVariant, "variant is the on-chain escape from the same-block id collision");
    }
}
