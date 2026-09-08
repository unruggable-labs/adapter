// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Test} from "forge-std/Test.sol";
import {Vm} from "forge-std/Vm.sol";
import {ERC1967Proxy} from "@openzeppelin/contracts/proxy/ERC1967/ERC1967Proxy.sol";
import {AdapterImplementation} from "../src/AdapterImplementation.sol";
import {IERC8217} from "../src/interfaces/IERC8217.sol";
import {IERC8004IdentityRegistry} from "../src/interfaces/IERC8004IdentityRegistry.sol";
import {MockIdentityRegistry} from "./mocks/MockIdentityRegistry.sol";
import {MockERC721} from "./mocks/MockERC721.sol";
import {MockContractBinder} from "./mocks/MockContractBinder.sol";

/// @notice Every counterfactual function that derives an identity returns it.
///
/// Each test pins the returned hash against two independent things: the published derivation
/// `ubid` exposes, and the identity that function's own event carries. Checking it
/// against only one of those would leave the return value able to agree with itself and nothing
/// else, which is the failure this file exists to rule out.
contract Adapter8004CounterfactualReturnsTest is Test {
    AdapterImplementation internal adapter;
    MockERC721 internal token;

    address internal alice = makeAddr("alice");
    address internal wallet = makeAddr("wallet");
    address internal admin = makeAddr("admin");

    IERC8217.Standard internal constant STD = IERC8217.Standard.ERC721;

    function setUp() external {
        MockIdentityRegistry registry = new MockIdentityRegistry();
        adapter = AdapterImplementation(
            address(
                new ERC1967Proxy(
                    address(new AdapterImplementation(address(registry))),
                    abi.encodeCall(AdapterImplementation.initialize, (admin))
                )
            )
        );
        token = new MockERC721();
        token.mint(alice, 1);
    }

    function testSetAgentURIReturnsTheDerivedHash() external {
        vm.recordLogs();
        vm.prank(alice);
        bytes32 returned = adapter.counterfactualSetAgentURI(STD, address(token), 1, "ipfs://updated");
        _assertPinned(returned);
    }

    function testSetMetadataReturnsTheDerivedHash() external {
        vm.recordLogs();
        vm.prank(alice);
        bytes32 returned = adapter.counterfactualSetMetadata(STD, address(token), 1, "role", bytes("builder"));
        _assertPinned(returned);
    }

    /// @dev The batch writes several keys against one identity, so one hash covers the whole call.
    /// Asserted with more than one entry, so a per-entry reading of the return would show up here.
    function testSetMetadataBatchReturnsTheOneDerivedHash() external {
        IERC8004IdentityRegistry.MetadataEntry[] memory metadata = new IERC8004IdentityRegistry.MetadataEntry[](3);
        metadata[0] = IERC8004IdentityRegistry.MetadataEntry({metadataKey: "a", metadataValue: bytes("1")});
        metadata[1] = IERC8004IdentityRegistry.MetadataEntry({metadataKey: "b", metadataValue: bytes("2")});
        metadata[2] = IERC8004IdentityRegistry.MetadataEntry({metadataKey: "c", metadataValue: bytes("3")});

        vm.recordLogs();
        vm.prank(alice);
        bytes32 returned = adapter.counterfactualSetMetadataBatch(STD, address(token), 1, metadata);

        Vm.Log[] memory logs = vm.getRecordedLogs();
        assertEq(logs.length, 1, "one event for the whole batch");
        _assertPinnedAgainst(returned, logs);
    }

    function testSetAgentWalletReturnsTheDerivedHash() external {
        vm.recordLogs();
        vm.prank(alice);
        bytes32 returned = adapter.counterfactualSetAgentWallet(STD, address(token), 1, wallet);
        _assertPinned(returned);
    }

    function testUnsetAgentWalletReturnsTheDerivedHash() external {
        vm.recordLogs();
        vm.prank(alice);
        bytes32 returned = adapter.counterfactualUnsetAgentWallet(STD, address(token), 1);
        _assertPinned(returned);
    }

    /// @dev The whole surface now answers with the same value for the same coordinates, which is the
    /// property that made the five worth changing. `counterfactualRegister` and the two wallet-id
    /// setters already did; these five now join them.
    function testEveryCounterfactualFunctionAgreesOnTheIdentity() external {
        bytes32 published = adapter.hashBinding(STD, address(token), 1);
        IERC8004IdentityRegistry.MetadataEntry[] memory empty = new IERC8004IdentityRegistry.MetadataEntry[](0);

        vm.startPrank(alice);
        assertEq(adapter.counterfactualRegister(STD, address(token), 1, "ipfs://a"), published, "register");
        assertEq(adapter.counterfactualSetAgentURI(STD, address(token), 1, "ipfs://b"), published, "setAgentURI");
        assertEq(adapter.counterfactualSetMetadata(STD, address(token), 1, "k", bytes("v")), published, "setMetadata");
        assertEq(adapter.counterfactualSetMetadataBatch(STD, address(token), 1, empty), published, "setMetadataBatch");
        assertEq(adapter.counterfactualSetAgentWallet(STD, address(token), 1, wallet), published, "setAgentWallet");
        assertEq(adapter.counterfactualUnsetAgentWallet(STD, address(token), 1), published, "unsetAgentWallet");
        assertEq(adapter.counterfactualSetAgentWalletAndUBID(STD, address(token), 1), published, "setAgentWalletAndID");
        assertEq(adapter.setWalletUBID(STD, address(token), 1), published, "setWalletUBID");
        uint256 agentId = adapter.register(STD, address(token), 1, "ipfs://agent");
        vm.stopPrank();

        assertEq(adapter.bindingHashOf(agentId), published, "bindingHashOf");
    }

    /// @dev `bindingHashOf` answers from the stored binding, so it must agree with the
    /// coordinate form for every standard rather than only for ERC-721.
    function testRegistrationHashOfMatchesTheCoordinateFormAcrossStandards() external {
        MockERC721 other = new MockERC721();
        other.mint(alice, 7);
        MockContractBinder binder = new MockContractBinder(adapter);

        vm.startPrank(alice);
        uint256 erc721Agent = adapter.register(STD, address(other), 7, "ipfs://a");
        vm.stopPrank();
        uint256 accountAgent = binder.register(0);

        assertEq(adapter.bindingHashOf(erc721Agent), adapter.hashBinding(STD, address(other), 7), "ERC721");
        assertEq(
            adapter.bindingHashOf(accountAgent),
            adapter.hashBinding(IERC8217.Standard.ACCOUNT, address(binder), 0),
            "ACCOUNT"
        );
        assertTrue(
            adapter.bindingHashOf(erc721Agent) != adapter.bindingHashOf(accountAgent), "two agents, two identities"
        );
    }

    /// @dev Unknown agents revert rather than answering zero, matching `bindingOf`. A zero answer
    /// would be indistinguishable from a real identity that happened to hash to zero.
    function testRegistrationHashOfRevertsForAnUnknownAgent() external {
        vm.expectRevert(abi.encodeWithSelector(IERC8217.UnknownAgent.selector, uint256(42)));
        adapter.bindingHashOf(42);

        vm.expectRevert(abi.encodeWithSelector(IERC8217.UnknownAgent.selector, uint256(0)));
        adapter.bindingHashOf(0);
    }

    /// @dev The property that makes this view safe to rely on: bindings are immutable, so the answer
    /// is fixed at registration and a token changing hands does not move it.
    function testRegistrationHashOfSurvivesATokenTransfer() external {
        vm.prank(alice);
        uint256 agentId = adapter.register(STD, address(token), 1, "ipfs://agent");
        bytes32 before = adapter.bindingHashOf(agentId);

        vm.prank(alice);
        token.transferFrom(alice, wallet, 1);
        assertEq(token.ownerOf(1), wallet, "premise: the token moved");

        assertEq(adapter.bindingHashOf(agentId), before, "the identity is unchanged");
        assertEq(before, adapter.hashBinding(STD, address(token), 1), "and still the coordinate form");
    }

    // ----------------------------------------------------------------
    //  Helpers
    // ----------------------------------------------------------------

    function _assertPinned(bytes32 returned) private {
        _assertPinnedAgainst(returned, vm.getRecordedLogs());
    }

    /// @dev `ubid` is the first indexed field on every counterfactual event, so
    /// `topics[1]` is the identity the log carries.
    function _assertPinnedAgainst(bytes32 returned, Vm.Log[] memory logs) private view {
        assertEq(returned, adapter.hashBinding(STD, address(token), 1), "matches the published derivation");
        assertEq(logs[0].topics[1], returned, "matches the identity its own event carries");
    }
}
