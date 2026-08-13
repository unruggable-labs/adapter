// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Test} from "forge-std/Test.sol";
import {ERC1967Proxy} from "@openzeppelin/contracts/proxy/ERC1967/ERC1967Proxy.sol";
import {Adapter8004} from "../src/Adapter8004.sol";
import {IERCAgentBindings} from "../src/interfaces/IERCAgentBindings.sol";
import {MockIdentityRegistry} from "./mocks/MockIdentityRegistry.sol";
import {MockDelegateRegistry} from "./mocks/MockDelegateRegistry.sol";

contract OwnableBinder {
    Adapter8004 internal immutable ADAPTER;
    address internal currentOwner;

    constructor(Adapter8004 adapter, address initialOwner) {
        ADAPTER = adapter;
        currentOwner = initialOwner;
    }

    function owner() external view virtual returns (address) {
        return currentOwner;
    }

    function transferOwnership(address newOwner) external {
        currentOwner = newOwner;
    }

    function registerOwnable() external returns (uint256) {
        return ADAPTER.register(IERCAgentBindings.TokenStandard.CONTRACT_OWNABLE, address(this), 0, "ipfs://ownable");
    }
}

/// @notice `owner()` reverts, so the contract reports no usable owner.
contract NoOwnerBinder is OwnableBinder {
    constructor(Adapter8004 adapter) OwnableBinder(adapter, address(0)) {}

    function owner() external pure override returns (address) {
        revert("no owner");
    }
}

/// @notice Covers the delegation route added to `CONTRACT_OWNABLE`, which makes it the fourth member
/// of the owner-and-delegate pattern alongside the three single-owner token standards.
contract Adapter8004OwnableDelegateTest is Test {
    Adapter8004 internal adapter;
    MockDelegateRegistry internal delegateRegistry;

    address internal alice = makeAddr("alice");
    address internal hot = makeAddr("hot");
    address internal bob = makeAddr("bob");
    address internal stranger = makeAddr("stranger");

    bytes32 internal constant OTHER_RIGHTS = keccak256("some.other.right");

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

        MockDelegateRegistry mockImpl = new MockDelegateRegistry();
        vm.etch(adapter.DELEGATE_REGISTRY(), address(mockImpl).code);
        delegateRegistry = MockDelegateRegistry(adapter.DELEGATE_REGISTRY());
    }

    function _bind(address ownerAddress) internal returns (OwnableBinder binder, uint256 agentId) {
        binder = new OwnableBinder(adapter, ownerAddress);
        agentId = binder.registerOwnable();
    }

    function testOwnerDelegateIsAuthorized() external {
        (OwnableBinder binder, uint256 agentId) = _bind(alice);
        assertFalse(adapter.isController(agentId, hot), "no delegation yet");

        delegateRegistry.delegateContract(hot, alice, address(binder), adapter.DELEGATE_RIGHTS(), true);

        assertTrue(adapter.isController(agentId, hot), "delegate of the current owner controls");
        assertTrue(adapter.isController(agentId, alice), "the owner still controls");
        assertTrue(adapter.isController(agentId, address(binder)), "the contract still controls");
    }

    /// @dev The owner is resolved on every call, so authority follows ownership rather than the
    /// delegation that was granted under it.
    function testFormerOwnerDelegationStopsWorkingAfterTransfer() external {
        (OwnableBinder binder, uint256 agentId) = _bind(alice);
        delegateRegistry.delegateContract(hot, alice, address(binder), adapter.DELEGATE_RIGHTS(), true);
        assertTrue(adapter.isController(agentId, hot));

        binder.transferOwnership(bob);

        assertFalse(adapter.isController(agentId, hot), "alice's delegate must lose authority");
        assertFalse(adapter.isController(agentId, alice), "alice must lose authority");
        assertTrue(adapter.isController(agentId, bob), "bob is the owner now");
    }

    /// @dev A contract reporting no usable owner must grant nobody, and must never send the zero
    /// address to the registry as a delegator.
    function testZeroOwnerGrantsNobodyEvenWithBlanketDelegation() external {
        NoOwnerBinder binder = new NoOwnerBinder(adapter);
        uint256 agentId = binder.registerOwnable();

        delegateRegistry.delegateAll(hot, address(0), bytes32(0), true);

        assertFalse(adapter.isController(agentId, hot), "no owner means no delegate");
        assertFalse(adapter.isController(agentId, address(0)), "the zero address is not an owner");
        assertTrue(adapter.isController(agentId, address(binder)), "contract-self authority is unaffected");
    }

    function testDelegationScopedToAnotherRightConfersNothing() external {
        (OwnableBinder binder, uint256 agentId) = _bind(alice);

        delegateRegistry.delegateContract(hot, alice, address(binder), OTHER_RIGHTS, true);

        assertFalse(adapter.isController(agentId, hot), "a different named right must not confer authority");
    }

    /// @dev A token-scoped delegation must not carry a contract binding. The binding pins `tokenId` to
    /// 0, where it is only an input to the counterfactual hash, so for a bound contract that is also
    /// an NFT collection a delegation covering token 0 would otherwise reach the whole contract.
    function testTokenScopedDelegationDoesNotConferContractAuthority() external {
        (OwnableBinder binder, uint256 agentId) = _bind(alice);

        delegateRegistry.delegateERC721(hot, alice, address(binder), 0, adapter.DELEGATE_RIGHTS(), true);

        assertFalse(adapter.isController(agentId, hot), "token-scoped delegation must not reach the contract");
    }

    /// @dev The direct paths are ordered ahead of the delegation check, so neither the contract nor
    /// the owner reaches the registry. Removing the registry's code proves it: a call that needed it
    /// would fail closed and return false.
    function testDirectAuthorityDoesNotConsultTheRegistry() external {
        (OwnableBinder binder, uint256 agentId) = _bind(alice);

        vm.etch(adapter.DELEGATE_REGISTRY(), "");

        assertTrue(adapter.isController(agentId, address(binder)), "contract-self needs no registry");
        assertTrue(adapter.isController(agentId, alice), "the owner needs no registry");
        assertFalse(adapter.isController(agentId, hot), "delegation fails closed without a registry");
    }
}
