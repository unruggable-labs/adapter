// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Test} from "forge-std/Test.sol";
import {ERC1967Proxy} from "@openzeppelin/contracts/proxy/ERC1967/ERC1967Proxy.sol";
import {AdapterImplementation} from "../src/AdapterImplementation.sol";
import {IERC8217} from "../src/interfaces/IERC8217.sol";
import {MockIdentityRegistry} from "./mocks/MockIdentityRegistry.sol";

/// @notice An AccessControl-style contract with no `owner()`, which is the case this standard exists
/// for. It could otherwise only bind as plain `ACCOUNT`.
contract AdminBinder {
    AdapterImplementation internal immutable ADAPTER;
    mapping(address => bool) internal admins;

    constructor(AdapterImplementation adapter, address initialAdmin) {
        ADAPTER = adapter;
        admins[initialAdmin] = true;
    }

    function setAdmin(address account, bool enabled) external {
        admins[account] = enabled;
    }

    function hasRole(bytes32 role, address account) external view virtual returns (bool) {
        return role == bytes32(0) && admins[account];
    }
}

/// @notice Implements no `hasRole` at all, so the probe must fail closed rather than revert.
contract NoRoleBinder {
    AdapterImplementation internal immutable ADAPTER;

    constructor(AdapterImplementation adapter) {
        ADAPTER = adapter;
    }
}

/// @notice Returns a word outside 0 and 1 for a `bool` return, which would revert a plain
/// `abi.decode(ret, (bool))`. The probe must deny authority without a decoding revert.
contract DirtyRoleBinder {
    AdapterImplementation internal immutable ADAPTER;

    constructor(AdapterImplementation adapter) {
        ADAPTER = adapter;
    }

    fallback(bytes calldata) external returns (bytes memory) {
        return abi.encode(uint256(42));
    }
}

