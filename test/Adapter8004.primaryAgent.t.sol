// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Test} from "forge-std/Test.sol";
import {ERC1967Proxy} from "@openzeppelin/contracts/proxy/ERC1967/ERC1967Proxy.sol";
import {Adapter8004} from "../src/Adapter8004.sol";
import {IERC8004AdapterPrimaryAgent} from "../src/interfaces/IERC8004AdapterPrimaryAgent.sol";
import {IERCAgentBindings} from "../src/interfaces/IERCAgentBindings.sol";
import {MockIdentityRegistry} from "./mocks/MockIdentityRegistry.sol";

/* ------------------------- helper account contracts ------------------------- */

/// @dev Account controlled through OpenZeppelin-style `owner()`.
contract OwnableAccount {
    address public owner;

    constructor(address owner_) {
        owner = owner_;
    }
}

/// @dev Account controlled through a `getOwner()` accessor (the fallback path).
contract GetOwnerAccount {
    address private _owner;

    constructor(address owner_) {
        _owner = owner_;
    }

    function getOwner() external view returns (address) {
        return _owner;
    }
}

/// @dev Account controlled through AccessControl `hasRole(DEFAULT_ADMIN_ROLE, ...)`.
contract AccessControlAccount {
    mapping(bytes32 => mapping(address => bool)) private _roles;

    function grant(bytes32 role, address who) external {
        _roles[role][who] = true;
    }

    function hasRole(bytes32 role, address who) external view returns (bool) {
        return _roles[role][who];
    }
}

/// @dev Account whose `owner()` returns an arbitrary address (models a contract lying about control).
contract SpoofOwnerAccount {
    address public owner;

    constructor(address fakeOwner) {
        owner = fakeOwner;
    }
}

/// @dev Account whose `owner()` always reverts (must be tolerated, not propagated).
contract RevertingOwnerAccount {
    function owner() external pure returns (address) {
        revert("nope");
    }
}

/// @dev Account whose `owner()` returns malformed (short) data (must be ignored).
contract GarbageOwnerAccount {
    function owner() external pure returns (bytes1) {
        return 0xAB;
    }
}

/* ---------------------------------- tests ---------------------------------- */

