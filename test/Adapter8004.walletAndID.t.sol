// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Test} from "forge-std/Test.sol";
import {Vm} from "forge-std/Vm.sol";
import {ERC1967Proxy} from "@openzeppelin/contracts/proxy/ERC1967/ERC1967Proxy.sol";
import {Adapter8004} from "../src/Adapter8004.sol";
import {IERCAgentBindings} from "../src/interfaces/IERCAgentBindings.sol";
import {IERC8004IdentityRegistry} from "../src/interfaces/IERC8004IdentityRegistry.sol";
import {MockIdentityRegistry} from "./mocks/MockIdentityRegistry.sol";
import {MockERC721} from "./mocks/MockERC721.sol";

/// @dev A wallet that its agent's owner also controls, so the combined call and the two separate
/// calls are both available to the same caller. Without that the reverse event's `setBy` would
/// differ between the two routes and no byte-identity comparison would be possible: the wallet
/// calling `setWalletAgentID` itself records the wallet as `setBy`, while the combined call records
/// the agent owner.
contract OwnedErc1271Wallet {
    bytes4 private constant MAGIC = 0x1626ba7e;

    address public owner;

    constructor(address owner_) {
        owner = owner_;
    }

    /// @dev Accepts any signature. The registry's verification path is exercised elsewhere; here the
    /// point is that the wallet is a contract its agent's owner controls.
    function isValidSignature(bytes32, bytes memory) external pure returns (bytes4) {
        return MAGIC;
    }
}

