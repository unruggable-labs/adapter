// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Test} from "forge-std/Test.sol";
import {PrepareChainUpgradeScript} from "../script/PrepareChainUpgrade.s.sol";

contract PrepareChainUpgradeTest is Test {
    function testRejectsUnsupportedChain() external {
        PrepareChainUpgradeScript generator = new PrepareChainUpgradeScript();
        vm.chainId(4663);
        vm.expectRevert(bytes("unsupported chain"));
        generator.prepare(address(123), bytes32(0));
    }

    function testRejectsUndeployedOnBothChains() external {
        PrepareChainUpgradeScript generator = new PrepareChainUpgradeScript();
        vm.chainId(8453);
        vm.expectRevert(bytes("implementation is not deployed"));
        generator.prepare(address(123), bytes32(0));
        vm.chainId(1);
        vm.expectRevert(bytes("implementation is not deployed"));
        generator.prepare(address(123), bytes32(0));
    }

    function testRejectsUnapprovedRuntime() external {
        PrepareChainUpgradeScript generator = new PrepareChainUpgradeScript();
        vm.chainId(8453);
        vm.expectRevert(bytes("implementation codehash mismatch"));
        generator.prepare(address(generator), bytes32(0));
    }

    function testRejectsRuntimeEvenWithSelfReportedHash() external {
        PrepareChainUpgradeScript generator = new PrepareChainUpgradeScript();
        vm.chainId(8453);
        vm.expectRevert(bytes("runtime differs from local build"));
        generator.prepare(address(generator), address(generator).codehash);
    }
}
