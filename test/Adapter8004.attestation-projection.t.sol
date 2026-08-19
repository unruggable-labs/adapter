// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Test} from "forge-std/Test.sol";
import {Vm} from "forge-std/Vm.sol";
import {ERC1967Proxy} from "@openzeppelin/contracts/proxy/ERC1967/ERC1967Proxy.sol";
import {Adapter8004} from "../src/Adapter8004.sol";
import {IERC8004AdapterAttestation} from "../src/interfaces/IERC8004AdapterAttestation.sol";
import {MockIdentityRegistry} from "./mocks/MockIdentityRegistry.sol";

/// @notice Projection harness: records the events the real `Adapter8004` proxy emits and replays the
/// published reader rules over them in log order. Built in slice two-a against a reference emitter
/// and re-pointed here at the contract itself, unchanged in every rule it asserts. Rule four, that a revocation counts only when its caller is the
/// original attester, cannot be a contract test at all, because the contract records every
/// revocation and stores nothing, so this replay is its only executable home. The same holds for
/// the per-type payload rules, which the contract never decodes.
contract AttestationProjectionTest is Test {
    bytes32 private constant ATTESTED_SIG = keccak256("Attested(address,bytes32,bytes32,bytes32,bytes32,bytes)");
    bytes32 private constant REVOKED_SIG = keccak256("AttestationRevoked(bytes32,address)");

    struct Ev {
        bool isRevoke;
        address actor;
        bytes32 attType;
        bytes32 cfid;
        bytes32 id;
        bytes data;
        uint256 blockNum;
    }

    Adapter8004 internal adapter;
    Ev[] internal evs;

    // Cached once: a view call in an argument list would otherwise consume a pending vm.prank,
    // silently attesting from the test contract instead of the pranked account.
    bytes32 internal tConfirm;
    bytes32 internal tStar;
    bytes32 internal tRating;
    bytes32 internal tReview;

    address internal alice = address(uint160(0xA11CE));
    address internal bob = address(uint160(0xB0B));
    address internal carol = address(uint160(0xCA401));
    bytes32 internal cfid = keccak256("some counterfactual identity");

    function setUp() public {
        MockIdentityRegistry registry = new MockIdentityRegistry();
        Adapter8004 implementation = new Adapter8004();
        adapter = Adapter8004(
            address(
                new ERC1967Proxy(
                    address(implementation), abi.encodeCall(Adapter8004.initialize, (address(registry), address(this)))
                )
            )
        );
        tConfirm = adapter.CONFIRM_ACCOUNT();
        tStar = adapter.STAR();
        tRating = adapter.RATING();
        tReview = adapter.REVIEW();
        vm.recordLogs();
    }

    // ----------------------------------------------------------------
    //  Log capture
    // ----------------------------------------------------------------

    /// @dev Pull everything recorded since the last drain and stamp it with the current block.
    /// Vm.Log carries no block number, so tests drain once per block segment, before rolling.
    function drain() internal {
        Vm.Log[] memory logs = vm.getRecordedLogs();
        for (uint256 i; i < logs.length; ++i) {
            if (logs[i].topics[0] == ATTESTED_SIG) {
                // The projection keys on the id, which already commits to the variant.
                (bytes32 id,, bytes memory data) = abi.decode(logs[i].data, (bytes32, bytes32, bytes));
                evs.push(
                    Ev({
                        isRevoke: false,
                        actor: address(uint160(uint256(logs[i].topics[1]))),
                        attType: logs[i].topics[2],
                        cfid: logs[i].topics[3],
                        id: id,
                        data: data,
                        blockNum: block.number
                    })
                );
            } else if (logs[i].topics[0] == REVOKED_SIG) {
                evs.push(
                    Ev({
                        isRevoke: true,
                        actor: address(uint160(uint256(logs[i].topics[2]))),
                        attType: bytes32(0),
                        cfid: bytes32(0),
                        id: logs[i].topics[1],
                        data: "",
                        blockNum: block.number
                    })
                );
            }
        }
    }

    function roll(uint256 newBlock) internal {
        drain();
        vm.roll(newBlock);
    }

    function lastId() internal view returns (bytes32) {
        for (uint256 i = evs.length; i > 0; --i) {
            if (!evs[i - 1].isRevoke) return evs[i - 1].id;
        }
        revert("no attestation recorded");
    }

    // ----------------------------------------------------------------
    //  Reader rules, replayed in log order
    // ----------------------------------------------------------------

    /// @dev Rules 2, 3, and 4. A statement is live when its latest legitimate action is an
    /// attestation. The attester of an id is fixed by the first Attested event bearing it, and a
    /// revocation counts only when its caller equals that attester. A revocation seen before any
    /// attestation of its id, the zero id included, refers to a statement never made and does
    /// nothing.
    function isLive(bytes32 id) internal view returns (bool) {
        address knownAttester;
        bool live;
        for (uint256 i; i < evs.length; ++i) {
            if (evs[i].id != id) continue;
            if (!evs[i].isRevoke) {
                if (knownAttester == address(0)) knownAttester = evs[i].actor;
                live = true;
            } else if (knownAttester != address(0) && evs[i].actor == knownAttester) {
                live = false;
            }
        }
        return live;
    }

    /// @dev Rule 5, state projection: the latest live attestation per (attester, cfid, type) is
    /// the current position. Latest means latest Attested occurrence in log order, so a
    /// reactivated statement is as current as its most recent emission.
    function currentState(address attester, bytes32 target, bytes32 attType)
        internal
        view
        returns (bool has, bytes memory data)
    {
        for (uint256 i; i < evs.length; ++i) {
            Ev storage e = evs[i];
            if (e.isRevoke || e.actor != attester || e.cfid != target || e.attType != attType) continue;
            if (isLive(e.id)) {
                has = true;
                data = e.data;
            }
        }
    }

    // ----------------------------------------------------------------
    //  Payload rules, the read-time checks the contract never performs
    // ----------------------------------------------------------------

    function validStar(bytes memory data) internal pure returns (bool) {
        return data.length == 1 && uint8(data[0]) <= 1;
    }

    function validRating(bytes memory data) internal pure returns (bool) {
        return data.length == 1 && uint8(data[0]) <= 100;
    }

    function validReview(bytes memory data) internal pure returns (bool) {
        return data.length >= 1;
    }

    function validInteraction(bytes memory data) internal pure returns (bool) {
        return data.length >= 33 && uint8(data[0]) <= 100;
    }

    // ----------------------------------------------------------------
    //  Aggregation
    // ----------------------------------------------------------------

    function starCount(bytes32 target) internal view returns (uint256 count) {
        address[] memory seen = _attestersOf(target, tStar);
        for (uint256 i; i < seen.length; ++i) {
            (bool has, bytes memory data) = currentState(seen[i], target, tStar);
            if (has && validStar(data) && uint8(data[0]) == 1) ++count;
        }
    }

    function ratingAverage(bytes32 target, address[] memory dependents) internal view returns (uint256 avg) {
        address[] memory seen = _attestersOf(target, tRating);
        uint256 sum;
        uint256 n;
        for (uint256 i; i < seen.length; ++i) {
            if (_contains(dependents, seen[i])) continue;
            (bool has, bytes memory data) = currentState(seen[i], target, tRating);
            if (has && validRating(data)) {
                sum += uint8(data[0]);
                ++n;
            }
        }
        avg = n == 0 ? 0 : sum / n;
    }

    function _attestersOf(bytes32 target, bytes32 attType) internal view returns (address[] memory) {
        address[] memory tmp = new address[](evs.length);
        uint256 n;
        for (uint256 i; i < evs.length; ++i) {
            Ev storage e = evs[i];
            if (e.isRevoke || e.cfid != target || e.attType != attType) continue;
            if (!_contains(_shrink(tmp, n), e.actor)) tmp[n++] = e.actor;
        }
        return _shrink(tmp, n);
    }

    function _shrink(address[] memory arr, uint256 n) internal pure returns (address[] memory out) {
        out = new address[](n);
        for (uint256 i; i < n; ++i) {
            out[i] = arr[i];
        }
    }

    function _contains(address[] memory arr, address a) internal pure returns (bool) {
        for (uint256 i; i < arr.length; ++i) {
            if (arr[i] == a) return true;
        }
        return false;
    }

    /// @dev The identifier formula, for tests that need an id before or without its attestation.
    function idOf(address src, address attester, bytes32 target, bytes32 attType, bytes32 variant, bytes memory data)
        internal
        view
        returns (bytes32)
    {
        return
            keccak256(abi.encode(_interop(src, block.chainid), attester, target, attType, block.number, variant, data));
    }

    function _interop(address account, uint256 chainId) internal pure returns (bytes memory identifier) {
        uint256 referenceLength;
        uint256 remaining = chainId;
        while (remaining != 0) {
            ++referenceLength;
            remaining >>= 8;
        }
        identifier = new bytes(referenceLength + 26);
        identifier[1] = 0x01;
        identifier[4] = bytes1(uint8(referenceLength));
        for (uint256 i; i < referenceLength; ++i) {
            identifier[5 + referenceLength - 1 - i] = bytes1(uint8(chainId >> (i * 8)));
        }
        identifier[5 + referenceLength] = 0x14;
        bytes20 rawAddress = bytes20(account);
        for (uint256 i; i < 20; ++i) {
            identifier[6 + referenceLength + i] = rawAddress[i];
        }
    }

    // ----------------------------------------------------------------
    //  Constants and fixture vectors
    // ----------------------------------------------------------------

    function testConstantsPinnedAgainstExactBytes() public view {
        assertEq(adapter.CONFIRM_ACCOUNT(), 0x0d1301b55a7106242fdc007f7371d46dbf2cef93819719bb571322d165ef0bdb);
        assertEq(adapter.STAR(), 0xe57ebfd03b6f9111378311d8b209d3c35c5c9c45ce387029dbe32c0ff44b2651);
        assertEq(adapter.RATING(), 0xe29bafddb9bd210da3ccc8f60685504f8868bbcce6d9c216f35f0f841a6618b5);
        assertEq(adapter.REVIEW(), 0x0ce439abec3b50d9bb4c1c26b71f5e02b7dac5a8f4546824b09b0066c94e6aed);
        assertEq(adapter.INTERACTION(), 0x38bd7d6c19f392ef255c7033e6700c65ef16fc48f3ced5e18caf837f3231fedf);
    }

    /// @notice The exact-bytes vectors from docs/fixtures/adapter-attestation-ids.md, reproduced
    /// in their stated environment: chain id 1, the adapter's own runtime code at the fixture proxy
    /// address, the fixture callers, the fixture block. Each assertion pins one component's place in
    /// the formula against precomputed bytes, never a round trip.
    /// @dev The implementation runtime is etched directly at the fixture address rather than put
    /// behind a proxy there. `attest` reads no storage, so the delegate hop cannot affect the
    /// identifier; what matters is that `address(this)` is the fixture's stated proxy address, which
    /// etching gives exactly. `testIdentifierBindsTheProxyNotTheImplementation` covers the hop
    /// itself, which is the failure this fixture would otherwise be blind to.
    function testFixtureVectors() public {
        address proxy = 0x1111111111111111111111111111111111111111;
        vm.etch(proxy, address(new Adapter8004()).code);
        vm.chainId(1);
        vm.roll(19000000);
        IERC8004AdapterAttestation fx = IERC8004AdapterAttestation(proxy);
        bytes32 fxCfid = 0xefa93cfacbc3a08981c5725059a0a35e463f4063313da93f44d85cc02f457a0b;

        vm.prank(alice);
        fx.confirmAdditionalAccount(fxCfid);
        drain();
        assertEq(lastId(), 0x80d05e729b10ebc5c0852c919bcb47c18342bac827ab09e307827dd576332e67, "vector 1");

        vm.prank(alice);
        fx.attest(tConfirm, fxCfid, bytes32(uint256(1)), "");
        drain();
        assertEq(lastId(), 0x97ff8f55126d26f62b78c5ec3b8908e1ab8bb76891d5e955832ab8cca1d0a202, "vector 2");

        vm.prank(alice);
        fx.attest(tRating, fxCfid, bytes32(0), hex"57");
        drain();
        assertEq(lastId(), 0x127945db7ff1b8f34cfd587ee3605c33c70d686af9ae9081413fd0929a70f6de, "vector 3");

        vm.prank(bob);
        fx.confirmAdditionalAccount(fxCfid);
        drain();
        assertEq(lastId(), 0x1d000c7a6200f50086414eaab8e24343cca0a45518e82657ee5d652de28ebc87, "vector 4");

        vm.roll(19000001);
        vm.prank(alice);
        fx.confirmAdditionalAccount(fxCfid);
        drain();
        assertEq(lastId(), 0x3b3f23c978049fa900522abac43b368325b25936825ed83e402a4214e4ab762a, "vector 5");
    }

    // ----------------------------------------------------------------
    //  Guards
    // ----------------------------------------------------------------

    function testAttestRejectsZeroType() public {
        vm.expectRevert(IERC8004AdapterAttestation.AttestationTypeZero.selector);
        adapter.attest(bytes32(0), cfid, bytes32(0), "");
    }

    function testAttestRejectsZeroTarget() public {
        vm.expectRevert(IERC8004AdapterAttestation.AttestationTargetZero.selector);
        adapter.attest(tRating, bytes32(0), bytes32(0), hex"32");
    }

    function testConfirmRejectsZeroTarget() public {
        vm.expectRevert(IERC8004AdapterAttestation.AttestationTargetZero.selector);
        adapter.confirmAdditionalAccount(bytes32(0));
    }

    function testRevokeAcceptsZeroIdAsRecordedNoOp() public {
        vm.prank(alice);
        adapter.confirmAdditionalAccount(cfid);
        drain();
        bytes32 id = lastId();

        vm.prank(alice);
        adapter.revoke(bytes32(0));
        drain();
        assertTrue(isLive(id), "revoking the zero id touches nothing");
    }

    // ----------------------------------------------------------------
    //  Rules 1 to 4
    // ----------------------------------------------------------------

    function testCollapseDuplicateEmitsAreOneStatement() public {
        vm.startPrank(alice);
        adapter.attest(tRating, cfid, bytes32(0), hex"32");
        adapter.attest(tRating, cfid, bytes32(0), hex"32");
        drain();
        assertEq(evs[0].id, evs[1].id, "byte-identical same-block content is one id");

        adapter.revoke(evs[0].id);
        vm.stopPrank();
        drain();
        assertFalse(isLive(evs[0].id), "one revocation withdraws the statement, both copies");
        (bool has,) = currentState(alice, cfid, tRating);
        assertFalse(has);
    }

    function testVariantSeparatesWithinOneBlock() public {
        vm.startPrank(alice);
        adapter.attest(tReview, cfid, bytes32(0), "solid");
        adapter.attest(tReview, cfid, bytes32(uint256(1)), "solid");
        vm.stopPrank();
        drain();
        assertTrue(evs[0].id != evs[1].id, "variant distinguishes identical same-block statements");
    }

    function testWithdrawal() public {
        vm.prank(alice);
        adapter.confirmAdditionalAccount(cfid);
        drain();
        bytes32 id = lastId();
        vm.prank(alice);
        adapter.revoke(id);
        drain();
        assertFalse(isLive(id));
    }

    function testReactivationWithinOneBlock() public {
        vm.startPrank(alice);
        adapter.confirmAdditionalAccount(cfid);
        drain();
        bytes32 id = lastId();
        adapter.revoke(id);
        adapter.confirmAdditionalAccount(cfid);
        vm.stopPrank();
        drain();
        assertTrue(isLive(id), "attest, revoke, attest in one block reactivates the same id");
    }

    function testAttestRevokeAttestRevokeEndsWithdrawn() public {
        vm.startPrank(alice);
        adapter.confirmAdditionalAccount(cfid);
        drain();
        bytes32 id = lastId();
        adapter.revoke(id);
        adapter.confirmAdditionalAccount(cfid);
        adapter.revoke(id);
        vm.stopPrank();
        drain();
        assertFalse(isLive(id), "log order decides: the final revocation stands");
    }

    function testRevokeBeforeAttestIsInertThenAttestLands() public {
        bytes32 id = idOf(address(adapter), alice, cfid, tConfirm, bytes32(0), "");
        vm.startPrank(alice);
        adapter.revoke(id);
        adapter.confirmAdditionalAccount(cfid);
        vm.stopPrank();
        drain();
        assertTrue(isLive(id), "a revocation of a statement not yet made refers to nothing");
    }

    function testReactivationAcrossBlocksIsANewStatement() public {
        vm.prank(alice);
        adapter.confirmAdditionalAccount(cfid);
        drain();
        bytes32 firstId = lastId();
        roll(block.number + 1);
        vm.prank(alice);
        adapter.revoke(firstId);
        roll(block.number + 1);
        vm.prank(alice);
        adapter.confirmAdditionalAccount(cfid);
        drain();
        bytes32 secondId = lastId();

        assertTrue(firstId != secondId, "a later block yields a fresh id");
        assertFalse(isLive(firstId));
        assertTrue(isLive(secondId));
        (bool has,) = currentState(alice, cfid, tConfirm);
        assertTrue(has);
    }

    function testNonAttesterRevocationIsIgnored() public {
        vm.prank(alice);
        adapter.confirmAdditionalAccount(cfid);
        drain();
        bytes32 id = lastId();

        vm.prank(bob);
        adapter.revoke(id);
        drain();
        assertTrue(isLive(id), "a revocation counts only from the original attester");
    }

    function testTwoAttestersAreTwoStatements() public {
        vm.prank(alice);
        adapter.confirmAdditionalAccount(cfid);
        vm.prank(bob);
        adapter.confirmAdditionalAccount(cfid);
        drain();
        assertTrue(evs[0].id != evs[1].id, "the caller is in the identifier");

        vm.prank(alice);
        adapter.revoke(evs[0].id);
        drain();
        assertFalse(isLive(evs[0].id));
        assertTrue(isLive(evs[1].id), "statements revoke independently");
    }

    function testConfirmHelperEqualsGenericAttest() public {
        vm.startPrank(alice);
        adapter.confirmAdditionalAccount(cfid);
        adapter.attest(tConfirm, cfid, bytes32(0), "");
        vm.stopPrank();
        drain();
        assertEq(evs[0].id, evs[1].id, "the helper is the generic call with the confirmation type");
    }

    // ----------------------------------------------------------------
    //  Rule 5: state projection and resurrection
    // ----------------------------------------------------------------

    function testStateResurrection() public {
        vm.prank(alice);
        adapter.attest(tRating, cfid, bytes32(0), hex"32"); // 50
        drain();
        bytes32 fifty = lastId();
        roll(block.number + 1);
        vm.prank(alice);
        adapter.attest(tRating, cfid, bytes32(0), hex"50"); // 80
        drain();
        bytes32 eighty = lastId();

        (bool has, bytes memory data) = currentState(alice, cfid, tRating);
        assertTrue(has);
        assertEq(uint8(data[0]), 80, "latest live statement wins");

        roll(block.number + 1);
        vm.prank(alice);
        adapter.revoke(eighty);
        drain();
        (has, data) = currentState(alice, cfid, tRating);
        assertTrue(has);
        assertEq(uint8(data[0]), 50, "revoking the latest resurfaces the previous live statement");

        roll(block.number + 1);
        vm.prank(alice);
        adapter.revoke(fifty);
        drain();
        (has,) = currentState(alice, cfid, tRating);
        assertFalse(has, "no position needs every live statement revoked");
    }

    function testReEmissionMakesAStatementCurrentAgain() public {
        vm.startPrank(alice);
        adapter.attest(tRating, cfid, bytes32(0), hex"32"); // 50
        adapter.attest(tRating, cfid, bytes32(0), hex"3c"); // 60
        adapter.attest(tRating, cfid, bytes32(0), hex"32"); // 50 again, same id as the first
        vm.stopPrank();
        drain();
        (bool has, bytes memory data) = currentState(alice, cfid, tRating);
        assertTrue(has);
        assertEq(uint8(data[0]), 50, "latest emission in log order is current, reactivation included");
    }

    function testUnstarVersusRevokeAreDifferentOperations() public {
        // Unstar: star in two blocks, then attest zero. The current position is unstarred.
        vm.prank(alice);
        adapter.attest(tStar, cfid, bytes32(0), hex"01");
        roll(block.number + 1);
        vm.prank(alice);
        adapter.attest(tStar, cfid, bytes32(0), hex"01");
        roll(block.number + 1);
        vm.prank(alice);
        adapter.attest(tStar, cfid, bytes32(0), hex"00");
        drain();
        (bool has, bytes memory data) = currentState(alice, cfid, tStar);
        assertTrue(has);
        assertEq(uint8(data[0]), 0, "attesting zero is a position: unstarred");
        assertEq(starCount(cfid), 0);

        // Revoke: the same two stars from bob, then revoking only the latest. The earlier live
        // star resurfaces, so bob still counts as starring.
        vm.prank(bob);
        adapter.attest(tStar, cfid, bytes32(0), hex"01");
        drain();
        roll(block.number + 1);
        vm.prank(bob);
        adapter.attest(tStar, cfid, bytes32(0), hex"01");
        drain();
        bytes32 bobLatest = lastId();
        roll(block.number + 1);
        vm.prank(bob);
        adapter.revoke(bobLatest);
        drain();
        (has, data) = currentState(bob, cfid, tStar);
        assertTrue(has);
        assertEq(uint8(data[0]), 1, "revocation resurfaces the older live star");
        assertEq(starCount(cfid), 1, "bob still stars; alice holds an unstarred position");
    }

    // ----------------------------------------------------------------
    //  Payload rules and aggregation
    // ----------------------------------------------------------------

    function testPayloadRules() public view {
        assertTrue(validStar(hex"00"));
        assertTrue(validStar(hex"01"));
        assertFalse(validStar(hex"02"), "a star is zero or one");
        assertFalse(validStar(hex"0101"), "a star is one byte");
        assertTrue(validRating(hex"64"));
        assertFalse(validRating(hex"65"), "a rating caps at 100");
        assertFalse(validReview(""), "a review has text");
        assertTrue(validReview(bytes("fine work")));
        assertFalse(validInteraction(new bytes(32)), "an interaction is at least 33 bytes");
        assertTrue(validInteraction(new bytes(33)));
        bytes memory overScore = new bytes(33);
        overScore[0] = 0x65;
        assertFalse(validInteraction(overScore), "an interaction score caps at 100");
    }

    function testRatingAggregationExcludesInvalidPayloads() public {
        vm.prank(alice);
        adapter.attest(tRating, cfid, bytes32(0), hex"50"); // 80
        vm.prank(bob);
        adapter.attest(tRating, cfid, bytes32(0), hex"64"); // 100
        vm.prank(carol);
        adapter.attest(tRating, cfid, bytes32(0), hex"96"); // 150, invalid at read
        drain();
        assertEq(ratingAverage(cfid, new address[](0)), 90, "the invalid rating never enters the average");
    }

    function testRatingAggregationExcludesDependentAttesters() public {
        vm.prank(alice);
        adapter.attest(tRating, cfid, bytes32(0), hex"3c"); // 60
        vm.prank(bob);
        adapter.attest(tRating, cfid, bytes32(0), hex"64"); // 100, but bob is the subject's controller
        drain();
        address[] memory dependents = new address[](1);
        dependents[0] = bob;
        assertEq(ratingAverage(cfid, dependents), 60, "self-review is excluded at aggregation");
        assertEq(ratingAverage(cfid, new address[](0)), 80, "the exclusion is the consumer's choice, applied here");
    }

    function testStarCountCountsLatestLivePositions() public {
        vm.prank(alice);
        adapter.attest(tStar, cfid, bytes32(0), hex"01");
        vm.prank(bob);
        adapter.attest(tStar, cfid, bytes32(0), hex"01");
        vm.prank(carol);
        adapter.attest(tStar, cfid, bytes32(0), hex"00");
        drain();
        assertEq(starCount(cfid), 2);

        roll(block.number + 1);
        vm.prank(carol);
        adapter.attest(tStar, cfid, bytes32(0), hex"01");
        drain();
        assertEq(starCount(cfid), 3);
    }
}
