// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Test} from "forge-std/Test.sol";
import {ERC1967Proxy} from "@openzeppelin/contracts/proxy/ERC1967/ERC1967Proxy.sol";
import {Initializable} from "@openzeppelin/contracts-upgradeable/proxy/utils/Initializable.sol";
import {AdapterImplementation} from "../../src/AdapterImplementation.sol";
import {MockIdentityRegistry} from "../mocks/MockIdentityRegistry.sol";

contract NextImpl is AdapterImplementation {
    constructor(address registry_) AdapterImplementation(registry_) {}
}

/// R1 #20 was RegistryMismatch spoof. This is upgrade-and-reinitialize owner seizure.
contract GrokR2_10_UpgradeReinit is Test {
    /// Success condition: upgradeToAndCall(initialize(attacker)) replaces the owner.
    function test_defense_upgradeCannotReinitializeAndStealOwner() external {
        MockIdentityRegistry registry = new MockIdentityRegistry();
        address admin = makeAddr("admin");
        address attacker = makeAddr("attacker");
        AdapterImplementation adapter = AdapterImplementation(
            address(
                new ERC1967Proxy(
                    address(new AdapterImplementation(address(registry))),
                    abi.encodeCall(AdapterImplementation.initialize, (admin))
                )
            )
        );
        NextImpl next = new NextImpl(address(registry));

        vm.prank(admin);
        vm.expectRevert(Initializable.InvalidInitialization.selector);
        adapter.upgradeToAndCall(address(next), abi.encodeCall(AdapterImplementation.initialize, (attacker)));

        assertEq(adapter.owner(), admin);
        assertEq(address(adapter.identityRegistry()), address(registry));
    }
}
