// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Test} from "forge-std/Test.sol";
import {ERC1967Proxy} from "@openzeppelin/contracts/proxy/ERC1967/ERC1967Proxy.sol";
import {IERC721} from "@openzeppelin/contracts/token/ERC721/IERC721.sol";

import {Adapter8004} from "../src/Adapter8004.sol";
import {IERCAgentBindings} from "../src/interfaces/IERCAgentBindings.sol";
import {MockIdentityRegistry} from "./mocks/MockIdentityRegistry.sol";

/// @dev Covers the `ACCOUNT` standard, which is the one standard that accepts an address with no
/// runtime code. The negatives here matter as much as the positives: relaxing the code test for
/// `ACCOUNT` must not relax it for the other seven standards, and must not relax either the zero
/// address or the registry-address rejection for any standard including `ACCOUNT`.
contract Adapter8004AccountTest is Test {
    Adapter8004 internal adapter;
    MockIdentityRegistry internal registry;

    address internal eoa = address(0xE0A);
    address internal admin = address(0xADD1);

    function setUp() external {
        registry = new MockIdentityRegistry();
        Adapter8004 implementation = new Adapter8004();
        ERC1967Proxy proxy = new ERC1967Proxy(
            address(implementation), abi.encodeCall(Adapter8004.initialize, (address(registry), admin))
        );
        adapter = Adapter8004(address(proxy));
    }

    // --- positives: a code-less address is a first-class principal under ACCOUNT ---

    function testAccountRegistersFromCodelessAddress() external {
        assertEq(eoa.code.length, 0, "fixture must have no code");

        vm.prank(eoa);
        uint256 agentId = adapter.register(IERCAgentBindings.TokenStandard.ACCOUNT, eoa, 0, "ipfs://agent");

        IERCAgentBindings.Binding memory binding = adapter.bindingOf(agentId);
        assertEq(uint8(binding.standard), uint8(IERCAgentBindings.TokenStandard.ACCOUNT), "standard");
        assertEq(binding.tokenContract, eoa, "bound address");
        assertEq(binding.tokenId, 0, "token id");
        assertTrue(adapter.isController(agentId, eoa), "the account controls its own identity");
    }

    function testAccountCounterfactualRegisterFromCodelessAddress() external {
        vm.prank(eoa);
        bytes32 registrationHash =
            adapter.counterfactualRegister(IERCAgentBindings.TokenStandard.ACCOUNT, eoa, 0, "ipfs://cf");
        assertEq(registrationHash, adapter.registrationHash(eoa, 0), "hash is standard-independent");
    }

    function testAccountBindExistingFromCodelessAddress() external {
        vm.prank(eoa);
        uint256 agentId = registry.register("ipfs://premint");
        vm.prank(eoa);
        IERC721(address(registry)).approve(address(adapter), agentId);

        vm.prank(eoa);
        adapter.bindExisting(agentId, IERCAgentBindings.TokenStandard.ACCOUNT, eoa, 0);

        assertEq(adapter.bindingOf(agentId).tokenContract, eoa, "bound address");
        assertEq(registry.ownerOf(agentId), address(adapter), "identity moved into the adapter");
    }

    /// @dev The motivating defect. Before this change the code test was the only gate, so whether an
    /// EOA could bind at all depended on whether a 7702 delegation happened to be installed at that
    /// moment: 23 bytes of designator cleared the guard, and an ordinary transaction from the same
    /// key cleared `account == boundAddress`. The exclusion was therefore accidental and unstable
    /// rather than a decision. Both shapes must now behave identically.
    function testDelegatedAndUndelegatedAccountsBehaveIdentically() external {
        address plain = address(0xA11);
        address delegated = address(0xA22);
        vm.etch(delegated, abi.encodePacked(hex"ef0100", address(0xBEEF)));
        assertEq(plain.code.length, 0, "undelegated EOA");
        assertEq(delegated.code.length, 23, "7702 delegation designator");

        vm.prank(plain);
        uint256 plainAgent = adapter.register(IERCAgentBindings.TokenStandard.ACCOUNT, plain, 0, "ipfs://a");
        vm.prank(delegated);
        uint256 delegatedAgent = adapter.register(IERCAgentBindings.TokenStandard.ACCOUNT, delegated, 0, "ipfs://b");

        assertTrue(adapter.isController(plainAgent, plain), "plain account controls");
        assertTrue(adapter.isController(delegatedAgent, delegated), "delegated account controls");
    }

    // --- negatives: everything else still rejects a code-less address ---

    function testEveryOtherStandardStillRejectsCodelessAddress() external {
        IERCAgentBindings.TokenStandard[7] memory standards = [
            IERCAgentBindings.TokenStandard.ERC721,
            IERCAgentBindings.TokenStandard.ERC1155,
            IERCAgentBindings.TokenStandard.ERC6909,
            IERCAgentBindings.TokenStandard.ERC1155F,
            IERCAgentBindings.TokenStandard.ERC6909F,
            IERCAgentBindings.TokenStandard.CONTRACT_OWNABLE,
            IERCAgentBindings.TokenStandard.CONTRACT_ADMIN
        ];

        for (uint256 i; i < standards.length; ++i) {
            vm.prank(eoa);
            vm.expectRevert(Adapter8004.InvalidTokenContract.selector);
            adapter.register(standards[i], eoa, 0, "ipfs://x");

            vm.prank(eoa);
            vm.expectRevert(Adapter8004.InvalidTokenContract.selector);
            adapter.counterfactualRegister(standards[i], eoa, 0, "ipfs://x");
        }
    }

    /// @dev `_bindings` uses a zero `tokenContract` as its unbound sentinel, so a zero binding would
    /// be indistinguishable from no binding. `ACCOUNT` waives the code test but must not waive this.
    function testAccountRejectsZeroAddress() external {
        vm.prank(eoa);
        vm.expectRevert(Adapter8004.InvalidTokenContract.selector);
        adapter.register(IERCAgentBindings.TokenStandard.ACCOUNT, address(0), 0, "ipfs://x");

        vm.prank(eoa);
        vm.expectRevert(Adapter8004.InvalidTokenContract.selector);
        adapter.counterfactualRegister(IERCAgentBindings.TokenStandard.ACCOUNT, address(0), 0, "ipfs://x");
    }

    function testAccountRejectsRegistryAddress() external {
        vm.prank(eoa);
        vm.expectRevert(Adapter8004.InvalidTokenContractIsRegistry.selector);
        adapter.register(IERCAgentBindings.TokenStandard.ACCOUNT, address(registry), 0, "ipfs://x");
    }

    function testAccountStillRequiresCanonicalTokenId() external {
        vm.prank(eoa);
        vm.expectRevert(abi.encodeWithSelector(Adapter8004.NonZeroTokenIdForAccount.selector, eoa, uint256(1)));
        adapter.register(IERCAgentBindings.TokenStandard.ACCOUNT, eoa, 1, "ipfs://x");
    }

    function testAccountAuthorityIsSelfOnly() external {
        vm.prank(eoa);
        uint256 agentId = adapter.register(IERCAgentBindings.TokenStandard.ACCOUNT, eoa, 0, "ipfs://agent");

        address stranger = address(0xBAD);
        assertFalse(adapter.isController(agentId, stranger), "a stranger has no authority");

        vm.prank(stranger);
        vm.expectRevert(abi.encodeWithSelector(Adapter8004.NotController.selector, stranger, agentId));
        adapter.setAgentURI(agentId, "ipfs://hijacked");
    }
}
