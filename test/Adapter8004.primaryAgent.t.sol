// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Test} from "forge-std/Test.sol";
import {ERC1967Proxy} from "@openzeppelin/contracts/proxy/ERC1967/ERC1967Proxy.sol";
import {Adapter8004} from "../src/Adapter8004.sol";
import {IERCAgentBindings} from "../src/interfaces/IERCAgentBindings.sol";
import {MockIdentityRegistry} from "./mocks/MockIdentityRegistry.sol";
import {MockERC721} from "./mocks/MockERC721.sol";

contract Adapter8004ZeroHashHarness is Adapter8004 {
    constructor(address registry_) Adapter8004(registry_) {}

    function _ubi(IERCAgentBindings.TokenStandard, address, uint256) internal pure override returns (bytes32) {
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
    event WalletUBISet(
        address indexed account,
        bytes32 indexed ubi,
        address boundAddress,
        uint256 tokenId,
        IERCAgentBindings.TokenStandard standard,
        address indexed setBy
    );
    event WalletUBICleared(address indexed account, address indexed clearedBy);

    Adapter8004 internal adapter;
    address internal alice = makeAddr("alice");
    address internal bob = makeAddr("bob");
    /// @dev A real deployed collection rather than a bare placeholder address. The wallet
    /// counterfactual id setters validate their coordinates, so a code-less address under a
    /// code-requiring standard is rejected, exactly as the claim paths reject it.
    address internal token;
    IERCAgentBindings.TokenStandard internal constant STD = IERCAgentBindings.TokenStandard.ERC721;

    function setUp() external {
        MockIdentityRegistry registry = new MockIdentityRegistry();
        Adapter8004 implementation = new Adapter8004(address(registry));
        adapter = Adapter8004(
            address(new ERC1967Proxy(address(implementation), abi.encodeCall(Adapter8004.initialize, (address(this)))))
        );
        token = address(new MockERC721());
    }

    function testIndependentUnsetSentinelsAndZeroFullId() external {
        assertEq(adapter.walletAgentIDOf(alice), type(uint256).max);
        assertEq(adapter.walletUBIOf(alice), bytes32(type(uint256).max));
        vm.prank(alice);
        adapter.setWalletAgentID(0);
        assertEq(adapter.walletAgentIDOf(alice), 0);
        assertEq(adapter.walletUBIOf(alice), bytes32(type(uint256).max));
    }

    function testAccountCanHoldBothPrimariesAndEachWriteIsIndependent() external {
        bytes32 expected = adapter.ubiFor(STD, token, 7);
        vm.prank(alice);
        adapter.setWalletAgentID(42);
        vm.prank(alice);
        bytes32 actual = adapter.setWalletUBI(STD, token, 7);
        assertEq(actual, expected);
        assertEq(adapter.walletAgentIDOf(alice), 42);
        assertEq(adapter.walletUBIOf(alice), expected);

        vm.prank(alice);
        adapter.clearWalletAgentID();
        assertEq(adapter.walletAgentIDOf(alice), type(uint256).max);
        assertEq(adapter.walletUBIOf(alice), expected);

        vm.prank(alice);
        adapter.clearWalletUBI();
        assertEq(adapter.walletUBIOf(alice), bytes32(type(uint256).max));
    }

    function testFullAndCounterfactualSameBitsRemainIndependent() external {
        bytes32 hash = adapter.ubiFor(STD, token, 9);
        vm.prank(alice);
        adapter.setWalletAgentID(uint256(hash));
        vm.prank(alice);
        adapter.setWalletUBI(STD, token, 9);
        assertEq(adapter.walletAgentIDOf(alice), uint256(hash));
        assertEq(adapter.walletUBIOf(alice), hash);
    }

    function testEventsCarryTypedValuesAndCoordinates() external {
        vm.expectEmit(true, true, true, true, address(adapter));
        emit WalletAgentIDSet(alice, 42, alice);
        vm.prank(alice);
        adapter.setWalletAgentID(42);

        bytes32 hash = adapter.ubiFor(STD, token, 7);
        vm.expectEmit(true, true, true, true, address(adapter));
        emit WalletUBISet(alice, hash, token, 7, STD, alice);
        vm.prank(alice);
        adapter.setWalletUBI(STD, token, 7);
    }

    /// @dev The setters name an identity, and the standard is part of that identity. Pointing at the
    /// same `(boundAddress, tokenId)` under a different standard must move the pointer to a different
    /// hash rather than resolve to the same one, or an account could not distinguish which of two
    /// claimants' identities it had named.
    function testCounterfactualPrimaryIsPerStandard() external {
        vm.prank(alice);
        bytes32 asToken = adapter.setWalletUBI(STD, token, 0);
        vm.prank(alice);
        bytes32 asAccount = adapter.setWalletUBI(IERCAgentBindings.TokenStandard.ACCOUNT, token, 0);

        assertTrue(asToken != asAccount, "one pair under two standards must be two pointers");
        assertEq(adapter.walletUBIOf(alice), asAccount, "latest write wins");
        assertEq(asAccount, adapter.ubiFor(IERCAgentBindings.TokenStandard.ACCOUNT, token, 0));
    }

    function testReservedFullSentinelRevertsWithoutChangingCounterfactual() external {
        vm.prank(alice);
        adapter.setWalletUBI(STD, token, 7);
        bytes32 beforeValue = adapter.walletUBIOf(alice);
        vm.expectRevert(abi.encodeWithSelector(Adapter8004.WalletAgentIDReserved.selector, type(uint256).max));
        vm.prank(alice);
        adapter.setWalletAgentID(type(uint256).max);
        assertEq(adapter.walletUBIOf(alice), beforeValue);
    }

    function testCounterfactualHashZeroIsRepresentable() external {
        MockIdentityRegistry registry = new MockIdentityRegistry();
        Adapter8004ZeroHashHarness implementation = new Adapter8004ZeroHashHarness(address(registry));
        Adapter8004ZeroHashHarness zeroAdapter = Adapter8004ZeroHashHarness(
            address(new ERC1967Proxy(address(implementation), abi.encodeCall(Adapter8004.initialize, (address(this)))))
        );
        vm.prank(alice);
        assertEq(zeroAdapter.setWalletUBI(STD, token, 1), bytes32(0));
        assertEq(zeroAdapter.walletUBIOf(alice), bytes32(0));
    }

    function testOwnerAndDefaultAdminControlBothForSurfaces() external {
        PrimaryOwnableAccount owned = new PrimaryOwnableAccount(alice);
        vm.startPrank(alice);
        adapter.setWalletAgentIDFor(address(owned), 5);
        adapter.setWalletUBIFor(address(owned), STD, token, 1);
        vm.stopPrank();
        assertEq(adapter.walletAgentIDOf(address(owned)), 5);
        assertEq(adapter.walletUBIOf(address(owned)), adapter.ubiFor(STD, token, 1));

        PrimaryAccessControlAccount access = new PrimaryAccessControlAccount();
        access.grant(bob);
        vm.startPrank(bob);
        adapter.setWalletAgentIDFor(address(access), 6);
        adapter.setWalletUBIFor(address(access), STD, token, 2);
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
        adapter.setWalletUBIFor(address(owned), STD, token, 1);
    }

    function testIdempotentClearsDoNotCrossClobber() external {
        vm.expectEmit(true, true, true, true, address(adapter));
        emit WalletAgentIDCleared(alice, alice);
        vm.prank(alice);
        adapter.clearWalletAgentID();
        vm.expectEmit(true, true, true, true, address(adapter));
        emit WalletUBICleared(alice, alice);
        vm.prank(alice);
        adapter.clearWalletUBI();
    }
}