contract Adapter8004ContractAdminTest is Test {
    AdapterImplementation internal adapter;

    address internal admin = makeAddr("admin");
    address internal stranger = makeAddr("stranger");

    /// @dev An admin registers, not the contract. Contract-self authority was removed, so a bound
    /// contract can no longer create its own binding either.
    function _bindAs(address caller, address boundAddress) internal returns (uint256) {
        vm.prank(caller);
        return adapter.register(IERC8217.Standard.CONTRACT_ADMIN, boundAddress, 0, "ipfs://admin");
    }

    function setUp() external {
        MockIdentityRegistry registry = new MockIdentityRegistry();
        AdapterImplementation implementation = new AdapterImplementation(address(registry));
        adapter = AdapterImplementation(
            address(
                new ERC1967Proxy(
                    address(implementation), abi.encodeCall(AdapterImplementation.initialize, (address(this)))
                )
            )
        );
    }

    function testAdminBindsAndManages() external {
        AdminBinder binder = new AdminBinder(adapter, admin);
        uint256 agentId = _bindAs(admin, address(binder));

        assertTrue(adapter.isController(agentId, admin), "the admin controls the bound identity");

        vm.prank(admin);
        adapter.setAgentURI(agentId, "ipfs://updated");
        assertEq(adapter.tokenURI(agentId), "ipfs://updated", "the admin can write");
    }

    function testNonAdminIsDenied() external {
        AdminBinder binder = new AdminBinder(adapter, admin);
        uint256 agentId = _bindAs(admin, address(binder));

        assertFalse(adapter.isController(agentId, stranger));
        vm.prank(stranger);
        vm.expectRevert(abi.encodeWithSelector(AdapterImplementation.NotController.selector, stranger, agentId));
        adapter.setAgentURI(agentId, "ipfs://evil");
    }

    /// @dev The bound contract is rejected on both the authority read and the write path. Authority
    /// belongs to the role holders alone.
    function testBoundContractIsRejected() external {
        AdminBinder binder = new AdminBinder(adapter, admin);
        uint256 agentId = _bindAs(admin, address(binder));

        assertFalse(adapter.isController(agentId, address(binder)));

        vm.prank(address(binder));
        vm.expectRevert(abi.encodeWithSelector(AdapterImplementation.NotController.selector, address(binder), agentId));
        adapter.setAgentURI(agentId, "ipfs://self");
    }

    /// @dev A contract with no `hasRole` grants nobody, and must fail closed rather than revert.
    /// Since nobody holds the role there is also nobody who can create the binding, so the probe is
    /// observed through the registration attempt itself.
    function testContractWithoutHasRoleCannotBeBound() external {
        NoRoleBinder binder = new NoRoleBinder(adapter);

        vm.prank(admin);
        vm.expectRevert(abi.encodeWithSelector(AdapterImplementation.NotController.selector, admin, type(uint256).max));
        adapter.register(IERC8217.Standard.CONTRACT_ADMIN, address(binder), 0, "ipfs://norole");

        vm.prank(address(binder));
        vm.expectRevert(
            abi.encodeWithSelector(AdapterImplementation.NotController.selector, address(binder), type(uint256).max)
        );
        adapter.register(IERC8217.Standard.CONTRACT_ADMIN, address(binder), 0, "ipfs://norole");
    }

    function testDirtyBooleanReturnCannotAuthorizeRegistration() external {
        DirtyRoleBinder binder = new DirtyRoleBinder(adapter);

        vm.prank(stranger);
        vm.expectRevert(
            abi.encodeWithSelector(AdapterImplementation.NotController.selector, stranger, type(uint256).max)
        );
        adapter.register(IERC8217.Standard.CONTRACT_ADMIN, address(binder), 0, "ipfs://dirty");
    }

    function _assertAdminDenied(address binder, uint256 agentId) internal {
        assertFalse(adapter.isController(agentId, admin), "invalid response must deny without a decoding revert");

        vm.prank(admin);
        vm.expectRevert(abi.encodeWithSelector(AdapterImplementation.NotController.selector, admin, agentId));
        adapter.setAgentURI(agentId, "ipfs://denied");

        vm.prank(admin);
        vm.expectRevert(abi.encodeWithSelector(AdapterImplementation.NotController.selector, admin, type(uint256).max));
        adapter.counterfactualRegister(IERC8217.Standard.CONTRACT_ADMIN, binder, 0, "ipfs://denied");

        vm.prank(admin);
        vm.expectRevert(abi.encodeWithSelector(AdapterImplementation.NotController.selector, admin, type(uint256).max));
        adapter.register(IERC8217.Standard.CONTRACT_ADMIN, binder, 0, "ipfs://denied");
    }

    function testFuzzRoleResponseOnlyAcceptsCanonicalTrue(uint256 word) external {
        AdminBinder binder = new AdminBinder(adapter, admin);
        uint256 agentId = _bindAs(admin, address(binder));
        vm.mockCall(address(binder), abi.encodeCall(binder.hasRole, (bytes32(0), admin)), abi.encode(word));

        if (word == 1) {
            assertTrue(adapter.isController(agentId, admin));
            vm.prank(admin);
            adapter.setAgentURI(agentId, "ipfs://canonical");
            assertEq(adapter.tokenURI(agentId), "ipfs://canonical");
        } else {
            _assertAdminDenied(address(binder), agentId);
        }
    }

    function testMalformedBooleanWordsDenyExistingAdmin() external {
        AdminBinder binder = new AdminBinder(adapter, admin);
        uint256 agentId = _bindAs(admin, address(binder));
        uint256[5] memory words = [uint256(0), 2, 42, 256, type(uint256).max];
        for (uint256 i; i < words.length; ++i) {
            vm.mockCall(address(binder), abi.encodeCall(binder.hasRole, (bytes32(0), admin)), abi.encode(words[i]));
            _assertAdminDenied(address(binder), agentId);
        }
    }

    function testFuzzWrongLengthRoleResponseIsDenied(uint8 responseLength) external {
        vm.assume(responseLength != 32);
        AdminBinder binder = new AdminBinder(adapter, admin);
        uint256 agentId = _bindAs(admin, address(binder));
        bytes memory response = new bytes(responseLength);
        // Even a canonical true followed by trailing bytes is not an exact boolean response.
        if (responseLength > 32) response[31] = 0x01;
        vm.mockCall(address(binder), abi.encodeCall(binder.hasRole, (bytes32(0), admin)), response);

        _assertAdminDenied(address(binder), agentId);
    }

    function testRevertingRoleProbeDeniesExistingAdmin() external {
        AdminBinder binder = new AdminBinder(adapter, admin);
        uint256 agentId = _bindAs(admin, address(binder));
        // A failed call must be rejected even when its revert data looks like canonical true.
        vm.mockCallRevert(address(binder), abi.encodeCall(binder.hasRole, (bytes32(0), admin)), abi.encode(uint256(1)));

        _assertAdminDenied(address(binder), agentId);
    }

    /// @dev The role is read on every call, so it is not captured at bind time.
    function testRevokingTheRoleRemovesAuthorityOnTheNextCall() external {
        AdminBinder binder = new AdminBinder(adapter, admin);
        uint256 agentId = _bindAs(admin, address(binder));
        assertTrue(adapter.isController(agentId, admin));

        binder.setAdmin(admin, false);

        assertFalse(adapter.isController(agentId, admin), "revocation takes effect immediately");
    }

    function testNonZeroTokenIdRevertsOnRegister() external {
        AdminBinder binder = new AdminBinder(adapter, admin);

        vm.prank(admin);
        vm.expectRevert(
            abi.encodeWithSelector(AdapterImplementation.NonZeroTokenIdForAccount.selector, address(binder), 1)
        );
        adapter.register(IERC8217.Standard.CONTRACT_ADMIN, address(binder), 1, "ipfs://x");
    }

    /// @dev The second choke point. A counterfactual emit resolves authority through
    /// `_requireBindingControl`, so the canonical id is enforced there too.
    function testNonZeroTokenIdRevertsOnCounterfactualPath() external {
        AdminBinder binder = new AdminBinder(adapter, admin);

        vm.prank(admin);
        vm.expectRevert(
            abi.encodeWithSelector(AdapterImplementation.NonZeroTokenIdForAccount.selector, address(binder), 3)
        );
        adapter.counterfactualRegister(IERC8217.Standard.CONTRACT_ADMIN, address(binder), 3, "ipfs://x");
    }

    /// @dev This standard has no delegate.xyz route, so it is not a member of the owner-and-delegate
    /// pattern. A blanket delegation from the admin confers nothing here.
    function testNoDelegationRouteExists() external {
        AdminBinder binder = new AdminBinder(adapter, admin);
        uint256 agentId = _bindAs(admin, address(binder));
        address hot = makeAddr("hot");

        assertFalse(adapter.isController(agentId, hot), "delegation is not consulted for CONTRACT_ADMIN");
    }
}
