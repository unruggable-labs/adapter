// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Test} from "forge-std/Test.sol";
import {Vm} from "forge-std/Vm.sol";
import {ERC1967Proxy} from "@openzeppelin/contracts/proxy/ERC1967/ERC1967Proxy.sol";
import {Adapter8004} from "../src/Adapter8004.sol";
import {IERC8217} from "../src/interfaces/IERC8217.sol";
import {IERC8004IdentityRegistry} from "../src/interfaces/IERC8004IdentityRegistry.sol";
import {IERC8004AdapterCounterfactual} from "../src/interfaces/IERC8004AdapterCounterfactual.sol";
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
    //  Coordinate validation on the wallet UBI path
    // ----------------------------------------------------------------

    /// @dev These two setters write and emit without checking authority, deliberately, but they used
    /// to skip coordinate validation too. That let a wallet name an identity no forward claim could
    /// ever match, which an indexer following the interface's own recompute-from-the-triple rule
    /// would then index as an identity that cannot exist.
    function testWalletUBIRejectsCoordinatesNoClaimCanMatch() external {
        // `ACCOUNT` with a nonzero id: rejected by both claim paths, so it must be rejected here.
        vm.expectRevert(
            abi.encodeWithSelector(Adapter8004.NonZeroTokenIdForAccount.selector, address(token), uint256(1))
        );
        vm.prank(alice);
        adapter.setWalletUBI(IERC8217.Standard.ACCOUNT, address(token), 1);

        // The zero address is the unbound sentinel under every standard.
        vm.expectRevert(Adapter8004.InvalidBoundAddress.selector);
        vm.prank(alice);
        adapter.setWalletUBI(IERC8217.Standard.ERC721, address(0), 1);

        // A code-less address under a code-requiring standard.
        vm.expectRevert(Adapter8004.InvalidBoundAddress.selector);
        vm.prank(alice);
        adapter.setWalletUBI(IERC8217.Standard.ERC721, bob, 1);

        // The registry itself, which would resolve control to the adapter once bound.
        vm.expectRevert(abi.encodeWithSelector(Adapter8004.BoundAddressIsRegistry.selector));
        vm.prank(alice);
        adapter.setWalletUBI(IERC8217.Standard.ERC721, address(registry), 1);

        // Nothing was recorded by any of the four rejected calls.
        assertEq(_designationOf(alice), bytes32(0), "no designation recorded");
    }

    /// @dev The `For` variant reaches the same private writer, so it must reject identically rather
    /// than becoming the way around the guard.
    function testWalletUBIForRejectsTheSameCoordinates() external {
        vm.expectRevert(
            abi.encodeWithSelector(Adapter8004.NonZeroTokenIdForAccount.selector, address(token), uint256(1))
        );
        vm.prank(alice);
        adapter.setWalletUBIFor(alice, IERC8217.Standard.ACCOUNT, address(token), 1);

        vm.expectRevert(Adapter8004.InvalidBoundAddress.selector);
        vm.prank(alice);
        adapter.setWalletUBIFor(alice, IERC8217.Standard.ERC721, address(0), 1);
    }

    /// @dev The guard must reject only what the claim paths already reject, so it cannot cost anyone
    /// a designation they could legitimately want. Each coordinate is put through
    /// `counterfactualRegister` first to establish that it is claimable, then designated.
    function testWalletUBIStillAcceptsEveryClaimableCoordinate() external {
        vm.recordLogs();
        // A token in a real collection, unowned by the designator and not yet registered.
        vm.prank(alice);
        adapter.counterfactualRegister(IERC8217.Standard.ERC721, address(token), 1, "ipfs://a");
        vm.prank(bob);
        bytes32 erc721 = adapter.setWalletUBI(IERC8217.Standard.ERC721, address(token), 1);
        assertEq(erc721, adapter.bindingHashFor(IERC8217.Standard.ERC721, address(token), 1));

        // `ACCOUNT` at its canonical id, against a code-less address, which the claim path allows.
        vm.prank(bob);
        adapter.counterfactualRegister(IERC8217.Standard.ACCOUNT, bob, 0, "ipfs://b");
        vm.prank(bob);
        bytes32 account = adapter.setWalletUBI(IERC8217.Standard.ACCOUNT, bob, 0);
        assertEq(account, adapter.bindingHashFor(IERC8217.Standard.ACCOUNT, bob, 0));
        assertEq(_designationOf(bob), account, "the last designation stands under the projection rule");
    }

    /// @dev A token that does not exist yet in a collection that does is still designatable, which is
    /// the counterfactual case the guard must not break. Only the collection needs code.
    function testWalletUBIStillAcceptsAnUnmintedTokenId() external {
        uint256 unminted = 999;
        vm.prank(bob);
        bytes32 designated = adapter.setWalletUBI(IERC8217.Standard.ERC721, address(token), unminted);
        assertEq(designated, adapter.bindingHashFor(IERC8217.Standard.ERC721, address(token), unminted));
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
        adapter.counterfactualSetAgentWalletAndUBI(IERC8217.Standard.ERC721, address(token), 1);
        Vm.Log[] memory combined = vm.getRecordedLogs();

        vm.recordLogs();
        vm.startPrank(alice);
        adapter.counterfactualSetAgentWallet(IERC8217.Standard.ERC721, address(token), 1, alice);
        adapter.setWalletUBI(IERC8217.Standard.ERC721, address(token), 1);
        vm.stopPrank();
        Vm.Log[] memory separate = vm.getRecordedLogs();

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
        adapter.counterfactualSetAgentWalletAndUBI(IERC8217.Standard.ERC721, address(token), 1);

        bytes32 identity = adapter.bindingHashFor(IERC8217.Standard.ERC721, address(token), 1);

        // The forward record names the caller too, so the two halves are about one actor.
        vm.recordLogs();
        vm.prank(alice);
        adapter.counterfactualSetAgentWalletAndUBI(IERC8217.Standard.ERC721, address(token), 1);
        Vm.Log[] memory logs = vm.getRecordedLogs();
        (, address newWallet, address emitter) = abi.decode(logs[0].data, (uint8, address, address));
        assertEq(newWallet, alice, "forward: the wallet named is the caller");
        assertEq(emitter, alice, "forward: emitted by the caller");

        assertEq(_project(logs, alice), identity, "the caller is the wallet");
        assertEq(_project(logs, bob), bytes32(0), "and nobody else");
        assertEq(_project(logs, address(wallet)), bytes32(0), "not even a wallet the caller controls");
    }

    /// @dev The returned hash is pinned to two independent things, not just to itself: the published
    /// derivation `bindingHashFor` exposes, and the identity the emitted event actually carries. A
    /// return value that agreed with neither would be useless, and one that agreed only with itself
    /// would be untestable.
    function testCounterfactualCombinedReturnsTheDerivedHash() external {
        vm.recordLogs();
        vm.prank(alice);
        bytes32 returned = adapter.counterfactualSetAgentWalletAndUBI(IERC8217.Standard.ERC721, address(token), 1);
        Vm.Log[] memory logs = vm.getRecordedLogs();

        assertEq(
            returned,
            adapter.bindingHashFor(IERC8217.Standard.ERC721, address(token), 1),
            "matches the published derivation"
        );
        assertEq(logs[0].topics[1], returned, "matches the CounterfactualAgentWalletSet identity");
        assertEq(logs[1].topics[2], returned, "matches the WalletUBISet identity");
        assertEq(_project(logs, alice), returned, "and the designation a reader projects from it");

        // The sibling it now matches returns the same value for the same coordinates.
        vm.prank(bob);
        bytes32 sibling = adapter.setWalletUBI(IERC8217.Standard.ERC721, address(token), 1);
        assertEq(sibling, returned, "same value as setWalletUBI");
    }

    function testCounterfactualCombinedRequiresTokenAuthority() external {
        vm.expectRevert(abi.encodeWithSelector(Adapter8004.NotController.selector, bob, type(uint256).max));
        vm.prank(bob);
        adapter.counterfactualSetAgentWalletAndUBI(IERC8217.Standard.ERC721, address(token), 1);
    }

    /// @dev The forward guard runs first, so a rejected bound address leaves no reverse pointer.
    function testCounterfactualForwardFailureLeavesNoReversePointer() external {
        vm.expectRevert(Adapter8004.InvalidBoundAddress.selector);
        vm.prank(alice);
        adapter.counterfactualSetAgentWalletAndUBI(IERC8217.Standard.ERC721, address(0), 1);
        assertEq(_designationOf(alice), bytes32(0), "no orphan reverse record");
    }

    /// @dev Latest-wins is a projection rule now rather than an overwrite, so the test reads both
    /// events and applies it rather than reading a slot that no longer exists.
    function testCounterfactualCombinedOverwritesAnExistingDesignation() external {
        vm.recordLogs();
        vm.startPrank(alice);
        adapter.counterfactualSetAgentWalletAndUBI(IERC8217.Standard.ERC721, address(token), 1);
        adapter.counterfactualSetAgentWalletAndUBI(IERC8217.Standard.ERC721, address(token), 2);
        vm.stopPrank();
        Vm.Log[] memory logs = vm.getRecordedLogs();

        bytes32 first = adapter.bindingHashFor(IERC8217.Standard.ERC721, address(token), 1);
        bytes32 second = adapter.bindingHashFor(IERC8217.Standard.ERC721, address(token), 2);
        assertTrue(first != second, "premise: two different identities");
        assertEq(_project(logs, alice), second, "the later designation wins in log order");
    }

    /// @dev Read-time verification on this path now means something: the forward record names the
    /// caller as the wallet and the reverse record has that same caller naming the identity, and one
    /// actor was authorized on both sides.
    function testCounterfactualLoopVerifiesAfterTheCombinedCall() external {
        vm.recordLogs();
        vm.prank(alice);
        adapter.counterfactualSetAgentWalletAndUBI(IERC8217.Standard.ERC721, address(token), 1);
        Vm.Log[] memory logs = vm.getRecordedLogs();

        bytes32 expected = adapter.bindingHashFor(IERC8217.Standard.ERC721, address(token), 1);
        assertEq(logs[0].topics[1], expected, "forward: the wallet event names this identity");
        assertEq(_project(logs, alice), expected, "reverse: the caller names the identity");
    }

    // ----------------------------------------------------------------
    //  Helpers
    // ----------------------------------------------------------------

    /// @dev The published projection rule, implemented once so the tests assert the same thing an
    /// indexer would: latest `WalletUBISet` per account wins, `WalletUBICleared` unsets, in log
    /// order. Zero means no live designation, which is what unset means with nothing stored.
    function _project(Vm.Log[] memory logs, address account) private view returns (bytes32 designated) {
        bytes32 who = bytes32(uint256(uint160(account)));
        for (uint256 i; i < logs.length; ++i) {
            if (logs[i].emitter != address(adapter) || logs[i].topics[1] != who) continue;
            if (logs[i].topics[0] == IERC8004AdapterCounterfactual.WalletUBISet.selector) {
                designated = logs[i].topics[2];
            } else if (logs[i].topics[0] == IERC8004AdapterCounterfactual.WalletUBICleared.selector) {
                designated = bytes32(0);
            }
        }
    }

    /// @dev Same rule, for a test that did not start recording beforehand.
    function _designationOf(address account) private returns (bytes32) {
        return _project(vm.getRecordedLogs(), account);
    }

    function _register(uint256 tokenId) private returns (uint256) {
        vm.prank(alice);
        return adapter.register(IERC8217.Standard.ERC721, address(token), tokenId, "ipfs://agent");
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