/// @notice The two combined setters, which close the wallet loop in one call.
contract Adapter8004WalletAndIDTest is Test {
    MockIdentityRegistry internal registry;
    Adapter8004 internal adapter;
    MockERC721 internal token;
    OwnedErc1271Wallet internal wallet;

    address internal alice = makeAddr("alice");
    address internal bob = makeAddr("bob");
    address internal admin = makeAddr("admin");

    function setUp() external {
        registry = new MockIdentityRegistry();
        adapter = Adapter8004(
            address(
                new ERC1967Proxy(
                    address(new Adapter8004(address(registry))), abi.encodeCall(Adapter8004.initialize, (admin))
                )
            )
        );
        token = new MockERC721();
        token.mint(alice, 1);
        token.mint(alice, 2);
        wallet = new OwnedErc1271Wallet(alice);
    }

    // ----------------------------------------------------------------
    //  Coordinate validation on the wallet-counterfactual-id path
    // ----------------------------------------------------------------

    /// @dev These two setters write and emit without checking authority, deliberately, but they used
    /// to skip coordinate validation too. That let a wallet name an identity no forward claim could
    /// ever match, which an indexer following the interface's own recompute-from-the-triple rule
    /// would then index as an identity that cannot exist.
    function testWalletCounterfactualIDRejectsCoordinatesNoClaimCanMatch() external {
        // `ACCOUNT` with a nonzero id: rejected by both claim paths, so it must be rejected here.
        vm.expectRevert(
            abi.encodeWithSelector(Adapter8004.NonZeroTokenIdForAccount.selector, address(token), uint256(1))
        );
        vm.prank(alice);
        adapter.setWalletCounterfactualID(IERCAgentBindings.TokenStandard.ACCOUNT, address(token), 1);

        // The zero address is the unbound sentinel under every standard.
        vm.expectRevert(Adapter8004.InvalidBoundAddress.selector);
        vm.prank(alice);
        adapter.setWalletCounterfactualID(IERCAgentBindings.TokenStandard.ERC721, address(0), 1);

        // A code-less address under a code-requiring standard.
        vm.expectRevert(Adapter8004.InvalidBoundAddress.selector);
        vm.prank(alice);
        adapter.setWalletCounterfactualID(IERCAgentBindings.TokenStandard.ERC721, bob, 1);

        // The registry itself, which would resolve control to the adapter once bound.
        vm.expectRevert(abi.encodeWithSelector(Adapter8004.BoundAddressIsRegistry.selector));
        vm.prank(alice);
        adapter.setWalletCounterfactualID(IERCAgentBindings.TokenStandard.ERC721, address(registry), 1);

        // Nothing was written by any of the four rejected calls.
        assertEq(adapter.walletCounterfactualIDOf(alice), adapter.WALLET_COUNTERFACTUAL_ID_UNSET(), "no write");
    }

    /// @dev The `For` variant reaches the same private writer, so it must reject identically rather
    /// than becoming the way around the guard.
    function testWalletCounterfactualIDForRejectsTheSameCoordinates() external {
        vm.expectRevert(
            abi.encodeWithSelector(Adapter8004.NonZeroTokenIdForAccount.selector, address(token), uint256(1))
        );
        vm.prank(alice);
        adapter.setWalletCounterfactualIDFor(alice, IERCAgentBindings.TokenStandard.ACCOUNT, address(token), 1);

        vm.expectRevert(Adapter8004.InvalidBoundAddress.selector);
        vm.prank(alice);
        adapter.setWalletCounterfactualIDFor(alice, IERCAgentBindings.TokenStandard.ERC721, address(0), 1);
    }

    /// @dev The guard must reject only what the claim paths already reject, so it cannot cost anyone
    /// a designation they could legitimately want. Each coordinate is put through
    /// `counterfactualRegister` first to establish that it is claimable, then designated.
    function testWalletCounterfactualIDStillAcceptsEveryClaimableCoordinate() external {
        // A token in a real collection, unowned by the designator and not yet registered.
        vm.prank(alice);
        adapter.counterfactualRegister(IERCAgentBindings.TokenStandard.ERC721, address(token), 1, "ipfs://a");
        vm.prank(bob);
        bytes32 erc721 = adapter.setWalletCounterfactualID(IERCAgentBindings.TokenStandard.ERC721, address(token), 1);
        assertEq(erc721, adapter.ubiFor(IERCAgentBindings.TokenStandard.ERC721, address(token), 1));

        // `ACCOUNT` at its canonical id, against a code-less address, which the claim path allows.
        vm.prank(bob);
        adapter.counterfactualRegister(IERCAgentBindings.TokenStandard.ACCOUNT, bob, 0, "ipfs://b");
        vm.prank(bob);
        bytes32 account = adapter.setWalletCounterfactualID(IERCAgentBindings.TokenStandard.ACCOUNT, bob, 0);
        assertEq(account, adapter.ubiFor(IERCAgentBindings.TokenStandard.ACCOUNT, bob, 0));
        assertEq(adapter.walletCounterfactualIDOf(bob), account, "the last designation stands");
    }

    /// @dev A token that does not exist yet in a collection that does is still designatable, which is
    /// the counterfactual case the guard must not break. Only the collection needs code.
    function testWalletCounterfactualIDStillAcceptsAnUnmintedTokenId() external {
        uint256 unminted = 999;
        vm.prank(bob);
        bytes32 designated =
            adapter.setWalletCounterfactualID(IERCAgentBindings.TokenStandard.ERC721, address(token), unminted);
        assertEq(designated, adapter.ubiFor(IERCAgentBindings.TokenStandard.ERC721, address(token), unminted));
    }

    // ----------------------------------------------------------------
    //  Registered path
    // ----------------------------------------------------------------

    /// @dev The whole point of the surface: one call must leave exactly the state and the logs that
    /// the two calls leave, so an indexer needs no new subscription and the existing projection keeps
    /// working unchanged.
    function testRegisteredCombinedMatchesTwoSeparateCalls() external {
        uint256 combinedAgent = _register(1);
        uint256 deadline = block.timestamp + 4 minutes;

        vm.recordLogs();
        vm.prank(alice);
        adapter.setAgentWalletAndID(combinedAgent, address(wallet), deadline, hex"00");
        Vm.Log[] memory combined = vm.getRecordedLogs();
        uint256 combinedPointer = adapter.walletAgentIDOf(address(wallet));
        address combinedWallet = registry.getAgentWallet(combinedAgent);

        // Reset the reverse pointer so the second route starts from the same place.
        vm.prank(alice);
        adapter.clearWalletAgentIDFor(address(wallet));

        uint256 separateAgent = _register(2);
        vm.recordLogs();
        vm.startPrank(alice);
        adapter.setAgentWallet(separateAgent, address(wallet), deadline, hex"00");
        adapter.setWalletAgentIDFor(address(wallet), separateAgent);
        vm.stopPrank();
        Vm.Log[] memory separate = vm.getRecordedLogs();

        assertEq(registry.getAgentWallet(separateAgent), combinedWallet, "same forward record");
        assertEq(combinedPointer, combinedAgent, "combined: the wallet points back at its agent");
        assertEq(adapter.walletAgentIDOf(address(wallet)), separateAgent, "separate: the same, for its agent");
        _assertAdapterLogsMatch(combined, separate, combinedAgent, separateAgent);
    }

    /// @dev The forward write failing must take the reverse write with it. This matters most here,
    /// because the registry can reject the wallet signature after the caller has already proved
    /// control of the agent.
    function testRegisteredForwardFailureLeavesNoReversePointer() external {
        uint256 agentId = _register(1);
        assertEq(adapter.walletAgentIDOf(alice), adapter.WALLET_AGENT_ID_UNSET(), "premise: unset");

        // An EOA wallet cannot answer ERC-1271, so the registry rejects the signature.
        vm.expectRevert();
        vm.prank(alice);
        adapter.setAgentWalletAndID(agentId, bob, block.timestamp + 4 minutes, hex"00");

        assertEq(adapter.walletAgentIDOf(bob), adapter.WALLET_AGENT_ID_UNSET(), "no orphan reverse pointer");
        assertEq(registry.getAgentWallet(agentId), address(0), "and no forward record");
    }

    function testRegisteredCombinedRequiresAgentControl() external {
        uint256 agentId = _register(1);
        vm.expectRevert(abi.encodeWithSelector(Adapter8004.NotController.selector, bob, agentId));
        vm.prank(bob);
        adapter.setAgentWalletAndID(agentId, address(wallet), block.timestamp + 4 minutes, hex"00");
    }

    /// @dev Overwriting is intended, not incidental. A wallet designated for one agent and then named
    /// by another ends up pointing at the second, and the first agent's forward record is untouched.
    function testRegisteredCombinedOverwritesAnExistingDesignation() external {
        uint256 first = _register(1);
        uint256 second = _register(2);
        uint256 deadline = block.timestamp + 4 minutes;

        vm.startPrank(alice);
        adapter.setAgentWalletAndID(first, address(wallet), deadline, hex"00");
        assertEq(adapter.walletAgentIDOf(address(wallet)), first);

        adapter.setAgentWalletAndID(second, address(wallet), deadline, hex"00");
        vm.stopPrank();

        assertEq(adapter.walletAgentIDOf(address(wallet)), second, "the later call wins");
        assertEq(registry.getAgentWallet(first), address(wallet), "the first agent still names the wallet");
    }

    /// @dev Read-time verification, which is what makes the missing wallet-side gate a decision
    /// rather than an oversight: the loop is closed when the forward and reverse records agree.
    function testRegisteredLoopVerifiesAfterTheCombinedCall() external {
        uint256 agentId = _register(1);
        vm.prank(alice);
        adapter.setAgentWalletAndID(agentId, address(wallet), block.timestamp + 4 minutes, hex"00");

        assertEq(registry.getAgentWallet(agentId), address(wallet), "forward: agent names the wallet");
        assertEq(adapter.walletAgentIDOf(address(wallet)), agentId, "reverse: wallet names the agent");
    }

    /// @dev And a wallet that did not want the designation overwrites it itself, which is why a
    /// wrongly written reverse pointer produces no lasting false positive.
    function testWalletCanOverwriteAnUnwantedDesignation() external {
        uint256 agentId = _register(1);
        vm.prank(alice);
        adapter.setAgentWalletAndID(agentId, address(wallet), block.timestamp + 4 minutes, hex"00");
        assertEq(adapter.walletAgentIDOf(address(wallet)), agentId);

        vm.prank(address(wallet));
        adapter.clearWalletAgentID();
        assertEq(adapter.walletAgentIDOf(address(wallet)), adapter.WALLET_AGENT_ID_UNSET(), "wallet has the last word");
    }

    // ----------------------------------------------------------------
    //  Counterfactual path
    // ----------------------------------------------------------------

    /// @dev The counterfactual combined call now names the caller as the wallet, so the equivalent
    /// two-call sequence is the forward write naming `msg.sender` followed by the caller setting its
    /// own reverse pointer.
    function testCounterfactualCombinedMatchesTwoSeparateCalls() external {
        vm.recordLogs();
        vm.prank(alice);
        adapter.counterfactualSetAgentWalletAndID(IERCAgentBindings.TokenStandard.ERC721, address(token), 1);
        Vm.Log[] memory combined = vm.getRecordedLogs();
        bytes32 combinedPointer = adapter.walletCounterfactualIDOf(alice);

        vm.prank(alice);
        adapter.clearWalletCounterfactualID();

        vm.recordLogs();
        vm.startPrank(alice);
        adapter.counterfactualSetAgentWallet(IERCAgentBindings.TokenStandard.ERC721, address(token), 1, alice);
        adapter.setWalletCounterfactualID(IERCAgentBindings.TokenStandard.ERC721, address(token), 1);
        vm.stopPrank();
        Vm.Log[] memory separate = vm.getRecordedLogs();

        assertEq(adapter.walletCounterfactualIDOf(alice), combinedPointer, "same reverse record");
        assertEq(combined.length, separate.length, "same number of events");
        for (uint256 i; i < combined.length; ++i) {
            assertEq(combined[i].emitter, separate[i].emitter, "same emitter");
            assertEq(combined[i].topics.length, separate[i].topics.length, "same topic count");
            for (uint256 j; j < combined[i].topics.length; ++j) {
                assertEq(combined[i].topics[j], separate[i].topics[j], "same topic");
            }
            assertEq(keccak256(combined[i].data), keccak256(separate[i].data), "same body");
        }
    }

    /// @dev The property the whole consent argument rests on. The reverse pointer is written for the
    /// caller and for nobody else, so there is no way to designate an address that did not act.
    function testCounterfactualCombinedWritesTheReversePointerForTheCallerOnly() external {
        vm.prank(alice);
        adapter.counterfactualSetAgentWalletAndID(IERCAgentBindings.TokenStandard.ERC721, address(token), 1);

        bytes32 identity = adapter.ubiFor(IERCAgentBindings.TokenStandard.ERC721, address(token), 1);
        assertEq(adapter.walletCounterfactualIDOf(alice), identity, "the caller is the wallet");
        assertEq(adapter.walletCounterfactualIDOf(bob), adapter.WALLET_COUNTERFACTUAL_ID_UNSET(), "and nobody else");
        assertEq(
            adapter.walletCounterfactualIDOf(address(wallet)),
            adapter.WALLET_COUNTERFACTUAL_ID_UNSET(),
            "not even a wallet the caller controls"
        );

        // The forward record names the caller too, so the two halves are about one actor.
        vm.recordLogs();
        vm.prank(alice);
        adapter.counterfactualSetAgentWalletAndID(IERCAgentBindings.TokenStandard.ERC721, address(token), 1);
        Vm.Log[] memory logs = vm.getRecordedLogs();
        (, address newWallet, address emitter) = abi.decode(logs[0].data, (uint8, address, address));
        assertEq(newWallet, alice, "forward: the wallet named is the caller");
        assertEq(emitter, alice, "forward: emitted by the caller");
    }

    /// @dev The returned hash is pinned to two independent things, not just to itself: the published
    /// derivation `ubiFor` exposes, and the identity the emitted event actually carries. A
    /// return value that agreed with neither would be useless, and one that agreed only with itself
    /// would be untestable.
    function testCounterfactualCombinedReturnsTheDerivedHash() external {
        vm.recordLogs();
        vm.prank(alice);
        bytes32 returned =
            adapter.counterfactualSetAgentWalletAndID(IERCAgentBindings.TokenStandard.ERC721, address(token), 1);
        Vm.Log[] memory logs = vm.getRecordedLogs();

        assertEq(
            returned,
            adapter.ubiFor(IERCAgentBindings.TokenStandard.ERC721, address(token), 1),
            "matches the published derivation"
        );
        assertEq(logs[0].topics[1], returned, "matches the CounterfactualAgentWalletSet identity");
        assertEq(logs[1].topics[2], returned, "matches the WalletCounterfactualIDSet identity");
        assertEq(adapter.walletCounterfactualIDOf(alice), returned, "and the reverse pointer it wrote");

        // The sibling it now matches returns the same value for the same coordinates.
        vm.prank(bob);
        bytes32 sibling = adapter.setWalletCounterfactualID(IERCAgentBindings.TokenStandard.ERC721, address(token), 1);
        assertEq(sibling, returned, "same value as setWalletCounterfactualID");
    }

    function testCounterfactualCombinedRequiresTokenAuthority() external {
        vm.expectRevert(abi.encodeWithSelector(Adapter8004.NotController.selector, bob, type(uint256).max));
        vm.prank(bob);
        adapter.counterfactualSetAgentWalletAndID(IERCAgentBindings.TokenStandard.ERC721, address(token), 1);
    }

    /// @dev The forward guard runs first, so a rejected bound address leaves no reverse pointer.
    function testCounterfactualForwardFailureLeavesNoReversePointer() external {
        vm.expectRevert(Adapter8004.InvalidBoundAddress.selector);
        vm.prank(alice);
        adapter.counterfactualSetAgentWalletAndID(IERCAgentBindings.TokenStandard.ERC721, address(0), 1);
        assertEq(
            adapter.walletCounterfactualIDOf(alice),
            adapter.WALLET_COUNTERFACTUAL_ID_UNSET(),
            "no orphan reverse pointer"
        );
    }

    function testCounterfactualCombinedOverwritesAnExistingDesignation() external {
        vm.startPrank(alice);
        adapter.counterfactualSetAgentWalletAndID(IERCAgentBindings.TokenStandard.ERC721, address(token), 1);
        bytes32 first = adapter.walletCounterfactualIDOf(alice);

        adapter.counterfactualSetAgentWalletAndID(IERCAgentBindings.TokenStandard.ERC721, address(token), 2);
        vm.stopPrank();

        bytes32 second = adapter.walletCounterfactualIDOf(alice);
        assertTrue(first != second, "the pointer moved");
        assertEq(second, adapter.ubiFor(IERCAgentBindings.TokenStandard.ERC721, address(token), 2));
    }

    /// @dev Read-time verification on this path now means something: the forward record names the
    /// caller as the wallet and the reverse record has that same caller naming the identity, and one
    /// actor was authorized on both sides.
    function testCounterfactualLoopVerifiesAfterTheCombinedCall() external {
        vm.recordLogs();
        vm.prank(alice);
        adapter.counterfactualSetAgentWalletAndID(IERCAgentBindings.TokenStandard.ERC721, address(token), 1);
        Vm.Log[] memory logs = vm.getRecordedLogs();

        bytes32 expected = adapter.ubiFor(IERCAgentBindings.TokenStandard.ERC721, address(token), 1);
        assertEq(logs[0].topics[1], expected, "forward: the wallet event names this identity");
        assertEq(adapter.walletCounterfactualIDOf(alice), expected, "reverse: the caller names the identity");
    }

    // ----------------------------------------------------------------
    //  Helpers
    // ----------------------------------------------------------------

    function _register(uint256 tokenId) private returns (uint256) {
        vm.prank(alice);
        return adapter.register(IERCAgentBindings.TokenStandard.ERC721, address(token), tokenId, "ipfs://agent");
    }

    /// @dev Compares the adapter's own logs from both routes. The agent id differs between the two
    /// runs, so the fields carrying it are compared after substituting the run's own id.
    function _assertAdapterLogsMatch(
        Vm.Log[] memory combined,
        Vm.Log[] memory separate,
        uint256 combinedAgent,
        uint256 separateAgent
    ) private view {
        Vm.Log[] memory a = _onlyAdapterLogs(combined);
        Vm.Log[] memory b = _onlyAdapterLogs(separate);
        assertEq(a.length, b.length, "same number of adapter events");
        assertEq(a.length, 2, "AgentWalletSet then WalletAgentIDSet");

        for (uint256 i; i < a.length; ++i) {
            assertEq(a[i].topics.length, b[i].topics.length, "same topic count");
            for (uint256 j; j < a[i].topics.length; ++j) {
                bytes32 left = a[i].topics[j];
                bytes32 right = b[i].topics[j];
                if (left == bytes32(combinedAgent) && right == bytes32(separateAgent)) continue;
                assertEq(left, right, "same topic");
            }
            assertEq(keccak256(a[i].data), keccak256(b[i].data), "same body");
        }
    }

    function _onlyAdapterLogs(Vm.Log[] memory logs) private view returns (Vm.Log[] memory out) {
        uint256 n;
        for (uint256 i; i < logs.length; ++i) {
            if (logs[i].emitter == address(adapter)) ++n;
        }
        out = new Vm.Log[](n);
        uint256 k;
        for (uint256 i; i < logs.length; ++i) {
            if (logs[i].emitter == address(adapter)) out[k++] = logs[i];
        }
    }
}
