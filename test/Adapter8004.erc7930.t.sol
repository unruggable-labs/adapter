// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Test, Vm} from "forge-std/Test.sol";
import {ERC1967Proxy} from "@openzeppelin/contracts/proxy/ERC1967/ERC1967Proxy.sol";
import {Adapter8004} from "../src/Adapter8004.sol";
import {IERCAgentBindings} from "../src/interfaces/IERCAgentBindings.sol";
import {MockIdentityRegistry} from "./mocks/MockIdentityRegistry.sol";
import {MockERC721} from "./mocks/MockERC721.sol";

contract Adapter8004HashHarness is Adapter8004 {
    function chainIdentifierFor(uint256 chainId) external pure returns (bytes memory) {
        return _chainIdentifierFor(chainId);
    }

    function interoperableAddressFor(uint256 chainId, address account) external pure returns (bytes memory) {
        return _interoperableAddressFor(chainId, account);
    }

    function registrationHashFor(bytes memory adapterInteroperableAddress, address tokenContract, uint256 tokenId)
        external
        pure
        returns (bytes32)
    {
        return _registrationHashFor(adapterInteroperableAddress, tokenContract, tokenId);
    }

    /// @dev TEST-ONLY parameterized preimage. Production deliberately exposes no way to vary
    /// `extraData`, since the field is reserved rather than used, so the property that distinct
    /// discriminators yield distinct identities has to be expressed here instead. This restates the documented
    /// formula rather than calling production code, so every test using it MUST first anchor it:
    /// with `extraData == bytes32(0)` it has to equal what production computes. See
    /// `_assertParameterizedPreimageMatchesProduction`.
    function registrationHashWithExtra(address tokenContract, uint256 tokenId, bytes32 extraData)
        external
        view
        returns (bytes32)
    {
        return keccak256(abi.encode(_interoperableAddress(address(this)), tokenContract, tokenId, extraData));
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

    /// @dev Vectors for the `extraData` preimage with `extraData == bytes32(0)`. Each value was
    /// computed outside the contract as
    /// `keccak256(abi.encode(adapterAddress, token, 42, bytes32(0)))` and cross-checked against the
    /// implementation, so this pins the encoding rather than restating it.
    function testPublishedCrossNamespaceVectors() external view {
        _assertVector(
            hex"000100000101141111111111111111111111111111111111111111",
            0xfd3ae85086b1e0d0a39318f3f7458b07a86becf50434a9b8b70b9426528388bf
        );
        _assertVector(
            hex"00010000022105141111111111111111111111111111111111111111",
            0xaddf435e3042b0f79ee2a2c26e5ec3a7757b2fec663ca0f45547b09489d0e07e
        );
        _assertVector(
            hex"0001000003aa36a7141111111111111111111111111111111111111111",
            0x5546dad5cfa9e0c3df6dff6ebca6d72e8bc3d707f2827c81e708a615cd24a2cb
        );
        _assertVector(
            hex"000100022045296998a6f8e2a784db5d9f95e18fc23f70441a1039446801089879b08c7ef0141111111111111111111111111111111111111111",
            0x725203cd24b34d707d2e8e9ae2dd74c7ea01e0cead262b4fe5fb483345c4d0d1
        );
    }

    /// @dev The superseded pre-`extraData` scheme, frozen as a literal so the cutover is asserted
    /// against a copy of the old formula rather than against whatever the contract computes now.
    function testSupersededVectorsNoLongerMatch() external view {
        bytes memory mainnetAdapter = hex"000100000101141111111111111111111111111111111111111111";
        assertEq(
            keccak256(abi.encode(mainnetAdapter, VECTOR_TOKEN, uint256(42))),
            0x7f28a61447dba6ca306a9b3c0af2184fb625679ab3da0c8469cf04734670875e,
            "frozen superseded vector"
        );
        assertTrue(
            harness.registrationHashFor(mainnetAdapter, VECTOR_TOKEN, 42)
                != 0x7f28a61447dba6ca306a9b3c0af2184fb625679ab3da0c8469cf04734670875e,
            "extraData scheme must not collide with the superseded scheme"
        );
    }

    /// @dev `COUNTERFACTUAL_EXTRA_DATA` is private and no getter varies it, so the reserved value is
    /// asserted through behaviour: production must agree with the explicit-zero preimage, for any
    /// token. This is also the anchor that makes the test-only parameterized helper trustworthy.
    function testReservedExtraDataIsZeroForEveryToken() external view {
        _assertParameterizedPreimageMatchesProduction(VECTOR_TOKEN, 42);
        _assertParameterizedPreimageMatchesProduction(address(0xBEEF), type(uint256).max);
        _assertParameterizedPreimageMatchesProduction(address(0), 0);
    }

    function testDistinctExtraDataProducesDistinctIdentities() external view {
        _assertParameterizedPreimageMatchesProduction(VECTOR_TOKEN, 42);

        bytes32 a = keccak256("class-a");
        bytes32 b = keccak256("class-b");
        assertTrue(
            harness.registrationHashWithExtra(VECTOR_TOKEN, 42, a)
                != harness.registrationHashWithExtra(VECTOR_TOKEN, 42, b)
        );
        assertTrue(
            harness.registrationHashWithExtra(VECTOR_TOKEN, 42, a)
                != harness.registrationHashWithExtra(VECTOR_TOKEN, 42, bytes32(0))
        );
    }

    /// @dev The motivating collision: one `(tokenContract, tokenId)`, two classes, two identities.
    /// Nothing produces this today, because production reserves the field and never varies it, so
    /// the property is pinned through the test-only parameterized preimage, anchored to production
    /// at `extraData == bytes32(0)`.
    function testTwoClassesOfOneTokenIdAreDistinctResolvableIdentities() external view {
        _assertParameterizedPreimageMatchesProduction(VECTOR_TOKEN, 1);

        bytes32 classA = keccak256("class-a");
        bytes32 classB = keccak256("class-b");
        bytes32 idA = harness.registrationHashWithExtra(VECTOR_TOKEN, 1, classA);
        bytes32 idB = harness.registrationHashWithExtra(VECTOR_TOKEN, 1, classB);

        assertTrue(idA != idB, "same token pair, different class, must be different identities");
        // Both remain independently recomputable, and neither shadows the other.
        assertEq(idA, harness.registrationHashWithExtra(VECTOR_TOKEN, 1, classA));
        assertEq(idB, harness.registrationHashWithExtra(VECTOR_TOKEN, 1, classB));
        // And the reserved zero identity for the same pair is a third, distinct identity.
        assertTrue(harness.registrationHash(VECTOR_TOKEN, 1) != idA);
        assertTrue(harness.registrationHash(VECTOR_TOKEN, 1) != idB);
    }

    /// @dev Ties the test-only parameterized preimage to the production hash. If production ever
    /// stops committing to a trailing `bytes32(0)`, whether by a different constant, a different
    /// position, or a dropped field, this fails. Without it the two class tests above would stay
    /// green against a formula production no longer uses.
    function _assertParameterizedPreimageMatchesProduction(address tokenContract, uint256 tokenId) internal view {
        assertEq(
            harness.registrationHash(tokenContract, tokenId),
            harness.registrationHashWithExtra(tokenContract, tokenId, bytes32(0)),
            "production must commit to a trailing bytes32(0)"
        );
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
        bytes memory identifier = adapter.chainIdentifier();
        bytes memory adapterAddress = adapter.interoperableAddress(address(adapter));
        bytes memory tokenAddress = adapter.interoperableAddress(token);
        bytes32 actual = adapter.registrationHash(token, tokenId);
        assertEq(actual, keccak256(abi.encode(adapterAddress, token, tokenId, bytes32(0))));
        // extraData must be a real trailing preimage field: dropping it, leading it, or changing
        // its value must each produce a different identity.
        assertTrue(actual != keccak256(abi.encode(adapterAddress, token, tokenId)));
        assertTrue(actual != keccak256(abi.encode(bytes32(0), adapterAddress, token, tokenId)));
        assertTrue(actual != keccak256(abi.encode(adapterAddress, token, tokenId, keccak256("class-b"))));
        assertTrue(actual != keccak256(abi.encode(block.chainid, address(adapter), token, tokenId, bytes32(0))));
        assertTrue(actual != keccak256(abi.encode(identifier, address(adapter), token, tokenId, bytes32(0))));
        assertTrue(actual != keccak256(abi.encode(adapterAddress, tokenAddress, tokenId, bytes32(0))));
        assertTrue(actual != keccak256(abi.encode(address(adapter), token, tokenId, bytes32(0))));
        assertTrue(actual != keccak256(abi.encodePacked(adapterAddress, token, tokenId, bytes32(0))));
        assertTrue(actual != keccak256(abi.encode(keccak256(adapterAddress), token, tokenId, bytes32(0))));
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

        // The hash in the event must be the hash of that exact emitted extraData.
        assertEq(
            emittedHash,
            keccak256(
                abi.encode(adapter.interoperableAddress(address(adapter)), address(token), uint256(1), emittedExtra)
            ),
            "hash folds emitted value"
        );
        // And it must be the reserved zero value, not some other constant.
        assertEq(emittedExtra, bytes32(0), "reserved value is zero");
        // A different discriminator would have produced a different identity, so the field is
        // genuinely load-bearing in the preimage rather than inert padding.
        assertTrue(
            emittedHash
                != keccak256(
                    abi.encode(
                        adapter.interoperableAddress(address(adapter)), address(token), uint256(1), keccak256("class-b")
                    )
                ),
            "field is load-bearing"
        );
    }

    function testEachDomainCoordinateChangesHash() external view {
        bytes memory adapterAddress = hex"000100000101141111111111111111111111111111111111111111";
        bytes memory otherTypeAdapter = hex"000100010101141111111111111111111111111111111111111111";
        bytes memory otherReferenceAdapter = hex"000100000102141111111111111111111111111111111111111111";
        bytes memory otherAdapter = hex"000100000101143333333333333333333333333333333333333333";
        bytes32 base = harness.registrationHashFor(adapterAddress, VECTOR_TOKEN, 42);
        assertTrue(base != harness.registrationHashFor(otherTypeAdapter, VECTOR_TOKEN, 42));
        assertTrue(base != harness.registrationHashFor(otherReferenceAdapter, VECTOR_TOKEN, 42));
        assertTrue(base != harness.registrationHashFor(otherAdapter, VECTOR_TOKEN, 42));
        assertTrue(base != harness.registrationHashFor(adapterAddress, address(0x4444), 42));
        assertTrue(base != harness.registrationHashFor(adapterAddress, VECTOR_TOKEN, 43));
    }

    function _assertVector(bytes memory adapterAddress, bytes32 expected) internal view {
        assertEq(harness.registrationHashFor(adapterAddress, VECTOR_TOKEN, 42), expected);
    }
}
