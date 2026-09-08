// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Test} from "forge-std/Test.sol";
import {PrepareSepoliaUpgradeScript} from "../script/PrepareSepoliaUpgrade.s.sol";

contract PrepareSepoliaUpgradeTest is Test {
    function testRejectsWrongChain() external {
        PrepareSepoliaUpgradeScript script = new PrepareSepoliaUpgradeScript();
        vm.chainId(1);
        vm.expectRevert(bytes("Sepolia only"));
        script.run();
    }

    function testRejectsUndeployedImplementation() external {
        PrepareSepoliaUpgradeScript script = new PrepareSepoliaUpgradeScript();
        vm.chainId(11155111);
        vm.setEnv("ADAPTER_IMPLEMENTATION_ADDRESS", vm.toString(makeAddr("undeployed implementation")));
        vm.setEnv("EXPECTED_IMPLEMENTATION_CODEHASH", vm.toString(bytes32(uint256(1))));
        vm.expectRevert(bytes("implementation is not deployed"));
        script.run();
    }

    function testRejectsUnexpectedCodehash() external {
        PrepareSepoliaUpgradeScript script = new PrepareSepoliaUpgradeScript();
        vm.chainId(11155111);
        address implementation = makeAddr("unapproved implementation");
        vm.etch(implementation, hex"00");
        vm.setEnv("ADAPTER_IMPLEMENTATION_ADDRESS", vm.toString(implementation));
        vm.setEnv("EXPECTED_IMPLEMENTATION_CODEHASH", vm.toString(bytes32(uint256(1))));
        vm.expectRevert(bytes("implementation codehash mismatch"));
        script.run();
    }
}
