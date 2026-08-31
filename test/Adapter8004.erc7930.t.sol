// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Test, Vm} from "forge-std/Test.sol";
import {ERC1967Proxy} from "@openzeppelin/contracts/proxy/ERC1967/ERC1967Proxy.sol";
import {InteroperableAddress} from "@openzeppelin/contracts/utils/draft-InteroperableAddress.sol";
import {Adapter8004} from "../src/Adapter8004.sol";
import {IERC8217} from "../src/interfaces/IERC8217.sol";
import {MockIdentityRegistry} from "./mocks/MockIdentityRegistry.sol";
import {MockERC721} from "./mocks/MockERC721.sol";

/// @notice The word-aligned encoder that `Adapter8004` carried before it adopted OpenZeppelin's
/// `InteroperableAddress`, kept verbatim as a second frozen reference.
///
/// **Do not delete, and do not edit it to match anything.** When production used this code, OZ was
/// the independent oracle. Production now uses OZ, so the roles inverted and this is the oracle:
/// together with `ReferenceErc7930` it is what proves OZ's output is still the encoding every
/// identity this contract has ever issued was built from. Two implementations written here, one
/// written by OpenZeppelin, all three agreeing, is the whole safety argument. Deleting either
/// reference collapses that to a two-way agreement; deleting both leaves the dependency checked only
/// against itself.
library WordAlignedErc7930 {
    error InvalidChainId();

    function encode(uint256 chainId, address account, bool includeAddress)
        internal
        pure
        returns (bytes memory identifier)
    {
        if (chainId == 0) revert InvalidChainId();

        uint256 referenceLength;
        uint256 remaining = chainId;
        while (remaining != 0) {
            ++referenceLength;
            remaining >>= 8;
        }

        uint256 length = referenceLength + 6 + (includeAddress ? 20 : 0);
        identifier = new bytes(length);

        // Fast path: the whole envelope fits in one 32-byte word, so it is one MSTORE instead of up
        // to twenty-six bounds-checked byte writes. `length <= 32` is the exact condition for both
        // shapes at once: with an address that is `referenceLength <= 6`, so chain ids below 2^48;
        // without one it is `referenceLength <= 26`. Every chain in existence is far inside both.
        //
        // Byte `i` of the envelope occupies bits `248 - 8i` upward, which is where each shift below
        // comes from. The pieces cover disjoint byte ranges, so OR-ing them is assembly, not
        // arithmetic. Bytes 0, 2 and 3 stay zero because nothing writes them, and so does the
        // trailing AddressLength byte when `includeAddress` is false.
        if (length <= 32) {
            uint256 word = (uint256(1) << 240) // version 0x0001 at bytes 0-1; ChainType 0x0000 follows
                | (referenceLength << 216) // ReferenceLength at byte 4
                | (chainId << (216 - 8 * referenceLength)); // reference at bytes 5..4+L
            if (includeAddress) {
                word |= (uint256(0x14) << (208 - 8 * referenceLength)) // AddressLength at byte 5+L
                    | (uint256(uint160(account)) << (48 - 8 * referenceLength)); // address at bytes 6+L..25+L
            }
            assembly ("memory-safe") {
                // `new bytes` rounds its data region up to a whole word and `length` is at least 7
                // here, so the data region is exactly 32 bytes and this store stays inside it.
                mstore(add(identifier, 32), word)
            }
            return identifier;
        }

        // Fallback for chain ids too large to fit the envelope in one word. Unreachable on any real
        // chain, kept so the encoder stays total. this file fuzzes it against the
        // fast path, because a divergence here would silently re-key identities rather than revert.
        identifier[1] = 0x01;
        identifier[4] = bytes1(uint8(referenceLength));
        for (uint256 i; i < referenceLength; ++i) {
            identifier[5 + referenceLength - 1 - i] = bytes1(uint8(chainId >> (i * 8)));
        }
        if (includeAddress) {
            identifier[5 + referenceLength] = 0x14;
            bytes20 rawAddress = bytes20(account);
            for (uint256 i; i < 20; ++i) {
                identifier[6 + referenceLength + i] = rawAddress[i];
            }
        }
        // Otherwise the final byte remains zero: ERC-7930 AddressLength == 0.
    }
}

