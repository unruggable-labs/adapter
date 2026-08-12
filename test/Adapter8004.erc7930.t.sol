// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Test, Vm} from "forge-std/Test.sol";
import {ERC1967Proxy} from "@openzeppelin/contracts/proxy/ERC1967/ERC1967Proxy.sol";
import {Adapter8004} from "../src/Adapter8004.sol";
import {IERCAgentBindings} from "../src/interfaces/IERCAgentBindings.sol";
import {IERC8004IdentityRegistry} from "../src/interfaces/IERC8004IdentityRegistry.sol";
import {MockIdentityRegistry} from "./mocks/MockIdentityRegistry.sol";
import {MockERC721} from "./mocks/MockERC721.sol";

contract Adapter8004HashHarness is Adapter8004 {
    function chainIdentifierFor(uint256 chainId) external pure returns (bytes memory) {
        return _chainIdentifierFor(chainId);
    }

    function interoperableAddressFor(uint256 chainId, address account) external pure returns (bytes memory) {
        return _interoperableAddressFor(chainId, account);
    }

    function tokenIdentifier(uint256 tokenId) external pure returns (bytes memory) {
        return _tokenIdentifier(tokenId);
    }

    function registrationHashFor(
        bytes memory adapterInteroperableAddress,
        address tokenContract,
        bytes memory identifier
    ) external pure returns (bytes32) {
        return _registrationHashFor(adapterInteroperableAddress, tokenContract, identifier);
    }
}

