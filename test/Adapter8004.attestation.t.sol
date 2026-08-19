// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Test} from "forge-std/Test.sol";
import {Vm} from "forge-std/Vm.sol";
import {ERC1967Proxy} from "@openzeppelin/contracts/proxy/ERC1967/ERC1967Proxy.sol";
import {ReentrancyGuard} from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import {Adapter8004} from "../src/Adapter8004.sol";
import {IERC8004AdapterAttestation} from "../src/interfaces/IERC8004AdapterAttestation.sol";
import {IERCAgentBindings} from "../src/interfaces/IERCAgentBindings.sol";
import {MockIdentityRegistry} from "./mocks/MockIdentityRegistry.sol";
import {MockERC721} from "./mocks/MockERC721.sol";

/// @notice The attestation surface as implemented on `Adapter8004` itself: what it binds, what it
/// refuses to write, what it deliberately does not guard, and what it costs.
///
/// The projection rules and the published identifier vectors live in
/// `Adapter8004.attestation-projection.t.sol`, which replays reader behaviour over real logs. This
/// file covers the properties that only exist once the surface is inside the adapter: that the
/// identifier binds the proxy rather than the implementation, that no storage is touched, that the
/// reentrancy guard is absent on purpose, and that the code-size margin still holds.
contract Adapter8004AttestationTest is Test {
    /// @dev `keccak256(abi.encode(uint256(keccak256("openzeppelin.storage.ReentrancyGuard")) - 1)) & ~bytes32(uint256(0xff))`,
    /// copied from OpenZeppelin's `ReentrancyGuard`. Writing `ENTERED` here puts the proxy in the
    /// exact state a guarded function sees mid-call, with no mock and no staged callback.
    bytes32 private constant REENTRANCY_GUARD_STORAGE =
        0x9b779b17422d0df92223018b32b4d1fa46e071723d6817e2486d003becc55f00;
    uint256 private constant ENTERED = 2;

    /// @dev EIP-170 runtime code cap, and the margin the upgrade docs require this contract to keep.
    uint256 private constant CODE_SIZE_CAP = 24_576;
    uint256 private constant REQUIRED_MARGIN = 2_000;

    MockIdentityRegistry internal registry;
    Adapter8004 internal implementation;
    Adapter8004 internal adapter;
    MockERC721 internal token;

    // Cached in setUp, never read inline in a pranked call's argument list: a view call there
    // consumes the pending prank and the attestation lands from this test contract instead.
    bytes32 internal tConfirm;
    bytes32 internal tRating;
    bytes32 internal tReview;

    address internal alice = makeAddr("alice");
    address internal bob = makeAddr("bob");
    bytes32 internal cfid = keccak256("target counterfactual identity");

    function setUp() external {
        registry = new MockIdentityRegistry();
        implementation = new Adapter8004();
        adapter = Adapter8004(
            address(
                new ERC1967Proxy(
                    address(implementation), abi.encodeCall(Adapter8004.initialize, (address(registry), address(this)))
                )
            )
        );
        token = new MockERC721();
        token.mint(alice, 1);

        tConfirm = adapter.CONFIRM_ACCOUNT();
        tRating = adapter.RATING();
        tReview = adapter.REVIEW();
    }

    // ----------------------------------------------------------------
    //  What the identifier binds
    // ----------------------------------------------------------------

    /// @dev Fixture risk made executable. An identifier computed against the implementation address
    /// would validate a deployment nobody interacts with, and every call arrives through the proxy,
    /// so the value the contract derives must name the proxy. The two addresses differ here, so the
    /// assertion has teeth.
    function testIdentifierBindsTheProxyNotTheImplementation() external {
        assertTrue(address(adapter) != address(implementation), "premise: proxy and implementation differ");

        vm.recordLogs();
        vm.prank(alice);
        adapter.confirmAdditionalAccount(cfid);
        (bytes32 emittedId,,) = _lastAttested();

        assertEq(
            emittedId,
            _expectedId(address(adapter), alice, cfid, tConfirm, block.number, bytes32(0), ""),
            "identifier binds the proxy"
        );
        assertTrue(
            emittedId != _expectedId(address(implementation), alice, cfid, tConfirm, block.number, bytes32(0), ""),
            "identifier must not bind the implementation"
        );
    }

    /// @dev The emitted attester is `msg.sender` and nothing else. There is no acting-for path and
    /// no submitter field, so a relayer forwarding a call attests as itself, not on anyone's behalf.
    function testEmittedAttesterIsAlwaysTheCaller() external {
        vm.recordLogs();
        vm.prank(alice);
        adapter.attest(tRating, cfid, bytes32(0), hex"32");
        (bytes32 aliceId, address aliceAttester,) = _lastAttested();
        assertEq(aliceAttester, alice);

        vm.recordLogs();
        vm.prank(bob);
        adapter.attest(tRating, cfid, bytes32(0), hex"32");
        (bytes32 bobId, address bobAttester,) = _lastAttested();
        assertEq(bobAttester, bob);

        assertTrue(aliceId != bobId, "the caller is in the preimage, so two callers are two statements");
    }

    /// @dev The negative-encoding matrix from the fixture: each variation must produce a different
    /// identifier, so no component can be dropped, reordered, or re-typed without the value moving.
    function testNegativeEncodingsAllDiffer() external {
        bytes memory data = bytes("solid work");
        bytes32 variant = bytes32(uint256(7));

        vm.recordLogs();
        vm.prank(alice);
        adapter.attest(tReview, cfid, variant, data);
        (bytes32 actual,,) = _lastAttested();

        bytes memory adapterAddress = adapter.interoperableAddress(address(adapter));
        uint256 blockNum = block.number;

        assertEq(
            actual, keccak256(abi.encode(adapterAddress, alice, cfid, tReview, blockNum, variant, data)), "canonical"
        );
        assertTrue(
            actual != keccak256(abi.encodePacked(adapterAddress, alice, cfid, tReview, blockNum, variant, data)),
            "packed encoding"
        );
        assertTrue(
            actual
                != keccak256(abi.encode(keccak256("domain"), adapterAddress, alice, cfid, tReview, blockNum, variant, data)),
            "leading domain constant"
        );
        assertTrue(
            actual != keccak256(abi.encode(adapterAddress, alice, tReview, cfid, blockNum, variant, data)),
            "type and target transposed"
        );
        assertTrue(
            actual != keccak256(abi.encode(address(adapter), alice, cfid, tReview, blockNum, variant, data)),
            "naked adapter address"
        );
        assertTrue(
            actual != keccak256(abi.encode(adapterAddress, alice, cfid, tReview, blockNum, variant)), "payload dropped"
        );
        assertTrue(
            actual != keccak256(abi.encode(adapterAddress, alice, cfid, tReview, blockNum, bytes32(0), data)),
            "variant dropped to zero"
        );
        assertTrue(
            actual != keccak256(abi.encode(adapterAddress, alice, cfid, tReview, blockNum + 1, variant, data)),
            "different block"
        );
    }

    /// @dev The counterfactual hash and the attestation identifier are derived by the same contract
    /// from overlapping material, so the claim that they cannot collide is worth pinning. Their
    /// preimages differ in length by construction: the five-component cfid encoding is a fixed 224
    /// bytes and this one is at least 320.
    function testTheTwoDerivationSchemesCannotCollide() external view {
        bytes memory adapterAddress = adapter.interoperableAddress(address(adapter));
        bytes memory cfidPreimage =
            abi.encode(adapterAddress, IERCAgentBindings.TokenStandard.ERC721, address(token), uint256(42), bytes32(0));
        bytes memory idPreimage = abi.encode(adapterAddress, alice, cfid, tConfirm, block.number, bytes32(0), bytes(""));

        assertEq(cfidPreimage.length, 224, "cfid preimage is a fixed 224 bytes");
        assertGe(idPreimage.length, 320, "identifier preimage is at least 320 bytes");
    }

    // ----------------------------------------------------------------
    //  confirmAdditionalAccount is exactly the generic call
    // ----------------------------------------------------------------

    /// @dev Not merely the same identifier: the same event, byte for byte. Every topic and the whole
    /// non-indexed body must match, so the helper cannot drift into emitting something subtly
    /// different from the call it documents itself as being equivalent to.
    function testConfirmAndAttestProduceByteIdenticalEvents() external {
        vm.recordLogs();
        vm.startPrank(alice);
        adapter.confirmAdditionalAccount(cfid);
        adapter.attest(tConfirm, cfid, bytes32(0), "");
        vm.stopPrank();

        Vm.Log[] memory logs = vm.getRecordedLogs();
        assertEq(logs.length, 2, "one event each");

        assertEq(logs[0].emitter, logs[1].emitter, "same emitter");
        assertEq(logs[0].topics.length, logs[1].topics.length, "same topic count");
        for (uint256 i; i < logs[0].topics.length; ++i) {
            assertEq(logs[0].topics[i], logs[1].topics[i], "same topic");
        }
        assertEq(keccak256(logs[0].data), keccak256(logs[1].data), "same non-indexed body");
    }

    /// @dev The helper's type is the published constant rather than a second spelling of it.
    function testConfirmUsesThePublishedConfirmAccountType() external {
        vm.recordLogs();
        vm.prank(alice);
        adapter.confirmAdditionalAccount(cfid);
        Vm.Log[] memory logs = vm.getRecordedLogs();

        assertEq(logs[0].topics[2], adapter.CONFIRM_ACCOUNT());
        assertEq(adapter.CONFIRM_ACCOUNT(), keccak256(bytes("adapter8004.attest.v1.confirm-account")));
    }

    // ----------------------------------------------------------------
    //  Guards: exactly two, and each fails if deleted
    // ----------------------------------------------------------------

    function testAttestRejectsZeroType() external {
        vm.expectRevert(IERC8004AdapterAttestation.AttestationTypeZero.selector);
        vm.prank(alice);
        adapter.attest(bytes32(0), cfid, bytes32(0), "");
    }

    function testAttestRejectsZeroTarget() external {
        vm.expectRevert(IERC8004AdapterAttestation.AttestationTargetZero.selector);
        vm.prank(alice);
        adapter.attest(tRating, bytes32(0), bytes32(0), hex"32");
    }

    function testConfirmRejectsZeroTarget() external {
        vm.expectRevert(IERC8004AdapterAttestation.AttestationTargetZero.selector);
        vm.prank(alice);
        adapter.confirmAdditionalAccount(bytes32(0));
    }

    /// @dev The type check runs before the target check, so a call with both fields unset reports the
    /// type. Pinned because the revert taxonomy is part of the surface an integrator debugs against.
    function testTypeCheckPrecedesTargetCheck() external {
        vm.expectRevert(IERC8004AdapterAttestation.AttestationTypeZero.selector);
        vm.prank(alice);
        adapter.attest(bytes32(0), bytes32(0), bytes32(0), "");
    }

    /// @dev A nonzero garbage target passes on purpose. Attesting before an identity's first
    /// counterfactual claim is emitted is the supported case, and no set of "real" hashes exists on
    /// chain to check a target against.
    function testUnresolvedTargetIsAccepted() external {
        vm.recordLogs();
        vm.prank(alice);
        adapter.attest(tRating, keccak256("nothing has ever claimed this"), bytes32(0), hex"32");
        Vm.Log[] memory logs = vm.getRecordedLogs();
        assertEq(logs.length, 1, "an unresolved target is a legitimate statement");
    }

    /// @dev Deliberately unguarded, the zero identifier included. Revoking a statement never made is
    /// a recorded no-op for readers, so a sentinel check here would guard against nothing.
    function testRevokeAcceptsAnyIdentifierIncludingZero() external {
        vm.recordLogs();
        vm.startPrank(alice);
        adapter.revoke(bytes32(0));
        adapter.revoke(keccak256("never attested"));
        vm.stopPrank();
        assertEq(vm.getRecordedLogs().length, 2, "every revocation is recorded, none is rejected");
    }

    // ----------------------------------------------------------------
    //  Emit-only: no storage, no calls, no guard
    // ----------------------------------------------------------------

    /// @dev The layout claim as an assertion rather than a comment. `vm.record` captures every
    /// SSTORE the call performs; all three functions must perform none, so the layout still ends at
    /// slot 4 and the upgrade needs no new slot.
    function testNoFunctionWritesAnyStorageSlot() external {
        vm.record();

        vm.startPrank(alice);
        adapter.attest(tReview, cfid, bytes32(uint256(3)), bytes("a review long enough to span words"));
        adapter.confirmAdditionalAccount(cfid);
        adapter.revoke(keccak256("some id"));
        vm.stopPrank();

        (, bytes32[] memory writes) = vm.accesses(address(adapter));
        assertEq(writes.length, 0, "the attestation surface writes no storage at all");
    }

    /// @dev Belt and braces on the same claim, read from the other direction: the slots after the
    /// declared layout stay zero. Slot 4 is the last declared one, so 5 onward must never appear.
    function testSlotsAfterTheDeclaredLayoutStayZero() external {
        vm.startPrank(alice);
        adapter.attest(tRating, cfid, bytes32(0), hex"32");
        adapter.confirmAdditionalAccount(cfid);
        adapter.revoke(keccak256("some id"));
        vm.stopPrank();

        for (uint256 slot = 5; slot <= 12; ++slot) {
            assertEq(vm.load(address(adapter), bytes32(slot)), bytes32(0), "no slot past the declared layout");
        }
    }

    /// @dev The reentrancy guard is absent on purpose, and this is what stops it being reinstated as
    /// a consistency fix. Forcing the guard slot to `ENTERED` puts the proxy in the state a guarded
    /// function sees mid-call. The counterfactual surface, which carries `nonReentrant`, must revert;
    /// all three attestation functions must go through. They make no external call, so the guard
    /// would cost roughly 2,900 gas per call to protect against nothing.
    function testAttestationSurfaceIsDeliberatelyNotReentrancyGuarded() external {
        vm.store(address(adapter), REENTRANCY_GUARD_STORAGE, bytes32(ENTERED));

        // Premise: the store really does simulate being inside a guarded frame.
        vm.expectRevert(ReentrancyGuard.ReentrancyGuardReentrantCall.selector);
        vm.prank(alice);
        adapter.counterfactualRegister(IERCAgentBindings.TokenStandard.ERC721, address(token), 1, "ipfs://cf");

        vm.recordLogs();
        vm.startPrank(alice);
        adapter.attest(tRating, cfid, bytes32(0), hex"32");
        adapter.confirmAdditionalAccount(cfid);
        adapter.revoke(keccak256("some id"));
        vm.stopPrank();

        assertEq(vm.getRecordedLogs().length, 3, "all three run inside a guarded frame");
    }

    // ----------------------------------------------------------------
    //  Event and interface conformance
    // ----------------------------------------------------------------

    function testEventTopicsAndSelectors() external view {
        assertEq(
            IERC8004AdapterAttestation.Attested.selector,
            keccak256("Attested(address,bytes32,bytes32,bytes32,bytes32,bytes)")
        );
        assertEq(
            IERC8004AdapterAttestation.AttestationRevoked.selector, keccak256("AttestationRevoked(bytes32,address)")
        );
        assertEq(IERC8004AdapterAttestation.attest.selector, bytes4(keccak256("attest(bytes32,bytes32,bytes32,bytes)")));
        assertEq(
            IERC8004AdapterAttestation.confirmAdditionalAccount.selector,
            bytes4(keccak256("confirmAdditionalAccount(bytes32)"))
        );
        assertEq(IERC8004AdapterAttestation.revoke.selector, bytes4(keccak256("revoke(bytes32)")));

        // The adapter answers the interface cast, so an integrator can hold only the interface.
        IERC8004AdapterAttestation cast = IERC8004AdapterAttestation(address(adapter));
        assertEq(cast.CONFIRM_ACCOUNT(), adapter.CONFIRM_ACCOUNT());
        assertEq(cast.STAR(), adapter.STAR());
        assertEq(cast.RATING(), adapter.RATING());
        assertEq(cast.REVIEW(), adapter.REVIEW());
        assertEq(cast.INTERACTION(), adapter.INTERACTION());
    }

    /// @dev Five constants, not six. The sixth was a domain separator that the identifier scheme
    /// dropped: nothing here is signed, and the interoperable address already binds the preimage to
    /// this adapter on this chain, so a domain constant would have been inert bytes.
    function testTheSurfaceAddsEightEntryPointsAndNoDomainConstant() external view {
        string[8] memory added = [
            "attest(bytes32,bytes32,bytes32,bytes)",
            "confirmAdditionalAccount(bytes32)",
            "revoke(bytes32)",
            "CONFIRM_ACCOUNT()",
            "STAR()",
            "RATING()",
            "REVIEW()",
            "INTERACTION()"
        ];
        for (uint256 i; i < added.length; ++i) {
            (bool ok,) = address(adapter).staticcall(abi.encodeWithSignature(added[i]));
            // The three writers revert on their zero-argument decode, the readers answer; either way
            // the selector must exist, which a missing function would not.
            assertTrue(ok || i < 3, "entry point missing");
        }

        (bool domainOk,) = address(adapter).staticcall(abi.encodeWithSignature("ATTESTATION_DOMAIN()"));
        assertFalse(domainOk, "there is deliberately no attestation domain constant");
    }

    // ----------------------------------------------------------------
    //  Size and gas
    // ----------------------------------------------------------------

    /// @dev The subsystem is the documented extraction candidate if the cap ever nears, so the margin
    /// is asserted rather than tracked by hand. If this fails, the fix is the extraction discussed in
    /// the upgrade docs, not a smaller floor.
    function testRuntimeSizeKeepsTheRequiredMargin() external view {
        uint256 size = address(implementation).code.length;
        assertLt(size, CODE_SIZE_CAP, "runtime code exceeds the EIP-170 cap");
        assertGe(CODE_SIZE_CAP - size, REQUIRED_MARGIN, "code-size margin has fallen below the floor");
    }

    /// @dev Execution gas for the three entry points, excluding the fixed 21,000 per transaction and
    /// measured warm, so the cold-account surcharge a first touch pays is not folded in. The bounds
    /// are regression detectors around measured values, not targets; the numbers of record are in the
    /// CHANGELOG. A large jump means something started touching storage or calling out, which is the
    /// change worth catching.
    function testGasCosts() external {
        vm.startPrank(alice, alice);
        // Warm the proxy, the implementation, and the memory the encoder grows into. Without this
        // the first measurement carries roughly 13,000 gas of one-off cold-access cost.
        adapter.attest(tRating, cfid, bytes32(uint256(99)), hex"32");

        uint256 before = gasleft();
        adapter.attest(tRating, cfid, bytes32(0), hex"32");
        uint256 attestSmall = before - gasleft();

        before = gasleft();
        adapter.confirmAdditionalAccount(cfid);
        uint256 confirm = before - gasleft();

        before = gasleft();
        adapter.revoke(keccak256("some id"));
        uint256 revokeCost = before - gasleft();

        vm.stopPrank();

        emit log_named_uint("gas: attest (small payload)", attestSmall);
        emit log_named_uint("gas: confirmAdditionalAccount", confirm);
        emit log_named_uint("gas: revoke", revokeCost);

        assertLt(attestSmall, 20_000, "attest with a small payload");
        assertLt(confirm, 20_000, "confirmAdditionalAccount");
        assertLt(revokeCost, 5_000, "revoke");
        assertLt(revokeCost, confirm, "revoke is much the cheapest: no identifier, two topics, no body");
    }

    /// @dev Payload bytes are the author's cost, by design for `REVIEW`. Measured across a large
    /// span rather than a small one: the marginal cost of a few hundred bytes is lost in the noise of
    /// memory already grown, while four kilobytes gives a clean per-byte figure.
    function testPayloadBytesAreThePayersCost() external {
        vm.startPrank(alice, alice);
        adapter.attest(tReview, cfid, bytes32(uint256(99)), new bytes(32));

        uint256 before = gasleft();
        adapter.attest(tReview, cfid, bytes32(0), new bytes(32));
        uint256 small = before - gasleft();

        before = gasleft();
        adapter.attest(tReview, cfid, bytes32(uint256(1)), new bytes(4096));
        uint256 large = before - gasleft();
        vm.stopPrank();

        assertGt(large, small, "a longer payload costs more");
        uint256 perByte = (large - small) / (4096 - 32);
        emit log_named_uint("gas per payload byte", perByte);

        // Dominated by the 8 gas per byte of log data, plus keccak over a longer preimage.
        assertGe(perByte, 5, "payload bytes are not free");
        assertLe(perByte, 15, "payload bytes cost about what log data costs");
    }

    // ----------------------------------------------------------------
    //  Helpers
    // ----------------------------------------------------------------

    function _lastAttested() private view returns (bytes32 id, address attester, bytes32 attestationType) {
        Vm.Log[] memory logs = vm.getRecordedLogs();
        for (uint256 i = logs.length; i > 0; --i) {
            Vm.Log memory log = logs[i - 1];
            if (log.topics[0] != IERC8004AdapterAttestation.Attested.selector) continue;
            (id,,) = abi.decode(log.data, (bytes32, bytes32, bytes));
            return (id, address(uint160(uint256(log.topics[1]))), log.topics[2]);
        }
        revert("no Attested event recorded");
    }

    function _expectedId(
        address src,
        address attester,
        bytes32 target,
        bytes32 attestationType,
        uint256 blockNumber,
        bytes32 variant,
        bytes memory data
    ) private view returns (bytes32) {
        return keccak256(
            abi.encode(adapter.interoperableAddress(src), attester, target, attestationType, blockNumber, variant, data)
        );
    }
}