/// @notice The byte-at-a-time ERC-7930 encoder this contract carried before `0.0.17`, kept verbatim
/// as a frozen oracle. It is no longer an implementation of anything; production takes the encoding
/// from OpenZeppelin's `InteroperableAddress`.
///
/// **Do not delete, and do not "fix" it to match production.** Its whole value is that it was
/// written independently of the code it now checks. Together with `WordAlignedErc7930` it is what
/// proves OpenZeppelin's output is still the exact encoding every identity this contract has issued
/// was built from; deleting either one collapses a three-way agreement into a two-way one, and
/// deleting both leaves the dependency checked only against itself, which proves nothing.
///
/// This encoding is the preimage of every UBID and every
/// `attestationId`. A one-byte divergence would silently re-key identities rather than revert. If
/// this ever disagrees with production, the question is which one moved, and every existing identity
/// depends on the answer.
library ReferenceErc7930 {
    error InvalidChainId();

    function encode(uint256 chainId, address account, bool includeAddress)
        internal
        pure
        returns (bytes memory identifier)
    {
        if (chainId == 0) revert InvalidChainId();

        uint256 referenceLength;
        uint256 remaining = chainId;
        while (remaining != 0) {
            ++referenceLength;
            remaining >>= 8;
        }

        identifier = new bytes(referenceLength + 6 + (includeAddress ? 20 : 0));
        identifier[1] = 0x01;
        identifier[4] = bytes1(uint8(referenceLength));
        for (uint256 i; i < referenceLength; ++i) {
            identifier[5 + referenceLength - 1 - i] = bytes1(uint8(chainId >> (i * 8)));
        }
        if (includeAddress) {
            identifier[5 + referenceLength] = 0x14;
            bytes20 rawAddress = bytes20(account);
            for (uint256 i; i < 20; ++i) {
                identifier[6 + referenceLength + i] = rawAddress[i];
            }
        }
    }
}

contract Adapter8004HashHarness is Adapter8004 {
    constructor(address registry_) Adapter8004(registry_) {}

    function chainIdentifierFor(uint256 chainId) external pure returns (bytes memory) {
        return _chainIdentifierFor(chainId);
    }

    function interoperableAddressFor(uint256 chainId, address account) external pure returns (bytes memory) {
        return _interoperableAddressFor(chainId, account);
    }

    function bindingHashFrom(
        bytes memory adapterInteroperableAddress,
        IERC8217.Standard standard,
        address boundAddress,
        uint256 tokenId
    ) external pure returns (bytes32) {
        return _bindingHashFrom(adapterInteroperableAddress, standard, boundAddress, tokenId);
    }

    /// @dev Paints a sentinel into the free memory the encoder must not reach, runs the encoder in
    /// the SAME frame, and reports whether the sentinel survived. Points at the frozen
    /// `WordAlignedErc7930` reference rather than production: production delegates to OpenZeppelin
    /// now, so the hand-written `mstore` this guards lives only in the reference, and OZ's own
    /// allocation pattern is different enough that the sentinel would land inside its intermediate
    /// buffers. An external call would prove
    /// nothing here, because the callee's memory is a separate frame and the returned bytes are
    /// re-decoded into the caller's.
    ///
    /// The sentinel goes immediately past where the array will end. `new bytes(n)` takes one word of
    /// length plus `ceil(n/32)` words of data, so the first byte the encoder must never touch is
    /// `free + 32 + ceil(n/32) * 32`. Placing it at a fixed offset instead would sit inside the
    /// allocation for any `n` above 32 and report a false failure, which is exactly what a first
    /// draft of this did.
    function encodeWithMemoryGuard(uint256 chainId, address account, bool includeAddress)
        external
        pure
        returns (bytes memory encoded, bool guardIntact)
    {
        uint256 referenceLength;
        uint256 remaining = chainId;
        while (remaining != 0) {
            ++referenceLength;
            remaining >>= 8;
        }
        uint256 allocated = 32 + ((referenceLength + 6 + (includeAddress ? 20 : 0) + 31) / 32) * 32;

        bytes32 sentinel = keccak256("erc7930 memory guard");
        uint256 free;
        assembly ("memory-safe") {
            free := mload(0x40)
            mstore(add(free, allocated), sentinel)
            mstore(add(free, add(allocated, 0x20)), sentinel)
        }
        encoded = WordAlignedErc7930.encode(chainId, account, includeAddress);
        assembly ("memory-safe") {
            guardIntact :=
                and(eq(mload(add(free, allocated)), sentinel), eq(mload(add(free, add(allocated, 0x20))), sentinel))
        }
    }
}

