// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Test} from "forge-std/Test.sol";
import {ERC1967Proxy} from "@openzeppelin/contracts/proxy/ERC1967/ERC1967Proxy.sol";

import {AdapterImplementation} from "../../src/AdapterImplementation.sol";
import {MockIdentityRegistry} from "../mocks/MockIdentityRegistry.sol";

/// SdR3 #14 — UpgradeToCodelessImpl. `_authorizeUpgrade` calls
/// `AdapterImplementation(newImplementation).identityRegistry()` (:670) on the incoming implementation. A
/// codeless target makes that high-level call revert, so the upgrade cannot land. NOT one of the
/// prior 40: R1 #20 used a live impl with a lying getter; R2 #10/#11 covered reinit and dead slot 0.
/// None points the guard at a non-contract. Defended: the malformed upgrade reverts.
contract SdR3_14_UpgradeToCodelessImpl is Test {
    MockIdentityRegistry internal registry;
    AdapterImplementation internal adapter;

    address internal admin = makeAddr("admin");

    function setUp() external {
        registry = new MockIdentityRegistry();
        AdapterImplementation impl = new AdapterImplementation(address(registry));
        ERC1967Proxy proxy = new ERC1967Proxy(address(impl), abi.encodeCall(AdapterImplementation.initialize, (admin)));
        adapter = AdapterImplementation(address(proxy));
    }

    /// Success condition (defense): upgrading to a codeless address reverts; the proxy is unchanged.
    function test_upgradeToCodelessAddressReverts() external {
        address codeless = makeAddr("codeless");
        assertEq(codeless.code.length, 0, "target has no code");

        vm.prank(admin);
        vm.expectRevert();
        adapter.upgradeToAndCall(codeless, "");

        assertEq(address(adapter.identityRegistry()), address(registry), "registry unchanged after failed upgrade");
    }
}
