// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Test} from "forge-std/Test.sol";
import {ERC1967Proxy} from "@openzeppelin/contracts/proxy/ERC1967/ERC1967Proxy.sol";
import {Adapter8004} from "../../src/Adapter8004.sol";
import {MockIdentityRegistry} from "../mocks/MockIdentityRegistry.sol";

/// R1 #20 checked the upgrade getter. This is slot 0 vs the immutable registry on a fresh proxy.
contract GrokR2_11_DeadSlot0 is Test {
    /// Success condition: reading slot 0 yields the identity registry, so a storage reader can
    /// confuse it with a mutable registry pointer the owner can swap.
    function test_defense_slot0IsDeadAndGetterIsTheImmutable() external {
        MockIdentityRegistry registry = new MockIdentityRegistry();
        Adapter8004 adapter = Adapter8004(
            address(
                new ERC1967Proxy(
                    address(new Adapter8004(address(registry))),
                    abi.encodeCall(Adapter8004.initialize, (makeAddr("admin")))
                )
            )
        );
        bytes32 slot0 = vm.load(address(adapter), bytes32(uint256(0)));
        assertEq(uint256(slot0), 0, "fresh proxy never wrote slot 0");
        assertEq(address(adapter.identityRegistry()), address(registry));
        assertTrue(address(uint160(uint256(slot0))) != address(registry));
    }
}