contract Adapter8004ERC7930Test is Test {
    Adapter8004 internal adapter;
    Adapter8004HashHarness internal harness;
    address internal constant VECTOR_ADAPTER = 0x1111111111111111111111111111111111111111;
    address internal constant VECTOR_TOKEN = 0x2222222222222222222222222222222222222222;
    address internal alice = makeAddr("alice");

    bytes internal constant MAINNET_ADAPTER = hex"00010000010114" hex"1111111111111111111111111111111111111111";
    bytes internal constant TOKEN_42_IDENTIFIER =
        hex"00" hex"000000000000000000000000000000000000000000000000000000000000002a";

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

    // -----------------------------------------------------------------
    //  Identifier grammar
    // -----------------------------------------------------------------

    /// @dev The canonical token identifier is the 0x00 kind byte plus the FULL-WIDTH 32-byte
    /// big-endian id (33 bytes). Minimal-length encodings would give one subject two encodings, so
    /// the full width is load-bearing, including for id 0 and id max.
    function testTokenIdentifierIsKindByteAndFullWidthId() external view {
        assertEq(harness.tokenIdentifier(42), TOKEN_42_IDENTIFIER);
        assertEq(harness.tokenIdentifier(0).length, 33);
        assertEq(harness.tokenIdentifier(type(uint256).max).length, 33);
        assertEq(uint8(harness.tokenIdentifier(0)[0]), 0);
        // id 0's identifier is 33 bytes of zeros — emphatically NOT the empty contract identifier.
        assertEq(harness.tokenIdentifier(0), abi.encodePacked(uint8(0), uint256(0)));
    }

    function testFuzzTokenIdentifierRoundTrips(uint256 tokenId) external view {
        bytes memory identifier = harness.tokenIdentifier(tokenId);
        assertEq(identifier.length, 33);
        assertEq(uint8(identifier[0]), 0);
        uint256 decoded;
        for (uint256 i; i < 32; ++i) {
            decoded = (decoded << 8) | uint8(identifier[1 + i]);
        }
        assertEq(decoded, tokenId);
    }

    // -----------------------------------------------------------------
    //  Published vectors
    // -----------------------------------------------------------------

    /// @dev Token-subject vectors (identifier = 0x00 || id 42) computed outside the contract as
    /// `keccak256(abi.encode(adapterAddress, token, identifier))` and cross-checked here, so this
    /// pins the encoding rather than restating it.
    function testPublishedTokenSubjectVectors() external view {
        _assertTokenVector(MAINNET_ADAPTER, 0x2561a5127ce57aca2b3435b4ed6ed64f7c5b6751cfdc446b966689526719a6b2);
        _assertTokenVector(
            hex"0001000002210514" hex"1111111111111111111111111111111111111111",
            0xc85bfd30d7222052df213b1a9edb65d078c797f318571dd093b5d672bf2bb285
        );
        _assertTokenVector(
            hex"0001000003aa36a714" hex"1111111111111111111111111111111111111111",
            0x13dbefeafc7447b0e8affa009d7f3b45ad82ea4424751918250558dce70b0322
        );
        _assertTokenVector(
            hex"000100022045296998a6f8e2a784db5d9f95e18fc23f70441a1039446801089879b08c7ef014"
            hex"1111111111111111111111111111111111111111",
            0xecafe1ffdf879b3f017085b8218f16a5460f933c9f43a1c8b93cda3e56645782
        );
    }

    /// @dev Contract-subject vectors: the identifier is EMPTY (the subject is the contract itself).
    function testPublishedContractSubjectVectors() external view {
        assertEq(
            harness.registrationHashFor(MAINNET_ADAPTER, VECTOR_TOKEN, ""),
            0x7bcd28a8ab06672398163fa398bb414db0be5439508f0e96f7dd440cf2c43ea0
        );
        assertEq(
            harness.registrationHashFor(
                hex"0001000002210514" hex"1111111111111111111111111111111111111111", VECTOR_TOKEN, ""
            ),
            0xe42152f115d09fc263b6dd6cba1c15b5942d8be411b24e702ceaed0d9cf2c445
        );
        assertEq(
            harness.registrationHashFor(
                hex"0001000003aa36a714" hex"1111111111111111111111111111111111111111", VECTOR_TOKEN, ""
            ),
            0xc3e05023a35169e093cf930042ca89c5b4b24fb314b23194637e0707ec2febbd
        );
    }

    /// @dev The money shot of the identifier grammar: token id 0 (33 bytes of zeros behind a kind
    /// byte) and the contract subject (empty) are distinct identities at the same coordinate.
    function testTokenZeroAndContractSubjectAreDistinctIdentities() external view {
        bytes32 tokenZero = harness.registrationHashFor(MAINNET_ADAPTER, VECTOR_TOKEN, harness.tokenIdentifier(0));
        bytes32 contractSubject = harness.registrationHashFor(MAINNET_ADAPTER, VECTOR_TOKEN, "");
        assertEq(tokenZero, 0x7e90bedaa189d8b5124fb6e56be1140283a8a16451546607fe0d42b892a2a2a8);
        assertEq(contractSubject, 0x7bcd28a8ab06672398163fa398bb414db0be5439508f0e96f7dd440cf2c43ea0);
        assertTrue(tokenZero != contractSubject);
    }

    /// @dev A future identifier kind (leading byte != 0x00) is a distinct identity by construction —
    /// the class-token use case that previously motivated the removed `extraData` field.
    function testFutureIdentifierKindsAreDistinctIdentities() external view {
        bytes memory classB123 = abi.encodePacked(uint8(1), uint256(2), uint256(123));
        bytes32 classIdentity = harness.registrationHashFor(MAINNET_ADAPTER, VECTOR_TOKEN, classB123);
        assertEq(classIdentity, 0x1657a0aeeb5e08c43ffaafd8a9746524d2aae8ed7d45a82b734937cb788940ad);
        assertTrue(
            classIdentity != harness.registrationHashFor(MAINNET_ADAPTER, VECTOR_TOKEN, harness.tokenIdentifier(123))
        );
        assertTrue(classIdentity != harness.registrationHashFor(MAINNET_ADAPTER, VECTOR_TOKEN, ""));
    }

    // -----------------------------------------------------------------
    //  Superseded schemes
    // -----------------------------------------------------------------

    /// @dev Committed schemes a reimplementer might have built against, frozen as literals so the
    /// cutovers are asserted against copies of the old formulas rather than whatever the contract
    /// computes now: (1) the pre-v0.0.15 tuple without extraData; (2) the v0.0.15 tuple with a
    /// trailing `bytes32 extraData`. Both used the same ERC-7930 v1 adapter bytes the identifier
    /// scheme keeps (D1 revised), so the cutover is purely tuple-preimage vs identifier-preimage.
    function testSupersededVectorsNoLongerMatch() external {
        bytes memory versionedMainnetAdapter = hex"00010000010114" hex"1111111111111111111111111111111111111111";
        assertEq(
            keccak256(abi.encode(versionedMainnetAdapter, VECTOR_TOKEN, uint256(42))),
            0x7f28a61447dba6ca306a9b3c0af2184fb625679ab3da0c8469cf04734670875e,
            "frozen pre-extraData vector"
        );
        assertEq(
            keccak256(abi.encode(versionedMainnetAdapter, VECTOR_TOKEN, uint256(42), bytes32(0))),
            0xfd3ae85086b1e0d0a39318f3f7458b07a86becf50434a9b8b70b9426528388bf,
            "frozen versioned extraData vector"
        );
        vm.chainId(1);
        bytes memory liveAdapterBytes = harness.interoperableAddressFor(1, VECTOR_ADAPTER);
        assertEq(keccak256(liveAdapterBytes), keccak256(MAINNET_ADAPTER), "live encoding is ERC-7930 v1");
        bytes32 live = harness.registrationHashFor(liveAdapterBytes, VECTOR_TOKEN, harness.tokenIdentifier(42));
        assertEq(live, 0x2561a5127ce57aca2b3435b4ed6ed64f7c5b6751cfdc446b966689526719a6b2, "published vector");
        assertTrue(live != 0x7f28a61447dba6ca306a9b3c0af2184fb625679ab3da0c8469cf04734670875e, "vs scheme 1");
        assertTrue(live != 0xfd3ae85086b1e0d0a39318f3f7458b07a86becf50434a9b8b70b9426528388bf, "vs scheme 2");
    }

    // -----------------------------------------------------------------
    //  ERC-7930 v1 encoding
    // -----------------------------------------------------------------

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
        assertEq(adapter.interoperableAddress(VECTOR_ADAPTER), MAINNET_ADAPTER);
        vm.chainId(8453);
        assertEq(
            adapter.interoperableAddress(VECTOR_TOKEN),
            hex"0001000002210514" hex"2222222222222222222222222222222222222222"
        );
    }

    function testFuzzMinimalBigEndianIdentifier(uint256 chainId) external {
        vm.assume(chainId != 0);
        bytes memory identifier = harness.chainIdentifierFor(chainId);
        uint256 referenceLength = identifier.length - 6;
        assertGe(referenceLength, 1);
        assertLe(referenceLength, 32);
        // ERC-7930 v1 layout: Version(0x0001) || ChainType(2) || RefLen(1) || Ref || AddrLen(1).
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

    // -----------------------------------------------------------------
    //  Canonical formula and negative encodings
    // -----------------------------------------------------------------

    function testCanonicalFormulaAndNegativeEncodings() external view {
        address token = address(0xCAFE);
        uint256 tokenId = 99;
        bytes memory adapterAddress = adapter.interoperableAddress(address(adapter));
        bytes memory identifier = abi.encodePacked(uint8(0), tokenId);
        bytes32 actual = adapter.registrationHash(token, tokenId);
        assertEq(actual, keccak256(abi.encode(adapterAddress, token, identifier)));
        // The identifier must be a real ABI `bytes` field with the canonical encoding: packing,
        // dropping the kind byte, minimal-length ids, the old tuple layouts, and the naked adapter
        // address must each produce a different identity.
        assertTrue(actual != keccak256(abi.encodePacked(adapterAddress, token, identifier)));
        assertTrue(actual != keccak256(abi.encode(adapterAddress, token, abi.encodePacked(tokenId))));
        assertTrue(actual != keccak256(abi.encode(adapterAddress, token, abi.encodePacked(uint8(0), uint8(99)))));
        assertTrue(actual != keccak256(abi.encode(adapterAddress, token, tokenId)));
        assertTrue(actual != keccak256(abi.encode(adapterAddress, token, tokenId, bytes32(0))));
        assertTrue(actual != keccak256(abi.encode(block.chainid, address(adapter), token, tokenId)));
        assertTrue(actual != keccak256(abi.encode(address(adapter), token, identifier)));
        // Contract-subject view matches the empty-identifier formula and differs from every token id.
        assertEq(adapter.registrationHash(token), keccak256(abi.encode(adapterAddress, token, bytes(""))));
        assertTrue(adapter.registrationHash(token) != actual);
        assertTrue(adapter.registrationHash(token) != adapter.registrationHash(token, 0));
    }

    /// @dev The identifier an event advertises must be the value hashed into the identity that same
    /// event carries. Reads the emitted identifier back off the log and re-derives the hash from it,
    /// so it breaks if an emit site and the preimage ever disagree.
    function testEmittedIdentifierMatchesTheValueFoldedIntoTheHash() external {
        MockERC721 token = new MockERC721();
        token.mint(alice, 1);

        vm.prank(alice);
        vm.recordLogs();
        bytes32 emittedHash =
            adapter.counterfactualRegister(IERCAgentBindings.TokenStandard.ERC721, address(token), 1, "ipfs://cf");
        Vm.Log[] memory logs = vm.getRecordedLogs();

        assertEq(logs.length, 1);
        assertEq(logs[0].topics[1], emittedHash, "indexed hash");
        assertEq(logs[0].topics[3], bytes32(uint256(uint160(alice))), "indexed emitter");

        // Non-indexed head: [0] offset to identifier, then standard, then dynamic tails. Decode the
        // whole body to recover the identifier faithfully.
        (bytes memory emittedIdentifier,,,) =
            abi.decode(logs[0].data, (bytes, uint8, string, IERC8004IdentityRegistry.MetadataEntry[]));
        assertEq(emittedIdentifier, abi.encodePacked(uint8(0), uint256(1)), "canonical token identifier");
        assertEq(
            emittedHash,
            keccak256(abi.encode(adapter.interoperableAddress(address(adapter)), address(token), emittedIdentifier)),
            "hash folds emitted identifier"
        );
    }

    function testEachDomainCoordinateChangesHash() external view {
        bytes memory adapterAddress = MAINNET_ADAPTER;
        bytes memory otherTypeAdapter = hex"00010001010114" hex"1111111111111111111111111111111111111111";
        bytes memory otherReferenceAdapter = hex"00010000010214" hex"1111111111111111111111111111111111111111";
        bytes memory otherAdapter = hex"00010000010114" hex"3333333333333333333333333333333333333333";
        bytes memory id42 = harness.tokenIdentifier(42);
        bytes32 base = harness.registrationHashFor(adapterAddress, VECTOR_TOKEN, id42);
        assertTrue(base != harness.registrationHashFor(otherTypeAdapter, VECTOR_TOKEN, id42));
        assertTrue(base != harness.registrationHashFor(otherReferenceAdapter, VECTOR_TOKEN, id42));
        assertTrue(base != harness.registrationHashFor(otherAdapter, VECTOR_TOKEN, id42));
        assertTrue(base != harness.registrationHashFor(adapterAddress, address(0x4444), id42));
        assertTrue(base != harness.registrationHashFor(adapterAddress, VECTOR_TOKEN, harness.tokenIdentifier(43)));
    }

    function _assertTokenVector(bytes memory adapterAddress, bytes32 expected) internal view {
        assertEq(harness.registrationHashFor(adapterAddress, VECTOR_TOKEN, TOKEN_42_IDENTIFIER), expected);
    }
}
