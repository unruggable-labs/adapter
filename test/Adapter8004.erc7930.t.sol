// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Test, Vm} from "forge-std/Test.sol";
import {ERC1967Proxy} from "@openzeppelin/contracts/proxy/ERC1967/ERC1967Proxy.sol";
import {InteroperableAddress} from "@openzeppelin/contracts/utils/draft-InteroperableAddress.sol";
import {Adapter8004} from "../src/Adapter8004.sol";
import {IERCAgentBindings} from "../src/interfaces/IERCAgentBindings.sol";
import {MockIdentityRegistry} from "./mocks/MockIdentityRegistry.sol";
import {MockERC721} from "./mocks/MockERC721.sol";

/// @notice The pre-`0.0.17` byte-at-a-time ERC-7930 encoder, kept verbatim as the reference the
/// word-aligned rewrite is measured against.
///
/// **Do not delete, and do not "fix" it to match production.** Its whole value is that it was
/// written independently of the code it now checks; a test that compares the new encoder to itself
/// proves nothing. This encoding is the preimage of every counterfactual `registrationHash`, every
/// `attestationId`, and the EIP-712 surface, and a one-byte divergence would silently re-key
/// identities rather than revert, so byte-identity against this reference is the safety argument for
/// the rewrite. If it ever disagrees with production, the question is which one moved, and every
/// existing identity depends on the answer.
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
    function chainIdentifierFor(uint256 chainId) external pure returns (bytes memory) {
        return _chainIdentifierFor(chainId);
    }

    function interoperableAddressFor(uint256 chainId, address account) external pure returns (bytes memory) {
        return _interoperableAddressFor(chainId, account);
    }

    function registrationHashFor(
        bytes memory adapterInteroperableAddress,
        IERCAgentBindings.TokenStandard standard,
        address boundAddress,
        uint256 tokenId
    ) external pure returns (bytes32) {
        return _registrationHashFor(adapterInteroperableAddress, standard, boundAddress, tokenId);
    }

    /// @dev Paints a sentinel into the free memory the encoder must not reach, runs the encoder in
    /// the SAME frame, and reports whether the sentinel survived. An external call would prove
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
        encoded = includeAddress ? _interoperableAddressFor(chainId, account) : _chainIdentifierFor(chainId);
        assembly ("memory-safe") {
            guardIntact :=
                and(eq(mload(add(free, allocated)), sentinel), eq(mload(add(free, add(allocated, 0x20))), sentinel))
        }
    }

    /// @dev TEST-ONLY parameterized preimage. Production deliberately exposes no way to vary
    /// `extraData`, since the field is reserved rather than used, so the property that distinct
    /// discriminators yield distinct identities has to be expressed here instead. This restates the documented
    /// formula rather than calling production code, so every test using it MUST first anchor it:
    /// with `extraData == bytes32(0)` it has to equal what production computes. See
    /// `_assertParameterizedPreimageMatchesProduction`.
    function registrationHashWithExtra(
        IERCAgentBindings.TokenStandard standard,
        address boundAddress,
        uint256 tokenId,
        bytes32 extraData
    ) external view returns (bytes32) {
        return keccak256(abi.encode(_interoperableAddress(address(this)), standard, boundAddress, tokenId, extraData));
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
        Adapter8004 implementation = new Adapter8004();
        adapter = Adapter8004(
            address(
                new ERC1967Proxy(
                    address(implementation), abi.encodeCall(Adapter8004.initialize, (address(registry), address(this)))
                )
            )
        );
        harness = new Adapter8004HashHarness();
    }

    /// @dev Vectors for the five-component preimage with `extraData == bytes32(0)`. Each value was
    /// computed outside the contract as
    /// `keccak256(abi.encode(adapterAddress, uint8(standard), token, 42, bytes32(0)))` and
    /// cross-checked against the implementation, so this pins the encoding rather than restating it.
    /// The first group varies the chain envelope at a fixed standard; the second varies the standard
    /// at a fixed envelope, which is what pins the standard's position and width in the preimage.
    function testPublishedCrossNamespaceVectors() external view {
        _assertVector(
            hex"000100000101141111111111111111111111111111111111111111",
            IERCAgentBindings.TokenStandard.ERC721,
            0xefa93cfacbc3a08981c5725059a0a35e463f4063313da93f44d85cc02f457a0b
        );
        _assertVector(
            hex"00010000022105141111111111111111111111111111111111111111",
            IERCAgentBindings.TokenStandard.ERC721,
            0x59d0dda43bf31104928591e57cb9ea008cdc5010d128f5e9a1f22976d67f66c2
        );
        _assertVector(
            hex"0001000003aa36a7141111111111111111111111111111111111111111",
            IERCAgentBindings.TokenStandard.ERC721,
            0xda9417c2cab17e8973b2f8dc1661d856455d4877473006a492b1e4bc4b7960ff
        );
        _assertVector(
            hex"000100022045296998a6f8e2a784db5d9f95e18fc23f70441a1039446801089879b08c7ef0141111111111111111111111111111111111111111",
            IERCAgentBindings.TokenStandard.ERC721,
            0x9022fffd555f635b84981ac2056283d8325a432a0a01f3cac8ebf7cd4ba2cefc
        );
    }

    /// @dev One chain envelope, one `(boundAddress, tokenId)`, four standards, four pinned and
    /// distinct identities. These are the vectors that would move if the enum were ever renumbered,
    /// which is why the enum's numbering is identity-critical and append-only.
    function testPublishedPerStandardVectors() external view {
        bytes memory mainnetAdapter = hex"000100000101141111111111111111111111111111111111111111";
        _assertVector(
            mainnetAdapter,
            IERCAgentBindings.TokenStandard.ERC721,
            0xefa93cfacbc3a08981c5725059a0a35e463f4063313da93f44d85cc02f457a0b
        );
        _assertVector(
            mainnetAdapter,
            IERCAgentBindings.TokenStandard.ERC1155,
            0xa0822064813ff079eaead2d292b1cadd618d2350840f9813c5ee86605c6b654a
        );
        _assertVector(
            mainnetAdapter,
            IERCAgentBindings.TokenStandard.ACCOUNT,
            0xac6fc4a157cade654f49676a086bdcf2e514f0a21d5086cb22b6f9f1af59b029
        );
        _assertVector(
            mainnetAdapter,
            IERCAgentBindings.TokenStandard.CONTRACT_OWNABLE,
            0x06d91290d593090a0dc24da2056eb88f3c6a7e7f76f1a37a04061632933d9cb1
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

        for (uint8 s; s <= uint8(type(IERCAgentBindings.TokenStandard).max); ++s) {
            bytes32 current =
                harness.registrationHashFor(mainnetAdapter, IERCAgentBindings.TokenStandard(s), VECTOR_TOKEN, 42);
            assertTrue(current != schemeA, "must not collide with the live pre-ERC-7930 scheme");
            assertTrue(current != schemeB, "must not collide with the standard-less ERC-7930 scheme");
        }
    }

    /// @dev `COUNTERFACTUAL_EXTRA_DATA` is private and no getter varies it, so the reserved value is
    /// asserted through behaviour: production must agree with the explicit-zero preimage, for any
    /// token. This is also the anchor that makes the test-only parameterized helper trustworthy.
    function testReservedExtraDataIsZeroForEveryToken() external view {
        _assertParameterizedPreimageMatchesProduction(IERCAgentBindings.TokenStandard.ERC721, VECTOR_TOKEN, 42);
        _assertParameterizedPreimageMatchesProduction(
            IERCAgentBindings.TokenStandard.CONTRACT_ADMIN, address(0xBEEF), type(uint256).max
        );
        _assertParameterizedPreimageMatchesProduction(IERCAgentBindings.TokenStandard.ACCOUNT, address(0), 0);
    }

    function testDistinctExtraDataProducesDistinctIdentities() external view {
        _assertParameterizedPreimageMatchesProduction(IERCAgentBindings.TokenStandard.ERC721, VECTOR_TOKEN, 42);

        IERCAgentBindings.TokenStandard s = IERCAgentBindings.TokenStandard.ERC721;
        bytes32 a = keccak256("class-a");
        bytes32 b = keccak256("class-b");
        assertTrue(
            harness.registrationHashWithExtra(s, VECTOR_TOKEN, 42, a)
                != harness.registrationHashWithExtra(s, VECTOR_TOKEN, 42, b)
        );
        assertTrue(
            harness.registrationHashWithExtra(s, VECTOR_TOKEN, 42, a)
                != harness.registrationHashWithExtra(s, VECTOR_TOKEN, 42, bytes32(0))
        );
    }

    /// @dev The aliasing this version dissolves. Before the standard entered the preimage, one
    /// `(boundAddress, tokenId)` claimed under two standards collapsed onto a single identity, so a
    /// claimant who passed one authority probe shared a coordinate, and would share any reputation
    /// accumulated against it, with a claimant who passed a different one. Every standard must now
    /// produce a distinct identity for the same pair. The worked example is the contract that is also
    /// an ERC-721 collection claiming `(X, 0)` as `ERC721`, `ACCOUNT` and `CONTRACT_OWNABLE`.
    function testEveryStandardIsADistinctIdentityForOnePair() external view {
        uint8 max = uint8(type(IERCAgentBindings.TokenStandard).max);
        bytes32[] memory seen = new bytes32[](uint256(max) + 1);

        for (uint8 i; i <= max; ++i) {
            seen[i] = harness.registrationHash(IERCAgentBindings.TokenStandard(i), VECTOR_TOKEN, 0);
            for (uint8 j; j < i; ++j) {
                assertTrue(seen[i] != seen[j], "two standards must never alias onto one identity");
            }
        }
    }

    function testFuzzStandardIsLoadBearingInThePreimage(address boundAddress, uint256 tokenId, uint8 a, uint8 b)
        external
        view
    {
        uint8 max = uint8(type(IERCAgentBindings.TokenStandard).max);
        a = uint8(bound(a, 0, max));
        b = uint8(bound(b, 0, max));
        vm.assume(a != b);

        assertTrue(
            harness.registrationHash(IERCAgentBindings.TokenStandard(a), boundAddress, tokenId)
                != harness.registrationHash(IERCAgentBindings.TokenStandard(b), boundAddress, tokenId)
        );
    }

    /// @dev The motivating collision: one `(boundAddress, tokenId)`, two classes, two identities.
    /// Nothing produces this today, because production reserves the field and never varies it, so
    /// the property is pinned through the test-only parameterized preimage, anchored to production
    /// at `extraData == bytes32(0)`.
    function testTwoClassesOfOneTokenIdAreDistinctResolvableIdentities() external view {
        IERCAgentBindings.TokenStandard s = IERCAgentBindings.TokenStandard.ERC721;
        _assertParameterizedPreimageMatchesProduction(s, VECTOR_TOKEN, 1);

        bytes32 classA = keccak256("class-a");
        bytes32 classB = keccak256("class-b");
        bytes32 idA = harness.registrationHashWithExtra(s, VECTOR_TOKEN, 1, classA);
        bytes32 idB = harness.registrationHashWithExtra(s, VECTOR_TOKEN, 1, classB);

        assertTrue(idA != idB, "same token pair, different class, must be different identities");
        // Both remain independently recomputable, and neither shadows the other.
        assertEq(idA, harness.registrationHashWithExtra(s, VECTOR_TOKEN, 1, classA));
        assertEq(idB, harness.registrationHashWithExtra(s, VECTOR_TOKEN, 1, classB));
        // And the reserved zero identity for the same pair is a third, distinct identity.
        assertTrue(harness.registrationHash(s, VECTOR_TOKEN, 1) != idA);
        assertTrue(harness.registrationHash(s, VECTOR_TOKEN, 1) != idB);
    }

    /// @dev Ties the test-only parameterized preimage to the production hash. If production ever
    /// stops committing to a trailing `bytes32(0)`, whether by a different constant, a different
    /// position, or a dropped field, this fails. Without it the two class tests above would stay
    /// green against a formula production no longer uses.
    function _assertParameterizedPreimageMatchesProduction(
        IERCAgentBindings.TokenStandard standard,
        address boundAddress,
        uint256 tokenId
    ) internal view {
        assertEq(
            harness.registrationHash(standard, boundAddress, tokenId),
            harness.registrationHashWithExtra(standard, boundAddress, tokenId, bytes32(0)),
            "production must commit to a trailing bytes32(0)"
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

    /// @dev The single MSTORE must not write past the array's data region. Checked inside the
    /// encoder's own memory frame, with a sentinel painted into the words the allocation must not
    /// reach; an external call could not see this, because the callee's memory is a separate frame.
    function testFuzzFastPathDoesNotWritePastTheAllocation(uint256 seed, uint8 lengthPick, address account)
        external
        view
    {
        uint256 l = bound(lengthPick, 1, 32);
        uint256 chainId = _chainIdOfLength(seed, l);

        (bytes memory withAddress, bool guardA) = harness.encodeWithMemoryGuard(chainId, account, true);
        assertTrue(guardA, "address shape wrote past its allocation");
        assertEq(withAddress, ReferenceErc7930.encode(chainId, account, true));

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
        uint8 standard = uint8(IERCAgentBindings.TokenStandard.CONTRACT_OWNABLE);
        bytes memory identifier = adapter.chainIdentifier();
        bytes memory adapterAddress = adapter.interoperableAddress(address(adapter));
        bytes memory tokenAddress = adapter.interoperableAddress(token);
        bytes32 actual = adapter.registrationHash(IERCAgentBindings.TokenStandard.CONTRACT_OWNABLE, token, tokenId);
        assertEq(actual, keccak256(abi.encode(adapterAddress, standard, token, tokenId, bytes32(0))));
        // extraData must be a real trailing preimage field: dropping it, leading it, or changing
        // its value must each produce a different identity.
        assertTrue(actual != keccak256(abi.encode(adapterAddress, standard, token, tokenId)));
        assertTrue(actual != keccak256(abi.encode(bytes32(0), adapterAddress, standard, token, tokenId)));
        assertTrue(actual != keccak256(abi.encode(adapterAddress, standard, token, tokenId, keccak256("class-b"))));
        // The standard must be a real preimage field in its own position: dropping it, moving it
        // after the coordinates, or changing its value must each produce a different identity.
        assertTrue(actual != keccak256(abi.encode(adapterAddress, token, tokenId, bytes32(0))));
        assertTrue(actual != keccak256(abi.encode(adapterAddress, token, tokenId, standard, bytes32(0))));
        assertTrue(actual != keccak256(abi.encode(adapterAddress, uint8(standard + 1), token, tokenId, bytes32(0))));
        assertTrue(actual != keccak256(abi.encode(adapterAddress, uint8(standard - 1), token, tokenId, bytes32(0))));
        assertTrue(
            actual != keccak256(abi.encode(block.chainid, address(adapter), standard, token, tokenId, bytes32(0)))
        );
        assertTrue(actual != keccak256(abi.encode(identifier, address(adapter), standard, token, tokenId, bytes32(0))));
        assertTrue(actual != keccak256(abi.encode(adapterAddress, standard, tokenAddress, tokenId, bytes32(0))));
        assertTrue(actual != keccak256(abi.encode(address(adapter), standard, token, tokenId, bytes32(0))));
        assertTrue(actual != keccak256(abi.encodePacked(adapterAddress, standard, token, tokenId, bytes32(0))));
        assertTrue(actual != keccak256(abi.encode(keccak256(adapterAddress), standard, token, tokenId, bytes32(0))));
    }

    /// @dev The `extraData` an event advertises must be the same value folded into the
    /// `registrationHash` that event carries. With one constant referenced twice this cannot fail
    /// today, which is the point. The test reads the field back off the log and re-derives the hash
    /// from it, so it breaks if a future edit changes the value at the preimage but not at an emit
    /// site, or the reverse.
    function testEmittedExtraDataMatchesTheValueFoldedIntoTheHash() external {
        MockERC721 token = new MockERC721();
        token.mint(alice, 1);

        vm.prank(alice);
        vm.recordLogs();
        bytes32 emittedHash =
            adapter.counterfactualRegister(IERCAgentBindings.TokenStandard.ERC721, address(token), 1, "ipfs://cf");
        Vm.Log[] memory logs = vm.getRecordedLogs();

        assertEq(logs.length, 1);
        assertEq(logs[0].topics[1], emittedHash, "indexed hash");

        // Non-indexed head words, with no payload version: [0] bytes32 extraData, [1] uint8
        // standard, then the dynamic offsets. Read word 0.
        bytes32 emittedExtra;
        bytes memory data = logs[0].data;
        assembly ("memory-safe") {
            emittedExtra := mload(add(data, 0x20))
        }
        // Guard against this test passing by reading the wrong word: word 1 is `standard`, which is
        // also zero for ERC721, so assert the two words are distinguishable positions.
        bytes32 secondWord;
        assembly ("memory-safe") {
            secondWord := mload(add(data, 0x40))
        }
        assertEq(uint256(secondWord), uint256(uint8(IERCAgentBindings.TokenStandard.ERC721)), "word 1 is standard");

        // The hash in the event must be the hash of that exact emitted extraData and standard.
        assertEq(
            emittedHash,
            keccak256(
                abi.encode(
                    adapter.interoperableAddress(address(adapter)),
                    uint8(uint256(secondWord)),
                    address(token),
                    uint256(1),
                    emittedExtra
                )
            ),
            "hash folds emitted values"
        );
        // And it must be the reserved zero value, not some other constant.
        assertEq(emittedExtra, bytes32(0), "reserved value is zero");
        // A different discriminator would have produced a different identity, so the field is
        // genuinely load-bearing in the preimage rather than inert padding.
        assertTrue(
            emittedHash
                != keccak256(
                    abi.encode(
                        adapter.interoperableAddress(address(adapter)),
                        uint8(uint256(secondWord)),
                        address(token),
                        uint256(1),
                        keccak256("class-b")
                    )
                ),
            "extraData is load-bearing"
        );
        // Same for the standard the event advertises: a different one would have been a different
        // identity, so a log line carries everything a reader needs to recompute the hash it names.
        assertTrue(
            emittedHash
                != keccak256(
                    abi.encode(
                        adapter.interoperableAddress(address(adapter)),
                        uint8(uint256(secondWord)) + 1,
                        address(token),
                        uint256(1),
                        emittedExtra
                    )
                ),
            "standard is load-bearing"
        );
    }

    function testEachDomainCoordinateChangesHash() external view {
        bytes memory adapterAddress = hex"000100000101141111111111111111111111111111111111111111";
        bytes memory otherTypeAdapter = hex"000100010101141111111111111111111111111111111111111111";
        bytes memory otherReferenceAdapter = hex"000100000102141111111111111111111111111111111111111111";
        bytes memory otherAdapter = hex"000100000101143333333333333333333333333333333333333333";
        IERCAgentBindings.TokenStandard s = IERCAgentBindings.TokenStandard.ERC721;
        bytes32 base = harness.registrationHashFor(adapterAddress, s, VECTOR_TOKEN, 42);
        assertTrue(base != harness.registrationHashFor(otherTypeAdapter, s, VECTOR_TOKEN, 42));
        assertTrue(base != harness.registrationHashFor(otherReferenceAdapter, s, VECTOR_TOKEN, 42));
        assertTrue(base != harness.registrationHashFor(otherAdapter, s, VECTOR_TOKEN, 42));
        assertTrue(base != harness.registrationHashFor(adapterAddress, s, address(0x4444), 42));
        assertTrue(base != harness.registrationHashFor(adapterAddress, s, VECTOR_TOKEN, 43));
        assertTrue(
            base
                != harness.registrationHashFor(adapterAddress, IERCAgentBindings.TokenStandard.ERC1155, VECTOR_TOKEN, 42)
        );
    }

    function _assertVector(bytes memory adapterAddress, IERCAgentBindings.TokenStandard standard, bytes32 expected)
        internal
        view
    {
        assertEq(harness.registrationHashFor(adapterAddress, standard, VECTOR_TOKEN, 42), expected);
    }

    /// @dev These two tests compare the local ERC-7930 encoder against OpenZeppelin's, which is used
    /// nowhere in production and deliberately so. The encoding is the counterfactual identity
    /// preimage, so taking it from a library would mean a routine dependency bump could re-key every
    /// counterfactual identity that has ever been emitted. Keeping our own copy makes that
    /// impossible, and these tests are what stops the copy drifting in silence: they hold it against
    /// the ecosystem reference. If they ever fail, the question is not which implementation to
    /// change. It is whether ERC-7930 itself moved, and every existing identity depends on the
    /// answer. Do not delete these as unused, and do not resolve a failure by switching production
    /// to the library.
    function testEncodingMatchesOpenZeppelinReference() external view {
        uint256[4] memory chainIds = [uint256(1), 8453, 11155111, 424242];
        address account = 0x1111111111111111111111111111111111111111;

        for (uint256 i = 0; i < chainIds.length; i++) {
            assertEq(
                harness.interoperableAddressFor(chainIds[i], account),
                InteroperableAddress.formatEvmV1(chainIds[i], account)
            );
            assertEq(harness.chainIdentifierFor(chainIds[i]), InteroperableAddress.formatEvmV1(chainIds[i]));
        }
    }

    function testFuzzEncodingMatchesOpenZeppelinReference(uint256 chainId, address account) external view {
        vm.assume(chainId != 0);
        bytes memory ozEncoded = InteroperableAddress.formatEvmV1(chainId, account);
        assertEq(harness.interoperableAddressFor(chainId, account), ozEncoded);
        assertEq(harness.chainIdentifierFor(chainId), InteroperableAddress.formatEvmV1(chainId));
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
