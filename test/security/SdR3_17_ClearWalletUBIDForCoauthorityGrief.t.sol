// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Test} from "forge-std/Test.sol";
import {ERC1967Proxy} from "@openzeppelin/contracts/proxy/ERC1967/ERC1967Proxy.sol";

import {AdapterImplementation} from "../../src/AdapterImplementation.sol";
import {IERC8217} from "../../src/interfaces/IERC8217.sol";
import {MockIdentityRegistry} from "../mocks/MockIdentityRegistry.sol";

contract SimpleOwnable17 {
    address public owner;

    constructor(address o) {
        owner = o;
    }
}

/// SdR3 #17 regression — only a wallet's own call can clear its designation.
/// Owners and strangers both fail when calling the removed acting-for selector.
contract SdR3_17_ClearWalletUBIDForCoauthorityGrief is Test {
    event WalletUBIDCleared(address indexed account, address indexed clearedBy);

    MockIdentityRegistry internal registry;
    AdapterImplementation internal adapter;
    SimpleOwnable17 internal account;

    address internal admin = makeAddr("admin");
    address internal coAuthority = makeAddr("coAuthority");
    address internal stranger = makeAddr("stranger");

    function setUp() external {
        registry = new MockIdentityRegistry();
        AdapterImplementation impl = new AdapterImplementation(address(registry));
        ERC1967Proxy proxy = new ERC1967Proxy(address(impl), abi.encodeCall(AdapterImplementation.initialize, (admin)));
        adapter = AdapterImplementation(address(proxy));
        account = new SimpleOwnable17(coAuthority);
    }

    function test_ownerCannotClearAccountsOwnDesignation() external {
        vm.prank(address(account));
        adapter.setWalletUBID(IERC8217.Standard.ACCOUNT, address(account), 0);

        vm.prank(coAuthority);
        (bool ownerOk,) =
            address(adapter).call(abi.encodeWithSignature("clearWalletUBIDFor(address)", address(account)));
        assertFalse(ownerOk);

        // Control: a stranger cannot.
        vm.prank(stranger);
        (bool strangerOk,) =
            address(adapter).call(abi.encodeWithSignature("clearWalletUBIDFor(address)", address(account)));
        assertFalse(strangerOk);

        vm.expectEmit(true, true, false, false, address(adapter));
        emit WalletUBIDCleared(address(account), address(account));
        vm.prank(address(account));
        adapter.clearWalletUBID();
    }
}
