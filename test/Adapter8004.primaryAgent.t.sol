// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Test} from "forge-std/Test.sol";
import {ERC1967Proxy} from "@openzeppelin/contracts/proxy/ERC1967/ERC1967Proxy.sol";
import {Adapter8004} from "../src/Adapter8004.sol";
import {IERCAgentBindings} from "../src/interfaces/IERCAgentBindings.sol";
import {MockIdentityRegistry} from "./mocks/MockIdentityRegistry.sol";

contract Adapter8004ZeroHashHarness is Adapter8004 {
    function _registrationHash(IERCAgentBindings.TokenStandard, address, uint256)
        internal
        pure
        override
        returns (bytes32)
    {
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
    event WalletAgentIDSet(address indexed account, uint256 indexed agentId, address indexed setBy);
    event WalletAgentIDCleared(address indexed account, address indexed clearedBy);
    event WalletCounterfactualIDSet(
        address indexed account,
        bytes32 indexed registrationHash,
        address boundAddress,
        uint256 tokenId,
        IERCAgentBindings.TokenStandard standard,
        address indexed setBy
    );
    event WalletCounterfactualIDCleared(address indexed account, address indexed clearedBy);

    Adapter8004 internal adapter;
    address internal alice = makeAddr("alice");
    address internal bob = makeAddr("bob");
    address internal token = address(0xBEEF);
    IERCAgentBindings.TokenStandard internal constant STD = IERCAgentBindings.TokenStandard.ERC721;

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
        assertEq(adapter.walletAgentIDOf(alice), type(uint256).max);
        assertEq(adapter.walletCounterfactualIDOf(alice), bytes32(type(uint256).max));
        vm.prank(alice);
        adapter.setWalletAgentID(0);
        assertEq(adapter.walletAgentIDOf(alice), 0);
        assertEq(adapter.walletCounterfactualIDOf(alice), bytes32(type(uint256).max));
    }

    function testAccountCanHoldBothPrimariesAndEachWriteIsIndependent() external {
        bytes32 expected = adapter.registrationHash(STD, token, 7);
        vm.prank(alice);
        adapter.setWalletAgentID(42);
        vm.prank(alice);
        bytes32 actual = adapter.setWalletCounterfactualID(STD, token, 7);
        assertEq(actual, expected);
        assertEq(adapter.walletAgentIDOf(alice), 42);
        assertEq(adapter.walletCounterfactualIDOf(alice), expected);

        vm.prank(alice);
        adapter.clearWalletAgentID();
        assertEq(adapter.walletAgentIDOf(alice), type(uint256).max);
        assertEq(adapter.walletCounterfactualIDOf(alice), expected);

        vm.prank(alice);
        adapter.clearWalletCounterfactualID();
        assertEq(adapter.walletCounterfactualIDOf(alice), bytes32(type(uint256).max));
    }

    function testFullAndCounterfactualSameBitsRemainIndependent() external {
        bytes32 hash = adapter.registrationHash(STD, token, 9);
        vm.prank(alice);
        adapter.setWalletAgentID(uint256(hash));
        vm.prank(alice);
        adapter.setWalletCounterfactualID(STD, token, 9);
        assertEq(adapter.walletAgentIDOf(alice), uint256(hash));
        assertEq(adapter.walletCounterfactualIDOf(alice), hash);
    }

    function testEventsCarryTypedValuesAndCoordinates() external {
        vm.expectEmit(true, true, true, true, address(adapter));
        emit WalletAgentIDSet(alice, 42, alice);
        vm.prank(alice);
        adapter.setWalletAgentID(42);

        bytes32 hash = adapter.registrationHash(STD, token, 7);
        vm.expectEmit(true, true, true, true, address(adapter));
        emit WalletCounterfactualIDSet(alice, hash, token, 7, STD, alice);
        vm.prank(alice);
        adapter.setWalletCounterfactualID(STD, token, 7);
    }

    /// @dev The setters name an identity, and the standard is part of that identity. Pointing at the
    /// same `(boundAddress, tokenId)` under a different standard must move the pointer to a different
    /// hash rather than resolve to the same one, or an account could not distinguish which of two
    /// claimants' identities it had named.
    function testCounterfactualPrimaryIsPerStandard() external {
        vm.prank(alice);
        bytes32 asToken = adapter.setWalletCounterfactualID(STD, token, 0);
        vm.prank(alice);
        bytes32 asAccount = adapter.setWalletCounterfactualID(IERCAgentBindings.TokenStandard.ACCOUNT, token, 0);

        assertTrue(asToken != asAccount, "one pair under two standards must be two pointers");
        assertEq(adapter.walletCounterfactualIDOf(alice), asAccount, "latest write wins");
        assertEq(asAccount, adapter.registrationHash(IERCAgentBindings.TokenStandard.ACCOUNT, token, 0));
    }

    function testReservedFullSentinelRevertsWithoutChangingCounterfactual() external {
        vm.prank(alice);
        adapter.setWalletCounterfactualID(STD, token, 7);
        bytes32 beforeValue = adapter.walletCounterfactualIDOf(alice);
        vm.expectRevert(abi.encodeWithSelector(Adapter8004.WalletAgentIDReserved.selector, type(uint256).max));
        vm.prank(alice);
        adapter.setWalletAgentID(type(uint256).max);
        assertEq(adapter.walletCounterfactualIDOf(alice), beforeValue);
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
        assertEq(zeroAdapter.setWalletCounterfactualID(STD, token, 1), bytes32(0));
        assertEq(zeroAdapter.walletCounterfactualIDOf(alice), bytes32(0));
    }

    function testOwnerAndDefaultAdminControlBothForSurfaces() external {
        PrimaryOwnableAccount owned = new PrimaryOwnableAccount(alice);
        vm.startPrank(alice);
        adapter.setWalletAgentIDFor(address(owned), 5);
        adapter.setWalletCounterfactualIDFor(address(owned), STD, token, 1);
        vm.stopPrank();
        assertEq(adapter.walletAgentIDOf(address(owned)), 5);
        assertEq(adapter.walletCounterfactualIDOf(address(owned)), adapter.registrationHash(STD, token, 1));

        PrimaryAccessControlAccount access = new PrimaryAccessControlAccount();
        access.grant(bob);
        vm.startPrank(bob);
        adapter.setWalletAgentIDFor(address(access), 6);
        adapter.setWalletCounterfactualIDFor(address(access), STD, token, 2);
        vm.stopPrank();
        assertEq(adapter.walletAgentIDOf(address(access)), 6);
    }

    function testNonControllerRejectedOnBothForSurfaces() external {
        PrimaryOwnableAccount owned = new PrimaryOwnableAccount(alice);
        vm.expectRevert(abi.encodeWithSelector(Adapter8004.NotAccountController.selector, address(owned), bob));
        vm.prank(bob);
        adapter.setWalletAgentIDFor(address(owned), 1);

        vm.expectRevert(abi.encodeWithSelector(Adapter8004.NotAccountController.selector, address(owned), bob));
        vm.prank(bob);
        adapter.setWalletCounterfactualIDFor(address(owned), STD, token, 1);
    }

    function testIdempotentClearsDoNotCrossClobber() external {
        vm.expectEmit(true, true, true, true, address(adapter));
        emit WalletAgentIDCleared(alice, alice);
        vm.prank(alice);
        adapter.clearWalletAgentID();
        vm.expectEmit(true, true, true, true, address(adapter));
        emit WalletCounterfactualIDCleared(alice, alice);
        vm.prank(alice);
        adapter.clearWalletCounterfactualID();
    }
}