contract Adapter8004ERC7930Test is Test {
    Adapter8004 internal adapter;
    Adapter8004HashHarness internal harness;
    address internal constant VECTOR_ADAPTER = 0x1111111111111111111111111111111111111111;
    address internal constant VECTOR_TOKEN = 0x2222222222222222222222222222222222222222;
    address internal alice = makeAddr("alice");

    function setUp() external {
        MockIdentityRegistry registry = new MockIdentityRegistry();
        Adapter8004 implementation = new Adapter8004(address(registry));
        adapter = Adapter8004(
            address(new ERC1967Proxy(address(implementation), abi.encodeCall(Adapter8004.initialize, (address(this)))))
        );
        harness = new Adapter8004HashHarness(address(registry));
    }

    /// @dev Vectors for the four-component preimage. Each value was computed outside the contract as
    /// `keccak256(abi.encode(adapterAddress, uint8(standard), token, 42))` and
    /// cross-checked against the implementation, so this pins the encoding rather than restating it.
    /// The first group varies the chain envelope at a fixed standard; the second varies the standard
    /// at a fixed envelope, which is what pins the standard's position and width in the preimage.
    function testPublishedCrossNamespaceVectors() external view {
        _assertVector(
            hex"000100000101141111111111111111111111111111111111111111",
            IERC8217.Standard.ERC721,
            0x8493ab3adb4f5e8753ee3fe05e377bffe213753e1b4155035fec1705d94615f9
        );
        _assertVector(
            hex"00010000022105141111111111111111111111111111111111111111",
            IERC8217.Standard.ERC721,
            0x7caa0ee523b99d37d2073eef394484c7b7a29c6d8848a531641c6ad59ac675a3
        );
        _assertVector(
            hex"0001000003aa36a7141111111111111111111111111111111111111111",
            IERC8217.Standard.ERC721,
            0xc753b3b34ad2466a045e80c94ee26ac3a47054333762cb429ae7d8f17e12ac0f
        );
        _assertVector(
            hex"000100022045296998a6f8e2a784db5d9f95e18fc23f70441a1039446801089879b08c7ef0141111111111111111111111111111111111111111",
            IERC8217.Standard.ERC721,
            0x0f9c133f3a5c0ca7b20f94b3b57e5ac97f214b004e73fa71b1d6a2075deaa3cc
        );
    }

    /// @dev One chain envelope, one `(boundAddress, tokenId)`, four standards, four pinned and
    /// distinct identities. These are the vectors that would move if the enum were ever renumbered,
    /// which is why the enum's numbering is identity-critical and append-only.
    function testPublishedPerStandardVectors() external view {
        bytes memory mainnetAdapter = hex"000100000101141111111111111111111111111111111111111111";
        _assertVector(
            mainnetAdapter,
            IERC8217.Standard.ERC721,
            0x8493ab3adb4f5e8753ee3fe05e377bffe213753e1b4155035fec1705d94615f9
        );
        _assertVector(
            mainnetAdapter,
            IERC8217.Standard.ERC1155,
            0x14cfea274e2d2b7367bffaa93dbfdda489fd4fbed711f949a321a75789fdec44
        );
        _assertVector(
            mainnetAdapter,
            IERC8217.Standard.ACCOUNT,
            0x3d8eaa0572359ac90e967f6acdd9106d9c026f3c35872baa01de02f78a997c69
        );
        _assertVector(
            mainnetAdapter,
            IERC8217.Standard.CONTRACT_OWNABLE,
            0x5bdc0e660d093b00b2552ec33586abf07d3b1572decf08bdd5563fa8c3180787
        );
    }

    /// @dev Both superseded schemes, frozen as literals so each cutover is asserted against a copy of
    /// the old formula rather than against whatever the contract computes now. Scheme A is the
    /// pre-ERC-7930 preimage still running on every live proxy. Scheme B is the ERC-7930 preimage
    /// without the standard, which no proxy ever ran: it existed only in `0.0.14`-`0.0.16` source, so
    /// adding the standard rides the cutover A already forces at no additional on-chain cost.
    function testSupersededVectorsNoLongerMatch() external view {
        bytes memory mainnetAdapter = hex"000100000101141111111111111111111111111111111111111111";

        bytes32 schemeA = keccak256(
            abi.encode(uint256(1), address(0x1111111111111111111111111111111111111111), VECTOR_TOKEN, uint256(42))
        );
        assertEq(schemeA, 0x44d822742b23b1e38c7ba4e0a007f2eb44aaa600d7808dd683ad24084085756d, "frozen scheme A vector");

        bytes32 schemeB = keccak256(abi.encode(mainnetAdapter, VECTOR_TOKEN, uint256(42), bytes32(0)));
        assertEq(schemeB, 0xfd3ae85086b1e0d0a39318f3f7458b07a86becf50434a9b8b70b9426528388bf, "frozen scheme B vector");

        // Scheme C: the five-component preimage with the reserved `extraData`, superseded at
        // `0.0.17` when the discriminator was removed. Also never deployed.
        bytes32 schemeC = keccak256(abi.encode(mainnetAdapter, uint8(0), VECTOR_TOKEN, uint256(42), bytes32(0)));
        assertEq(schemeC, 0xefa93cfacbc3a08981c5725059a0a35e463f4063313da93f44d85cc02f457a0b, "frozen scheme C vector");

        for (uint8 s; s <= uint8(type(IERC8217.Standard).max); ++s) {
            bytes32 current = harness.bindingHashFrom(mainnetAdapter, IERC8217.Standard(s), VECTOR_TOKEN, 42);
            assertTrue(current != schemeA, "must not collide with the live pre-ERC-7930 scheme");
            assertTrue(current != schemeB, "must not collide with the standard-less ERC-7930 scheme");
            assertTrue(current != schemeC, "must not collide with the extraData scheme");
        }
    }

    /// @dev The aliasing this version dissolves. Before the standard entered the preimage, one
    /// `(boundAddress, tokenId)` claimed under two standards collapsed onto a single identity, so a
    /// claimant who passed one authority probe shared a coordinate, and would share any reputation
    /// accumulated against it, with a claimant who passed a different one. Every standard must now
    /// produce a distinct identity for the same pair. The worked example is the contract that is also
    /// an ERC-721 collection claiming `(X, 0)` as `ERC721`, `ACCOUNT` and `CONTRACT_OWNABLE`.
    function testEveryStandardIsADistinctIdentityForOnePair() external view {
        uint8 max = uint8(type(IERC8217.Standard).max);
        bytes32[] memory seen = new bytes32[](uint256(max) + 1);

        for (uint8 i; i <= max; ++i) {
            seen[i] = harness.hashBinding(IERC8217.Standard(i), VECTOR_TOKEN, 0);
            for (uint8 j; j < i; ++j) {
                assertTrue(seen[i] != seen[j], "two standards must never alias onto one identity");
            }
        }
    }

    function testFuzzStandardIsLoadBearingInThePreimage(address boundAddress, uint256 tokenId, uint8 a, uint8 b)
        external
        view
    {
        uint8 max = uint8(type(IERC8217.Standard).max);
        a = uint8(bound(a, 0, max));
        b = uint8(bound(b, 0, max));
        vm.assume(a != b);

        assertTrue(
            harness.hashBinding(IERC8217.Standard(a), boundAddress, tokenId)
                != harness.hashBinding(IERC8217.Standard(b), boundAddress, tokenId)
        );
    }

    // ----------------------------------------------------------------
    //  Word-aligned encoder vs the reference, both shapes
    // ----------------------------------------------------------------
    //  The rewrite at `0.0.17` replaced up to twenty-six bounds-checked byte writes with one MSTORE
    //  for every envelope that fits in a word. These are the tests that make that safe: the encoding
    //  is the preimage of every identity this contract derives, so a divergence re-keys silently.

    /// @dev The reference length is chosen explicitly rather than left to the fuzzer. A raw
    /// `uint256` is almost always 32 bytes long, so an unconstrained fuzz would spend nearly every
    /// run comparing the fallback against itself and prove nothing about the fast path. Foundry's
    /// small-value bias does reach it, but not by a margin worth trusting for the property that keeps
    /// identities stable. Picking the length covers all 32 of them in proportion instead.
    function testFuzzWordAlignedMatchesReferenceWithAddress(uint256 seed, uint8 lengthPick, address account)
        external
        view
    {
        uint256 l = bound(lengthPick, 1, 32);
        uint256 chainId = _chainIdOfLength(seed, l);

        bytes memory actual = harness.interoperableAddressFor(chainId, account);
        assertEq(actual.length, l + 26, "premise: the fuzz built the reference length it intended");
        assertEq(actual, ReferenceErc7930.encode(chainId, account, true), "must match the reference encoder");
    }

    function testFuzzWordAlignedMatchesReferenceChainIdentifierOnly(uint256 seed, uint8 lengthPick) external view {
        uint256 l = bound(lengthPick, 1, 32);
        uint256 chainId = _chainIdOfLength(seed, l);

        bytes memory actual = harness.chainIdentifierFor(chainId);
        assertEq(actual.length, l + 6, "premise: the fuzz built the reference length it intended");
        assertEq(actual, ReferenceErc7930.encode(chainId, address(0), false), "must match the reference encoder");
    }

    /// @dev Builds a chain id whose shortest big-endian encoding is exactly `l` bytes, by masking the
    /// seed to `l` bytes and forcing the top bit of the top byte so it cannot be shorter.
    function _chainIdOfLength(uint256 seed, uint256 l) private pure returns (uint256) {
        uint256 topBit = uint256(1) << (8 * l - 1);
        if (l == 32) return seed | topBit;
        return (seed & ((uint256(1) << (8 * l)) - 1)) | topBit;
    }

    /// @dev The handoff, pinned from both sides. With an address the envelope is `26 + L` bytes, so
    /// the fast path covers `L <= 6` and `L == 7` is the first fallback case. Without an address it
    /// is `6 + L`, so the same `L` values are all comfortably inside the fast path — which is exactly
    /// why the two shapes need separate coverage rather than one loop.
    function testHandoffBoundaryIsIdenticalOnBothSides() external view {
        // Smallest and largest chain id at each reference length 1 through 7.
        uint256[14] memory ids = [
            uint256(0x01),
            0xFF,
            0x0100,
            0xFFFF,
            0x010000,
            0xFFFFFF,
            0x01000000,
            0xFFFFFFFF,
            0x0100000000,
            0xFFFFFFFFFF,
            0x010000000000,
            0xFFFFFFFFFFFF,
            0x01000000000000,
            0xFFFFFFFFFFFFFF
        ];
        address account = 0x1234567890AbcdEF1234567890aBcdef12345678;

        for (uint256 i; i < ids.length; ++i) {
            uint256 l = i / 2 + 1;
            bytes memory withAddress = harness.interoperableAddressFor(ids[i], account);
            bytes memory bare = harness.chainIdentifierFor(ids[i]);

            assertEq(withAddress, ReferenceErc7930.encode(ids[i], account, true), "with address");
            assertEq(bare, ReferenceErc7930.encode(ids[i], address(0), false), "chain identifier only");
            assertEq(withAddress.length, l + 26, "length with address");
            assertEq(bare.length, l + 6, "length without address");
            assertEq(uint8(withAddress[4]), l, "reference length byte");
        }
    }

    /// @dev The fallback is not dead code that never runs: `L == 7` genuinely takes it for the
    /// address shape while the same chain id stays on the fast path for the bare shape. Asserting the
    /// lengths straddle 32 is what proves the two branches were both exercised above.
    function testFallbackAndFastPathAreBothReachedAtLengthSeven() external view {
        uint256 chainId = 0x01000000000000; // 2^48, the first chain id needing seven reference bytes
        assertEq(harness.interoperableAddressFor(chainId, VECTOR_TOKEN).length, 33, "address shape takes the fallback");
        assertEq(harness.chainIdentifierFor(chainId).length, 13, "bare shape stays on the fast path");

        assertEq(
            harness.interoperableAddressFor(chainId, VECTOR_TOKEN), ReferenceErc7930.encode(chainId, VECTOR_TOKEN, true)
        );
        assertEq(harness.chainIdentifierFor(chainId), ReferenceErc7930.encode(chainId, address(0), false));
    }

    /// @dev The bare shape's own handoff, at `L == 27`, far past any real chain but the boundary the
    /// second branch condition actually turns on.
    function testChainIdentifierHandoffAtTwentySeven() external view {
        uint256 justInside = (uint256(1) << 208) - 1; // 26 reference bytes
        uint256 justOutside = uint256(1) << 208; // 27 reference bytes

        assertEq(harness.chainIdentifierFor(justInside).length, 32, "26 bytes still fits one word");
        assertEq(harness.chainIdentifierFor(justOutside).length, 33, "27 bytes needs the fallback");

        assertEq(harness.chainIdentifierFor(justInside), ReferenceErc7930.encode(justInside, address(0), false));
        assertEq(harness.chainIdentifierFor(justOutside), ReferenceErc7930.encode(justOutside, address(0), false));
        assertEq(
            harness.interoperableAddressFor(justOutside, VECTOR_TOKEN),
            ReferenceErc7930.encode(justOutside, VECTOR_TOKEN, true)
        );
    }

    /// @dev The frozen reference's single MSTORE must not write past the array's data region.
    /// Checked inside the encoder's own memory frame, with a sentinel painted into the words the allocation must not
    /// reach; an external call could not see this, because the callee's memory is a separate frame.
    function testFuzzReferenceFastPathDoesNotWritePastTheAllocation(uint256 seed, uint8 lengthPick, address account)
        external
        view
    {
        uint256 l = bound(lengthPick, 1, 32);
        uint256 chainId = _chainIdOfLength(seed, l);

        (bytes memory withAddress, bool guardA) = harness.encodeWithMemoryGuard(chainId, account, true);
        assertTrue(guardA, "address shape wrote past its allocation");
        assertEq(withAddress, ReferenceErc7930.encode(chainId, account, true));
        assertEq(withAddress, harness.interoperableAddressFor(chainId, account), "and still matches production");

        (bytes memory bare, bool guardB) = harness.encodeWithMemoryGuard(chainId, address(0), false);
        assertTrue(guardB, "chain-identifier shape wrote past its allocation");
        assertEq(bare, ReferenceErc7930.encode(chainId, address(0), false));
    }

    function testLocalKnownChainIdentifiers() external {
        vm.chainId(1);
        assertEq(adapter.chainIdentifier(), hex"00010000010100");
        vm.chainId(8453);
        assertEq(adapter.chainIdentifier(), hex"0001000002210500");
        vm.chainId(11155111);
        assertEq(adapter.chainIdentifier(), hex"0001000003aa36a700");
    }

    function testLocalKnownInteroperableAddresses() external {
        vm.chainId(1);
        assertEq(
            adapter.interoperableAddress(VECTOR_ADAPTER), hex"000100000101141111111111111111111111111111111111111111"
        );
        vm.chainId(8453);
        assertEq(
            adapter.interoperableAddress(VECTOR_TOKEN), hex"00010000022105142222222222222222222222222222222222222222"
        );
    }

    function testFuzzMinimalBigEndianIdentifier(uint256 chainId) external {
        vm.assume(chainId != 0);
        bytes memory identifier = harness.chainIdentifierFor(chainId);
        uint256 referenceLength = identifier.length - 6;
        assertGe(referenceLength, 1);
        assertLe(referenceLength, 32);
        assertEq(uint8(identifier[0]), 0);
        assertEq(uint8(identifier[1]), 1);
        assertEq(uint8(identifier[2]), 0);
        assertEq(uint8(identifier[3]), 0);
        assertEq(uint8(identifier[4]), referenceLength);
        assertTrue(identifier[5] != 0);
        assertEq(uint8(identifier[identifier.length - 1]), 0);

        uint256 decoded;
        for (uint256 i; i < referenceLength; ++i) {
            decoded = (decoded << 8) | uint8(identifier[5 + i]);
        }
        assertEq(decoded, chainId);
    }

    function testFuzzInteroperableAddressAppendsLengthAndRawAddress(uint256 chainId, address account) external {
        vm.assume(chainId != 0);
        bytes memory identifier = harness.chainIdentifierFor(chainId);
        bytes memory interoperable = harness.interoperableAddressFor(chainId, account);
        assertEq(interoperable.length, identifier.length + 20);
        for (uint256 i; i < identifier.length - 1; ++i) {
            assertEq(uint8(interoperable[i]), uint8(identifier[i]));
        }
        assertEq(uint8(interoperable[identifier.length - 1]), 20);
        bytes20 rawAddress = bytes20(account);
        for (uint256 i; i < 20; ++i) {
            assertEq(uint8(interoperable[identifier.length + i]), uint8(rawAddress[i]));
        }
    }

    function testChainIdZeroRejected() external {
        vm.chainId(0);
        vm.expectRevert(Adapter8004.InvalidChainId.selector);
        adapter.chainIdentifier();
    }

    function testCanonicalFormulaAndNegativeEncodings() external view {
        address token = address(0xCAFE);
        uint256 tokenId = 99;
        uint8 standard = uint8(IERC8217.Standard.CONTRACT_OWNABLE);
        bytes memory identifier = adapter.chainIdentifier();
        bytes memory adapterAddress = adapter.interoperableAddress(address(adapter));
        bytes memory tokenAddress = adapter.interoperableAddress(token);
        bytes32 actual = adapter.hashBinding(IERC8217.Standard.CONTRACT_OWNABLE, token, tokenId);

        assertEq(actual, keccak256(abi.encode(adapterAddress, standard, token, tokenId)), "canonical");
        // The four components are exactly the adapter envelope plus the stored binding. Appending a
        // fifth field, as the superseded `extraData` scheme did, must produce a different identity.
        assertTrue(actual != keccak256(abi.encode(adapterAddress, standard, token, tokenId, bytes32(0))));
        assertTrue(actual != keccak256(abi.encode(bytes32(0), adapterAddress, standard, token, tokenId)));
        // The standard must be a real preimage field in its own position: dropping it, moving it
        // after the coordinates, or changing its value must each produce a different identity.
        assertTrue(actual != keccak256(abi.encode(adapterAddress, token, tokenId)));
        assertTrue(actual != keccak256(abi.encode(adapterAddress, token, tokenId, standard)));
        assertTrue(actual != keccak256(abi.encode(adapterAddress, uint8(standard + 1), token, tokenId)));
        assertTrue(actual != keccak256(abi.encode(adapterAddress, uint8(standard - 1), token, tokenId)));
        assertTrue(actual != keccak256(abi.encode(block.chainid, address(adapter), standard, token, tokenId)));
        assertTrue(actual != keccak256(abi.encode(identifier, address(adapter), standard, token, tokenId)));
        assertTrue(actual != keccak256(abi.encode(adapterAddress, standard, tokenAddress, tokenId)));
        assertTrue(actual != keccak256(abi.encode(address(adapter), standard, token, tokenId)));
        assertTrue(actual != keccak256(abi.encodePacked(adapterAddress, standard, token, tokenId)));
        assertTrue(actual != keccak256(abi.encode(keccak256(adapterAddress), standard, token, tokenId)));
    }

    function testEachDomainCoordinateChangesHash() external view {
        bytes memory adapterAddress = hex"000100000101141111111111111111111111111111111111111111";
        bytes memory otherTypeAdapter = hex"000100010101141111111111111111111111111111111111111111";
        bytes memory otherReferenceAdapter = hex"000100000102141111111111111111111111111111111111111111";
        bytes memory otherAdapter = hex"000100000101143333333333333333333333333333333333333333";
        IERC8217.Standard s = IERC8217.Standard.ERC721;
        bytes32 base = harness.bindingHashFrom(adapterAddress, s, VECTOR_TOKEN, 42);
        assertTrue(base != harness.bindingHashFrom(otherTypeAdapter, s, VECTOR_TOKEN, 42));
        assertTrue(base != harness.bindingHashFrom(otherReferenceAdapter, s, VECTOR_TOKEN, 42));
        assertTrue(base != harness.bindingHashFrom(otherAdapter, s, VECTOR_TOKEN, 42));
        assertTrue(base != harness.bindingHashFrom(adapterAddress, s, address(0x4444), 42));
        assertTrue(base != harness.bindingHashFrom(adapterAddress, s, VECTOR_TOKEN, 43));
        assertTrue(base != harness.bindingHashFrom(adapterAddress, IERC8217.Standard.ERC1155, VECTOR_TOKEN, 42));
    }

    function _assertVector(bytes memory adapterAddress, IERC8217.Standard standard, bytes32 expected)
        internal
        view
    {
        assertEq(harness.bindingHashFrom(adapterAddress, standard, VECTOR_TOKEN, 42), expected);
    }

    // ----------------------------------------------------------------
    //  Differential against OpenZeppelin, and against the ERC-7930 spec
    // ----------------------------------------------------------------
    //  `ReferenceErc7930` above proves the word-aligned rewrite is faithful to the code it replaced.
    //  It cannot prove that code ever read ERC-7930 correctly: if the first implementation misread
    //  the spec, both agree and both are wrong, and every identity this contract issues is wrong the
    //  same way. Self-consistency is not correctness. These tests answer the other question, against
    //  an independent implementation by different authors from the same spec.
    //
    //  OpenZeppelin's library is used nowhere in production and deliberately so: the encoding is the
    //  identity preimage, so taking it from a dependency would mean a routine bump could re-key every
    //  identity ever emitted. It stays a test-only oracle. If these ever fail the question is not
    //  which implementation to change — it is whether ERC-7930 moved, and every existing identity
    //  depends on the answer. Do not delete them as unused, and do not resolve a failure by switching
    //  production to the library.

    /// @dev The three EVM reference examples from the ERC-7930 text, pinned as exact bytes. These are
    /// the strongest check available, because they come from the spec authors rather than from any
    /// implementation. OpenZeppelin's own test suite carries the same examples, but as checksummed
    /// human-readable names decoded by a JavaScript library rather than as literals, so the bytes are
    /// written out here. Each is asserted against our encoder AND against OpenZeppelin's, so a
    /// mistake in transcribing the literal fails rather than silently agreeing with us.
    function testErc7930SpecReferenceExamples() external view {
        address vitalik = 0xd8dA6BF26964aF9D7eEd9e03E53415D37aA96045;

        // Example 1: Ethereum mainnet address. `0xd8dA…6045@eip155:1`
        bytes memory example1 = hex"00010000010114d8da6bf26964af9d7eed9e03e53415d37aa96045";
        assertEq(harness.interoperableAddressFor(1, vitalik), example1, "spec example 1");
        assertEq(InteroperableAddress.formatEvmV1(1, vitalik), example1, "spec example 1, OZ agrees");

        // Example 5: Arbitrum One address. `0xd8dA…6045@eip155:42161`, reference 0xA4B1.
        bytes memory example5 = hex"0001000002a4b114d8da6bf26964af9d7eed9e03e53415d37aa96045";
        assertEq(harness.interoperableAddressFor(42161, vitalik), example5, "spec example 5");
        assertEq(InteroperableAddress.formatEvmV1(42161, vitalik), example5, "spec example 5, OZ agrees");

        // Example 6: Ethereum mainnet, no address. `@eip155:1`. This is the shape whose trailing
        // AddressLength byte was the obvious candidate for a divergence; the spec, OpenZeppelin and
        // this contract all carry the explicit zero.
        bytes memory example6 = hex"00010000010100";
        assertEq(harness.chainIdentifierFor(1), example6, "spec example 6");
        assertEq(InteroperableAddress.formatEvmV1(1), example6, "spec example 6, OZ agrees");
    }

    /// @dev Reference length picked explicitly rather than left to the fuzzer, for the same reason as
    /// the `ReferenceErc7930` fuzz above: a raw `uint256` is almost always 32 bytes long, so an
    /// unconstrained fuzz would spend nearly every run on one length and leave the short references
    /// every real chain actually uses barely sampled.
    function testFuzzOpenZeppelinDifferentialWithAddress(uint256 seed, uint8 lengthPick, address account)
        external
        view
    {
        uint256 l = bound(lengthPick, 1, 32);
        uint256 chainId = _chainIdOfLength(seed, l);

        bytes memory ours = harness.interoperableAddressFor(chainId, account);
        assertEq(ours.length, l + 26, "premise: the fuzz built the reference length it intended");
        assertEq(ours, InteroperableAddress.formatEvmV1(chainId, account), "must match OpenZeppelin");
    }

    function testFuzzOpenZeppelinDifferentialChainIdentifierOnly(uint256 seed, uint8 lengthPick) external view {
        uint256 l = bound(lengthPick, 1, 32);
        uint256 chainId = _chainIdOfLength(seed, l);

        bytes memory ours = harness.chainIdentifierFor(chainId);
        assertEq(ours.length, l + 6, "premise: the fuzz built the reference length it intended");
        assertEq(ours, InteroperableAddress.formatEvmV1(chainId), "must match OpenZeppelin");
    }

    /// @dev The chain ids that matter and the two handoffs, held against OpenZeppelin on both shapes.
    /// `L == 6/7` is where the address shape crosses from the single-word fast path to the fallback;
    /// `L == 26/27` is where the bare shape does. A divergence that only appeared on one side of a
    /// branch is exactly what a uniform fuzz would be least likely to surface.
    function testOpenZeppelinDifferentialAtRealChainIdsAndHandoffs() external view {
        uint256[9] memory ids = [
            uint256(1), // Ethereum
            8453, // Base
            11155111, // Sepolia
            42161, // Arbitrum One
            0xFFFFFFFFFFFF, // L == 6, last of the address-shape fast path
            0x01000000000000, // L == 7, first of the address-shape fallback
            (uint256(1) << 208) - 1, // L == 26, last of the bare-shape fast path
            uint256(1) << 208, // L == 27, first of the bare-shape fallback
            type(uint256).max // L == 32, both shapes on the fallback
        ];
        address account = 0x1234567890AbcdEF1234567890aBcdef12345678;

        for (uint256 i; i < ids.length; ++i) {
            assertEq(
                harness.interoperableAddressFor(ids[i], account),
                InteroperableAddress.formatEvmV1(ids[i], account),
                "address shape"
            );
            assertEq(harness.chainIdentifierFor(ids[i]), InteroperableAddress.formatEvmV1(ids[i]), "bare shape");
        }
    }

    /// @dev The check that matters most in practice: an integrator holding one of our identifiers
    /// will run a parser over it, and OpenZeppelin's is the one they are most likely to reach for.
    /// Encoding agreement is necessary but not sufficient — this asserts the value survives the round
    /// trip and comes back as the chain id and address that went in.
    function testFuzzRoundTripThroughOpenZeppelinParser(uint256 seed, uint8 lengthPick, address account)
        external
        view
    {
        uint256 l = bound(lengthPick, 1, 32);
        uint256 chainId = _chainIdOfLength(seed, l);

        (uint256 parsedChainId, address parsedAccount) =
            InteroperableAddress.parseEvmV1(harness.interoperableAddressFor(chainId, account));
        assertEq(parsedChainId, chainId, "chain id survives the round trip");
        assertEq(parsedAccount, account, "address survives the round trip");

        // The bare shape parses too, as an EVM chain with no address, which is what a consumer
        // distinguishing a chain identifier from a full address will rely on.
        (bool ok, uint256 bareChainId, address bareAccount) =
            InteroperableAddress.tryParseEvmV1(harness.chainIdentifierFor(chainId));
        assertTrue(ok, "chain identifier is a valid ERC-7930 value");
        assertEq(bareChainId, chainId, "chain id survives the round trip");
        assertEq(bareAccount, address(0), "and carries no address");
    }

    /// @dev The identifiers this contract actually issues are built over the adapter's own envelope,
    /// so the round trip is asserted on that too rather than only on synthetic inputs.
    function testLiveAdapterEnvelopeRoundTripsThroughOpenZeppelin() external view {
        (uint256 chainId, address parsed) =
            InteroperableAddress.parseEvmV1(adapter.interoperableAddress(address(adapter)));
        assertEq(chainId, block.chainid);
        assertEq(parsed, address(adapter));
    }

    /// @dev The one place the two implementations deliberately disagree, recorded so it is not later
    /// mistaken for drift. A chain id of zero identifies no chain and `block.chainid` never returns
    /// it, so the local encoder rejects it outright rather than producing an identity nothing could
    /// ever own. OpenZeppelin encodes it. The fuzz case above excludes zero for this reason and no
    /// other.
    function testZeroChainIdIsRejectedLocallyButNotByOpenZeppelin() external {
        vm.expectRevert(Adapter8004.InvalidChainId.selector);
        harness.chainIdentifierFor(0);

        assertGt(InteroperableAddress.formatEvmV1(uint256(0)).length, 0);
    }
}
