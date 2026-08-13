// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Test} from "forge-std/Test.sol";
import {ERC1967Proxy} from "@openzeppelin/contracts/proxy/ERC1967/ERC1967Proxy.sol";
import {Adapter8004} from "../src/Adapter8004.sol";
import {IERCAgentBindings} from "../src/interfaces/IERCAgentBindings.sol";
import {MockIdentityRegistry} from "./mocks/MockIdentityRegistry.sol";

/// @notice An AccessControl-style contract with no `owner()`, which is the case this standard exists
/// for. It could otherwise only bind as plain `CONTRACT`.
contract AdminBinder {
    Adapter8004 internal immutable ADAPTER;
    mapping(address => bool) internal admins;

    constructor(Adapter8004 adapter, address initialAdmin) {
        ADAPTER = adapter;
        admins[initialAdmin] = true;
    }

    function setAdmin(address account, bool enabled) external {
        admins[account] = enabled;
    }

    function hasRole(bytes32 role, address account) external view virtual returns (bool) {
        return role == bytes32(0) && admins[account];
    }

    function registerAdminBound() external returns (uint256) {
        return ADAPTER.register(IERCAgentBindings.TokenStandard.CONTRACT_ADMIN, address(this), 0, "ipfs://admin");
    }

    function registerWithTokenId(uint256 tokenId) external returns (uint256) {
        return ADAPTER.register(IERCAgentBindings.TokenStandard.CONTRACT_ADMIN, address(this), tokenId, "ipfs://x");
    }
}

/// @notice Implements no `hasRole` at all, so the probe must fail closed rather than revert.
contract NoRoleBinder {
    Adapter8004 internal immutable ADAPTER;

    constructor(Adapter8004 adapter) {
        ADAPTER = adapter;
    }

    function registerAdminBound() external returns (uint256) {
        return ADAPTER.register(IERCAgentBindings.TokenStandard.CONTRACT_ADMIN, address(this), 0, "ipfs://norole");
    }
}

/// @notice Returns a word outside 0 and 1 for a `bool` return, which would revert a plain
/// `abi.decode(ret, (bool))`. The raw-word decode exists so this fails or passes cleanly instead.
contract DirtyRoleBinder {
    Adapter8004 internal immutable ADAPTER;

    constructor(Adapter8004 adapter) {
        ADAPTER = adapter;
    }

    fallback(bytes calldata) external returns (bytes memory) {
        return abi.encode(uint256(42));
    }

    function registerAdminBound() external returns (uint256) {
        return ADAPTER.register(IERCAgentBindings.TokenStandard.CONTRACT_ADMIN, address(this), 0, "ipfs://dirty");
    }
}

contract Adapter8004ContractAdminTest is Test {
    Adapter8004 internal adapter;

    address internal admin = makeAddr("admin");
    address internal stranger = makeAddr("stranger");

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

    function testAdminBindsAndManages() external {
        AdminBinder binder = new AdminBinder(adapter, admin);
        uint256 agentId = binder.registerAdminBound();

        assertTrue(adapter.isController(agentId, admin), "the admin controls the bound identity");

        vm.prank(admin);
        adapter.setAgentURI(agentId, "ipfs://updated");
        assertEq(adapter.tokenURI(agentId), "ipfs://updated", "the admin can write");
    }

    function testNonAdminIsDenied() external {
        AdminBinder binder = new AdminBinder(adapter, admin);
        uint256 agentId = binder.registerAdminBound();

        assertFalse(adapter.isController(agentId, stranger));
        vm.prank(stranger);
        vm.expectRevert(abi.encodeWithSelector(Adapter8004.NotController.selector, stranger, agentId));
        adapter.setAgentURI(agentId, "ipfs://evil");
    }

    function testBoundContractRetainsAuthority() external {
        AdminBinder binder = new AdminBinder(adapter, admin);
        uint256 agentId = binder.registerAdminBound();

        assertTrue(adapter.isController(agentId, address(binder)), "contract-self authority is kept");
    }

    /// @dev A contract with no `hasRole` must grant nobody, and must not revert while deciding that.
    function testContractWithoutHasRoleFailsClosed() external {
        NoRoleBinder binder = new NoRoleBinder(adapter);
        uint256 agentId = binder.registerAdminBound();

        assertFalse(adapter.isController(agentId, admin), "no role support means no admin");
        assertFalse(adapter.isController(agentId, stranger));
        assertTrue(adapter.isController(agentId, address(binder)), "contract-self still works");
    }

    /// @dev The raw-word decode is what makes this a decision rather than a revert. Any non-zero word
    /// counts as holding the role.
    function testDirtyBooleanReturnIsHandled() external {
        DirtyRoleBinder binder = new DirtyRoleBinder(adapter);
        uint256 agentId = binder.registerAdminBound();

        assertTrue(adapter.isController(agentId, stranger), "a non-zero word counts as holding the role");
    }

    /// @dev The role is read on every call, so it is not captured at bind time.
    function testRevokingTheRoleRemovesAuthorityOnTheNextCall() external {
        AdminBinder binder = new AdminBinder(adapter, admin);
        uint256 agentId = binder.registerAdminBound();
        assertTrue(adapter.isController(agentId, admin));

        binder.setAdmin(admin, false);

        assertFalse(adapter.isController(agentId, admin), "revocation takes effect immediately");
    }

    function testNonZeroTokenIdRevertsOnRegister() external {
        AdminBinder binder = new AdminBinder(adapter, admin);

        vm.expectRevert(abi.encodeWithSelector(Adapter8004.NonZeroTokenIdForContract.selector, address(binder), 1));
        binder.registerWithTokenId(1);
    }

    /// @dev The second choke point. A counterfactual emit resolves authority through
    /// `_requireBindingControl`, so the canonical id is enforced there too.
    function testNonZeroTokenIdRevertsOnCounterfactualPath() external {
        AdminBinder binder = new AdminBinder(adapter, admin);

        vm.prank(admin);
        vm.expectRevert(abi.encodeWithSelector(Adapter8004.NonZeroTokenIdForContract.selector, address(binder), 3));
        adapter.counterfactualRegister(IERCAgentBindings.TokenStandard.CONTRACT_ADMIN, address(binder), 3, "ipfs://x");
    }

    /// @dev This standard has no delegate.xyz route, so it is not a member of the owner-and-delegate
    /// pattern. A blanket delegation from the admin confers nothing here.
    function testNoDelegationRouteExists() external {
        AdminBinder binder = new AdminBinder(adapter, admin);
        uint256 agentId = binder.registerAdminBound();
        address hot = makeAddr("hot");

        assertFalse(adapter.isController(agentId, hot), "delegation is not consulted for CONTRACT_ADMIN");
    }
}
