// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Test} from "forge-std/Test.sol";
import {ERC1967Proxy} from "@openzeppelin/contracts/proxy/ERC1967/ERC1967Proxy.sol";
import {Initializable} from "@openzeppelin/contracts-upgradeable/proxy/utils/Initializable.sol";
import {Adapter8004} from "../../src/Adapter8004.sol";
import {MockIdentityRegistry} from "../mocks/MockIdentityRegistry.sol";

contract NextImpl is Adapter8004 {
    constructor(address registry_) Adapter8004(registry_) {}
}

/// R1 #20 was RegistryMismatch spoof. This is upgrade-and-reinitialize owner seizure.
contract GrokR2_10_UpgradeReinit is Test {
    /// Success condition: upgradeToAndCall(initialize(attacker)) replaces the owner.
    function test_defense_upgradeCannotReinitializeAndStealOwner() external {
        MockIdentityRegistry registry = new MockIdentityRegistry();
        address admin = makeAddr("admin");
        address attacker = makeAddr("attacker");
        Adapter8004 adapter = Adapter8004(
            address(
                new ERC1967Proxy(
                    address(new Adapter8004(address(registry))), abi.encodeCall(Adapter8004.initialize, (admin))
                )
            )
        );
        NextImpl next = new NextImpl(address(registry));

        vm.prank(admin);
        vm.expectRevert(Initializable.InvalidInitialization.selector);
        adapter.upgradeToAndCall(address(next), abi.encodeCall(Adapter8004.initialize, (attacker)));

        assertEq(adapter.owner(), admin);
        assertEq(address(adapter.identityRegistry()), address(registry));
    }
}
