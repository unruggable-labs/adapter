// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Test} from "forge-std/Test.sol";
import {ERC1967Proxy} from "@openzeppelin/contracts/proxy/ERC1967/ERC1967Proxy.sol";
import {Adapter8004} from "../src/Adapter8004.sol";
import {MockIdentityRegistry} from "./mocks/MockIdentityRegistry.sol";

contract Adapter8004ZeroHashHarness is Adapter8004 {
    function _registrationHash(address, uint256) internal pure override returns (bytes32) {
        return bytes32(0);
    }
}

contract PrimaryOwnableAccount {
    address public owner;

    constructor(address owner_) {
        owner = owner_;
    }
}

contract PrimaryAccessControlAccount {
    mapping(address => bool) internal admins;

    function grant(address account) external {
        admins[account] = true;
    }

    function hasRole(bytes32, address account) external view returns (bool) {
        return admins[account];
    }
}

contract Adapter8004PrimaryAgentTest is Test {
    event PrimaryAgentSet(address indexed account, uint256 indexed agentId, address indexed setBy);
    event PrimaryAgentCleared(address indexed account, address indexed clearedBy);
    event PrimaryCounterfactualAgentSet(
        address indexed account,
        bytes32 indexed registrationHash,
        address tokenContract,
        uint256 tokenId,
        address indexed setBy
    );
    event PrimaryCounterfactualAgentCleared(address indexed account, address indexed clearedBy);

    Adapter8004 internal adapter;
    address internal alice = makeAddr("alice");
    address internal bob = makeAddr("bob");
    address internal token = address(0xBEEF);

    function setUp() external {
        MockIdentityRegistry registry = new MockIdentityRegistry();
        Adapter8004 implementation = new Adapter8004();
        adapter = Adapter8004(
            address(
                new ERC1967Proxy(
                    address(implementation), abi.encodeCall(Adapter8004.initialize, (address(registry), address(this)))
                )
            )
        );
    }

    function testIndependentUnsetSentinelsAndZeroFullId() external {
        assertEq(adapter.primaryAgentOf(alice), type(uint256).max);
        assertEq(adapter.primaryCounterfactualAgentOf(alice), bytes32(type(uint256).max));
        vm.prank(alice);
        adapter.setPrimaryAgent(0);
        assertEq(adapter.primaryAgentOf(alice), 0);
        assertEq(adapter.primaryCounterfactualAgentOf(alice), bytes32(type(uint256).max));
    }

    function testAccountCanHoldBothPrimariesAndEachWriteIsIndependent() external {
        bytes32 expected = adapter.registrationHash(token, 7);
        vm.prank(alice);
        adapter.setPrimaryAgent(42);
        vm.prank(alice);
        bytes32 actual = adapter.setPrimaryCounterfactualAgent(token, 7);
        assertEq(actual, expected);
        assertEq(adapter.primaryAgentOf(alice), 42);
        assertEq(adapter.primaryCounterfactualAgentOf(alice), expected);

        vm.prank(alice);
        adapter.clearPrimaryAgent();
        assertEq(adapter.primaryAgentOf(alice), type(uint256).max);
        assertEq(adapter.primaryCounterfactualAgentOf(alice), expected);

        vm.prank(alice);
        adapter.clearPrimaryCounterfactualAgent();
        assertEq(adapter.primaryCounterfactualAgentOf(alice), bytes32(type(uint256).max));
    }

    function testFullAndCounterfactualSameBitsRemainIndependent() external {
        bytes32 hash = adapter.registrationHash(token, 9);
        vm.prank(alice);
        adapter.setPrimaryAgent(uint256(hash));
        vm.prank(alice);
        adapter.setPrimaryCounterfactualAgent(token, 9);
        assertEq(adapter.primaryAgentOf(alice), uint256(hash));
        assertEq(adapter.primaryCounterfactualAgentOf(alice), hash);
    }

    function testEventsCarryTypedValuesAndCoordinates() external {
        vm.expectEmit(true, true, true, true, address(adapter));
        emit PrimaryAgentSet(alice, 42, alice);
        vm.prank(alice);
        adapter.setPrimaryAgent(42);

        bytes32 hash = adapter.registrationHash(token, 7);
        vm.expectEmit(true, true, true, true, address(adapter));
        emit PrimaryCounterfactualAgentSet(alice, hash, token, 7, alice);
        vm.prank(alice);
        adapter.setPrimaryCounterfactualAgent(token, 7);
    }

    function testReservedFullSentinelRevertsWithoutChangingCounterfactual() external {
        vm.prank(alice);
        adapter.setPrimaryCounterfactualAgent(token, 7);
        bytes32 beforeValue = adapter.primaryCounterfactualAgentOf(alice);
        vm.expectRevert(abi.encodeWithSelector(Adapter8004.PrimaryAgentIdReserved.selector, type(uint256).max));
        vm.prank(alice);
        adapter.setPrimaryAgent(type(uint256).max);
        assertEq(adapter.primaryCounterfactualAgentOf(alice), beforeValue);
    }

    function testCounterfactualHashZeroIsRepresentable() external {
        MockIdentityRegistry registry = new MockIdentityRegistry();
        Adapter8004ZeroHashHarness implementation = new Adapter8004ZeroHashHarness();
        Adapter8004ZeroHashHarness zeroAdapter = Adapter8004ZeroHashHarness(
            address(
                new ERC1967Proxy(
                    address(implementation), abi.encodeCall(Adapter8004.initialize, (address(registry), address(this)))
                )
            )
        );
        vm.prank(alice);
        assertEq(zeroAdapter.setPrimaryCounterfactualAgent(token, 1), bytes32(0));
        assertEq(zeroAdapter.primaryCounterfactualAgentOf(alice), bytes32(0));
    }

    function testOwnerAndDefaultAdminControlBothForSurfaces() external {
        PrimaryOwnableAccount owned = new PrimaryOwnableAccount(alice);
        vm.startPrank(alice);
        adapter.setPrimaryAgentFor(address(owned), 5);
        adapter.setPrimaryCounterfactualAgentFor(address(owned), token, 1);
        vm.stopPrank();
        assertEq(adapter.primaryAgentOf(address(owned)), 5);
        assertEq(adapter.primaryCounterfactualAgentOf(address(owned)), adapter.registrationHash(token, 1));

        PrimaryAccessControlAccount access = new PrimaryAccessControlAccount();
        access.grant(bob);
        vm.startPrank(bob);
        adapter.setPrimaryAgentFor(address(access), 6);
        adapter.setPrimaryCounterfactualAgentFor(address(access), token, 2);
        vm.stopPrank();
        assertEq(adapter.primaryAgentOf(address(access)), 6);
    }

    function testNonControllerRejectedOnBothForSurfaces() external {
        PrimaryOwnableAccount owned = new PrimaryOwnableAccount(alice);
        vm.expectRevert(abi.encodeWithSelector(Adapter8004.NotAccountController.selector, address(owned), bob));
        vm.prank(bob);
        adapter.setPrimaryAgentFor(address(owned), 1);

        vm.expectRevert(abi.encodeWithSelector(Adapter8004.NotAccountController.selector, address(owned), bob));
        vm.prank(bob);
        adapter.setPrimaryCounterfactualAgentFor(address(owned), token, 1);
    }

    function testIdempotentClearsDoNotCrossClobber() external {
        vm.expectEmit(true, true, true, true, address(adapter));
        emit PrimaryAgentCleared(alice, alice);
        vm.prank(alice);
        adapter.clearPrimaryAgent();
        vm.expectEmit(true, true, true, true, address(adapter));
        emit PrimaryCounterfactualAgentCleared(alice, alice);
        vm.prank(alice);
        adapter.clearPrimaryCounterfactualAgent();
    }
}
