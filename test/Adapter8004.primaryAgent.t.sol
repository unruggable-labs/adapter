// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Test} from "forge-std/Test.sol";
import {Vm} from "forge-std/Vm.sol";
import {ERC1967Proxy} from "@openzeppelin/contracts/proxy/ERC1967/ERC1967Proxy.sol";
import {Adapter8004} from "../src/Adapter8004.sol";
import {IERC8217} from "../src/interfaces/IERC8217.sol";
import {IERC8004AdapterCounterfactual} from "../src/interfaces/IERC8004AdapterCounterfactual.sol";
import {MockIdentityRegistry} from "./mocks/MockIdentityRegistry.sol";
import {MockERC721} from "./mocks/MockERC721.sol";

contract Adapter8004ZeroHashHarness is Adapter8004 {
    constructor(address registry_) Adapter8004(registry_) {}

    function _bindingHash(IERC8217.Standard, address, uint256) internal pure override returns (bytes32) {
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
    event WalletUBIDSet(
        address indexed account,
        bytes32 indexed ubid,
        address boundAddress,
        uint256 tokenId,
        IERC8217.Standard standard,
        address indexed setBy
    );
    event WalletUBIDCleared(address indexed account, address indexed clearedBy);

    Adapter8004 internal adapter;
    address internal alice = makeAddr("alice");
    address internal bob = makeAddr("bob");
    /// @dev A real deployed collection rather than a bare placeholder address. The wallet
    /// counterfactual id setters validate their coordinates, so a code-less address under a
    /// code-requiring standard is rejected, exactly as the claim paths reject it.
    address internal token;
    IERC8217.Standard internal constant STD = IERC8217.Standard.ERC721;

    function setUp() external {
        MockIdentityRegistry registry = new MockIdentityRegistry();
        Adapter8004 implementation = new Adapter8004(address(registry));
        adapter = Adapter8004(
            address(new ERC1967Proxy(address(implementation), abi.encodeCall(Adapter8004.initialize, (address(this)))))
        );
        token = address(new MockERC721());
    }

    /// @dev The designation is emit-only, so a set and a clear are both recorded and neither writes
    /// anything. There is no sentinel to distinguish a real value from an unwritten slot, because
    /// there is no slot; the projection rule does that work instead.
    function testSetAndClearAreRecordedAndStoreNothing() external {
        vm.record();
        vm.recordLogs();

        vm.prank(alice);
        bytes32 designated = adapter.setWalletUBID(STD, token, 7);
        vm.prank(alice);
        adapter.clearWalletUBID();

        (, bytes32[] memory writes) = vm.accesses(address(adapter));
        assertEq(writes.length, 0, "the wallet UBID surface writes no storage at all");

        Vm.Log[] memory logs = vm.getRecordedLogs();
        assertEq(logs.length, 2, "both calls are recorded");
        assertEq(logs[0].topics[0], IERC8004AdapterCounterfactual.WalletUBIDSet.selector);
        assertEq(logs[0].topics[2], designated, "the set names the derived identity");
        assertEq(logs[1].topics[0], IERC8004AdapterCounterfactual.WalletUBIDCleared.selector);
    }

    function testEventsCarryTypedValuesAndCoordinates() external {
        bytes32 hash = adapter.hashBinding(STD, token, 7);
        vm.expectEmit(true, true, true, true, address(adapter));
        emit WalletUBIDSet(alice, hash, token, 7, STD, alice);
        vm.prank(alice);
        adapter.setWalletUBID(STD, token, 7);
    }

    /// @dev The setters name an identity, and the standard is part of that identity. Pointing at the
    /// same `(boundAddress, tokenId)` under a different standard must move the pointer to a different
    /// hash rather than resolve to the same one, or an account could not distinguish which of two
    /// claimants' identities it had named.
    function testCounterfactualPrimaryIsPerStandard() external {
        vm.prank(alice);
        bytes32 asToken = adapter.setWalletUBID(STD, token, 0);
        vm.prank(alice);
        bytes32 asAccount = adapter.setWalletUBID(IERC8217.Standard.ACCOUNT, token, 0);

        assertTrue(asToken != asAccount, "one pair under two standards must be two identities");
        assertEq(asAccount, adapter.hashBinding(IERC8217.Standard.ACCOUNT, token, 0));
    }

    function testCounterfactualHashZeroIsRepresentable() external {
        MockIdentityRegistry registry = new MockIdentityRegistry();
        Adapter8004ZeroHashHarness implementation = new Adapter8004ZeroHashHarness(address(registry));
        Adapter8004ZeroHashHarness zeroAdapter = Adapter8004ZeroHashHarness(
            address(new ERC1967Proxy(address(implementation), abi.encodeCall(Adapter8004.initialize, (address(this)))))
        );
        vm.recordLogs();
        vm.prank(alice);
        assertEq(zeroAdapter.setWalletUBID(STD, token, 1), bytes32(0));

        // A zero identity is carried like any other. It needed a complement encoding when the value
        // was stored; emit-only removes that concern entirely rather than special-casing it.
        Vm.Log[] memory logs = vm.getRecordedLogs();
        assertEq(logs[0].topics[2], bytes32(0), "a zero identity is emitted as itself");
    }

    /// @dev The designation is recorded for the named account, not the caller, so the event has to
    /// carry the account rather than whoever was authorized to act for it.
    function testOwnerAndDefaultAdminControlTheForSurface() external {
        PrimaryOwnableAccount owned = new PrimaryOwnableAccount(alice);
        vm.expectEmit(true, true, true, true, address(adapter));
        emit WalletUBIDSet(address(owned), adapter.hashBinding(STD, token, 1), token, 1, STD, alice);
        vm.prank(alice);
        assertEq(adapter.setWalletUBIDFor(address(owned), STD, token, 1), adapter.hashBinding(STD, token, 1));

        PrimaryAccessControlAccount access = new PrimaryAccessControlAccount();
        access.grant(bob);
        vm.expectEmit(true, true, true, true, address(adapter));
        emit WalletUBIDSet(address(access), adapter.hashBinding(STD, token, 2), token, 2, STD, bob);
        vm.prank(bob);
        assertEq(adapter.setWalletUBIDFor(address(access), STD, token, 2), adapter.hashBinding(STD, token, 2));
    }

    /// @dev A clear from a different authorized party than the one that set is honoured, because
    /// both functions authorize against the account rather than against whoever wrote last. The
    /// projection rule says so and this is the on-chain half of it.
    function testAnyAuthorizedPartyMayClearWhatAnotherSet() external {
        PrimaryAccessControlAccount access = new PrimaryAccessControlAccount();
        access.grant(alice);
        access.grant(bob);

        vm.prank(alice);
        adapter.setWalletUBIDFor(address(access), STD, token, 1);

        vm.expectEmit(true, true, true, true, address(adapter));
        emit WalletUBIDCleared(address(access), bob);
        vm.prank(bob);
        adapter.clearWalletUBIDFor(address(access));
    }

    function testNonControllerRejectedOnTheForSurface() external {
        PrimaryOwnableAccount owned = new PrimaryOwnableAccount(alice);
        vm.expectRevert(abi.encodeWithSelector(Adapter8004.NotAccountController.selector, address(owned), bob));
        vm.prank(bob);
        adapter.setWalletUBIDFor(address(owned), STD, token, 1);
    }

    /// @dev Clearing an account that never set one is a recorded no-op, not a revert, so an indexer
    /// sees the same event either way.
    function testIdempotentClearStillEmits() external {
        vm.expectEmit(true, true, true, true, address(adapter));
        emit WalletUBIDCleared(alice, alice);
        vm.prank(alice);
        adapter.clearWalletUBID();
    }
}