contract Adapter8004PrimaryAgentTest is Test {
    event PrimaryAgentSet(address indexed account, bytes32 indexed agentId, address indexed setBy);

    MockIdentityRegistry internal registry;
    Adapter8004 internal adapter;

    address internal alice = makeAddr("alice");
    address internal bob = makeAddr("bob");
    address internal eve = makeAddr("eve");
    address internal admin = makeAddr("admin");

    bytes32 internal constant SMALL_ID = bytes32(uint256(42)); // an ERC-8004 registry token id
    bytes32 internal constant HASH_ID = keccak256("counterfactual-registration-hash"); // a 32-byte cf id

    function setUp() external {
        registry = new MockIdentityRegistry();
        Adapter8004 implementation = new Adapter8004();
        ERC1967Proxy proxy = new ERC1967Proxy(
            address(implementation), abi.encodeCall(Adapter8004.initialize, (address(registry), admin))
        );
        adapter = Adapter8004(address(proxy));
    }

    /* ------------------------------ self path ------------------------------ */

    function testSelfSetAndRead() external {
        vm.prank(alice);
        adapter.setPrimaryAgent(SMALL_ID);
        assertEq(adapter.primaryAgentOf(alice), SMALL_ID);
    }

    function testSelfSetEmitsEvent() external {
        vm.expectEmit(true, true, true, true, address(adapter));
        emit PrimaryAgentSet(alice, HASH_ID, alice);
        vm.prank(alice);
        adapter.setPrimaryAgent(HASH_ID);
    }

    function testSelfClearWithZero() external {
        vm.startPrank(alice);
        adapter.setPrimaryAgent(SMALL_ID);
        vm.expectEmit(true, true, true, true, address(adapter));
        emit PrimaryAgentSet(alice, bytes32(0), alice);
        adapter.setPrimaryAgent(bytes32(0));
        vm.stopPrank();
        assertEq(adapter.primaryAgentOf(alice), bytes32(0));
    }

    function testOverwriteUpdatesValue() external {
        vm.startPrank(alice);
        adapter.setPrimaryAgent(SMALL_ID);
        adapter.setPrimaryAgent(HASH_ID);
        vm.stopPrank();
        assertEq(adapter.primaryAgentOf(alice), HASH_ID);
    }

    function testUnsetReturnsZero() external view {
        assertEq(adapter.primaryAgentOf(bob), bytes32(0));
    }

    /// The whole point: ERC-8004 ids (small) and counterfactual hashes (32B) coexist without colliding.
    function testErc8004IdAndHashIdCoexist() external {
        vm.prank(alice);
        adapter.setPrimaryAgent(SMALL_ID);
        vm.prank(bob);
        adapter.setPrimaryAgent(HASH_ID);
        assertEq(adapter.primaryAgentOf(alice), SMALL_ID);
        assertEq(adapter.primaryAgentOf(bob), HASH_ID);
        assertTrue(adapter.primaryAgentOf(alice) != adapter.primaryAgentOf(bob));
    }

    /// A live counterfactual `registrationHash` is a valid primary-agent id.
    function testLiveRegistrationHashAsPrimaryAgent() external {
        bytes32 h = adapter.registrationHash(address(0xBEEF), 7);
        vm.prank(alice);
        adapter.setPrimaryAgent(h);
        assertEq(adapter.primaryAgentOf(alice), h);
    }

    /* --------------------------- setPrimaryAgentFor -------------------------- */

    function testForSelf() external {
        vm.prank(alice);
        adapter.setPrimaryAgentFor(alice, SMALL_ID);
        assertEq(adapter.primaryAgentOf(alice), SMALL_ID);
    }

    function testForByOwner() external {
        OwnableAccount account = new OwnableAccount(alice);
        vm.prank(alice);
        adapter.setPrimaryAgentFor(address(account), HASH_ID);
        assertEq(adapter.primaryAgentOf(address(account)), HASH_ID);
    }

    function testForByGetOwner() external {
        GetOwnerAccount account = new GetOwnerAccount(alice);
        vm.prank(alice);
        adapter.setPrimaryAgentFor(address(account), HASH_ID);
        assertEq(adapter.primaryAgentOf(address(account)), HASH_ID);
    }

    function testForByAccessControlAdmin() external {
        AccessControlAccount account = new AccessControlAccount();
        account.grant(bytes32(0), alice); // DEFAULT_ADMIN_ROLE
        vm.prank(alice);
        adapter.setPrimaryAgentFor(address(account), SMALL_ID);
        assertEq(adapter.primaryAgentOf(address(account)), SMALL_ID);
    }

    function testForByOwnerCanClear() external {
        OwnableAccount account = new OwnableAccount(alice);
        vm.startPrank(alice);
        adapter.setPrimaryAgentFor(address(account), HASH_ID);
        adapter.setPrimaryAgentFor(address(account), bytes32(0));
        vm.stopPrank();
        assertEq(adapter.primaryAgentOf(address(account)), bytes32(0));
    }

    function testForEmitsSetByOwner() external {
        OwnableAccount account = new OwnableAccount(alice);
        vm.expectEmit(true, true, true, true, address(adapter));
        emit PrimaryAgentSet(address(account), HASH_ID, alice);
        vm.prank(alice);
        adapter.setPrimaryAgentFor(address(account), HASH_ID);
    }

    /* ---------------------------- auth failures ---------------------------- */

    function testForRevertsForNonControllerEOA() external {
        // bob is an EOA: no owner()/hasRole, so only bob can set bob.
        vm.expectRevert(abi.encodeWithSelector(Adapter8004.NotAccountController.selector, bob, alice));
        vm.prank(alice);
        adapter.setPrimaryAgentFor(bob, SMALL_ID);
    }

    function testForRevertsForNonOwner() external {
        OwnableAccount account = new OwnableAccount(alice);
        vm.expectRevert(abi.encodeWithSelector(Adapter8004.NotAccountController.selector, address(account), eve));
        vm.prank(eve);
        adapter.setPrimaryAgentFor(address(account), SMALL_ID);
    }

    function testForRevertsForNonAdmin() external {
        AccessControlAccount account = new AccessControlAccount();
        account.grant(bytes32(0), alice);
        vm.expectRevert(abi.encodeWithSelector(Adapter8004.NotAccountController.selector, address(account), eve));
        vm.prank(eve);
        adapter.setPrimaryAgentFor(address(account), SMALL_ID);
    }

    /* ----------------------- robustness of the control check ---------------- */

    function testToleratesRevertingOwner() external {
        RevertingOwnerAccount account = new RevertingOwnerAccount();
        // owner() reverts -> treated as no control -> a non-self caller reverts NotAccountController.
        vm.expectRevert(abi.encodeWithSelector(Adapter8004.NotAccountController.selector, address(account), eve));
        vm.prank(eve);
        adapter.setPrimaryAgentFor(address(account), SMALL_ID);
    }

    function testToleratesGarbageOwnerReturn() external {
        GarbageOwnerAccount account = new GarbageOwnerAccount();
        // owner() returns <32 bytes -> ignored -> non-self caller reverts.
        vm.expectRevert(abi.encodeWithSelector(Adapter8004.NotAccountController.selector, address(account), eve));
        vm.prank(eve);
        adapter.setPrimaryAgentFor(address(account), SMALL_ID);
    }

    /// A contract that lies about its owner can only grant control over ITS OWN mapping entry.
    function testSpoofedOwnerIsAccountScoped() external {
        SpoofOwnerAccount malicious = new SpoofOwnerAccount(eve); // claims eve is its owner
        OwnableAccount honest = new OwnableAccount(alice);

        // eve can set the malicious account's entry (the account consented by lying).
        vm.prank(eve);
        adapter.setPrimaryAgentFor(address(malicious), HASH_ID);
        assertEq(adapter.primaryAgentOf(address(malicious)), HASH_ID);

        // ...but that grants eve nothing over an honest account.
        vm.expectRevert(abi.encodeWithSelector(Adapter8004.NotAccountController.selector, address(honest), eve));
        vm.prank(eve);
        adapter.setPrimaryAgentFor(address(honest), HASH_ID);
    }

    /* --------------------------- no side effects --------------------------- */

    function testNoBindingOrRegistrySideEffects() external {
        vm.prank(alice);
        adapter.setPrimaryAgent(SMALL_ID); // SMALL_ID == 42
        // The primary-agent mapping is independent of adapter bindings and the ERC-8004 registry:
        // storing id 42 does NOT create a binding for agent 42.
        vm.expectRevert(abi.encodeWithSelector(Adapter8004.UnknownAgent.selector, uint256(42)));
        adapter.bindingOf(42);
    }
}
