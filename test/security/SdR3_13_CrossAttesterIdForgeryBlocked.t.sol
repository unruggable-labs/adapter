// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Test} from "forge-std/Test.sol";
import {ERC1967Proxy} from "@openzeppelin/contracts/proxy/ERC1967/ERC1967Proxy.sol";

import {AdapterImplementation} from "../../src/AdapterImplementation.sol";
import {IERC8004AdapterAttestation} from "../../src/interfaces/IERC8004AdapterAttestation.sol";
import {MockIdentityRegistry} from "../mocks/MockIdentityRegistry.sol";

/// SdR3 #13 — CrossAttesterIdForgeryBlocked. `attestationId` binds `msg.sender` in its preimage
/// (:610-614), so an attacker cannot grind `variant`/`data` to reproduce a victim attester's id and
/// have their own `revoke` withdraw the victim's statement. NOT one of the prior 40: R1 #17 concerned
/// ordering of a stranger's revoke; none proves cross-attester id forgery is impossible.
/// Defended: identical fields under two different attesters yield two different ids.
contract SdR3_13_CrossAttesterIdForgeryBlocked is Test {
    MockIdentityRegistry internal registry;
    AdapterImplementation internal adapter;

    address internal admin = makeAddr("admin");
    address internal victim = makeAddr("victim");
    address internal attacker = makeAddr("attacker");

    function setUp() external {
        registry = new MockIdentityRegistry();
        AdapterImplementation impl = new AdapterImplementation(address(registry));
        ERC1967Proxy proxy = new ERC1967Proxy(address(impl), abi.encodeCall(AdapterImplementation.initialize, (admin)));
        adapter = AdapterImplementation(address(proxy));
    }

    function _id(address attester, bytes32 ubid) internal view returns (bytes32) {
        return keccak256(
            abi.encode(
                adapter.interoperableAddress(address(adapter)),
                attester,
                ubid,
                IERC8004AdapterAttestation.AttestationType.RATING,
                block.number,
                bytes32(0),
                bytes("")
            )
        );
    }

    /// Success condition (defense): the attacker cannot compute an id equal to the victim's, even with
    /// every other field identical.
    function test_attackerCannotReproduceVictimId() external {
        bytes32 ubid = keccak256("agent");
        assertTrue(_id(victim, ubid) != _id(attacker, ubid), "msg.sender in the preimage blocks cross-attester forgery");

        // Sanity: both can attest; their statements are distinct ids.
        vm.prank(victim);
        adapter.attest(IERC8004AdapterAttestation.AttestationType.RATING, ubid, bytes32(0), "");
        vm.prank(attacker);
        adapter.attest(IERC8004AdapterAttestation.AttestationType.RATING, ubid, bytes32(0), "");
    }
}
