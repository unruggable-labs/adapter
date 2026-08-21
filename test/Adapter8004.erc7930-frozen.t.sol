// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Test} from "forge-std/Test.sol";
import {Vm} from "forge-std/Vm.sol";
import {InteroperableAddress} from "@openzeppelin/contracts/utils/draft-InteroperableAddress.sol";
import {Adapter8004} from "../src/Adapter8004.sol";
import {IERC8004AdapterAttestation} from "../src/interfaces/IERC8004AdapterAttestation.sol";
import {IERC8004AdapterCounterfactual} from "../src/interfaces/IERC8004AdapterCounterfactual.sol";
import {IERCAgentBindings} from "../src/interfaces/IERCAgentBindings.sol";
import {Adapter8004HashHarness, ReferenceErc7930, WordAlignedErc7930} from "./Adapter8004.erc7930.t.sol";
import {MockIdentityRegistry} from "./mocks/MockIdentityRegistry.sol";
import {MockERC721} from "./mocks/MockERC721.sol";

/// @notice Locks the ERC-7930 encoding that `Adapter8004` now takes from OpenZeppelin.
///
/// # Why this file exists
///
/// This contract used to carry its own ERC-7930 encoder. At `0.0.17` it adopted OpenZeppelin's
/// `InteroperableAddress`. That swap is safe only for as long as OpenZeppelin's output stays
/// byte-identical to what the old encoders produced, because this encoding is the preimage of every
/// counterfactual `registrationHash` and every `attestationId` this contract has ever issued.
///
/// The exposure is real and specific. The library's file is `draft-` prefixed, so OpenZeppelin owes
/// no encoding stability across releases, and the dependency is a git submodule that somebody will
/// eventually bump. If a bump changed the encoding by one byte, **every identity would silently
/// re-key**: nothing would revert, nothing would look wrong, and every hash this contract produced
/// afterwards would name a different agent than the same inputs named before.
///
/// So this file's job is to make that failure loud, immediately, and unmistakable. It pins the
/// encoding three ways: against exact bytes derived from the ERC-7930 layout, against both former
/// in-house encoders kept frozen as references, and against the published fixture vectors end to
/// end through `registrationHash` and the attestation identifier.
contract Adapter8004Erc7930FrozenTest is Test {
    address internal constant VECTOR_ADAPTER = 0x1111111111111111111111111111111111111111;
    address internal constant VECTOR_TOKEN = 0x2222222222222222222222222222222222222222;
    address internal constant ALICE = 0x00000000000000000000000000000000000A11cE;

    /// @dev The published ERC-721 counterfactual identity for `(VECTOR_TOKEN, 42)` on Ethereum, from
    /// `docs/fixtures/adapter-counterfactual-hashes.md`.
    bytes32 internal constant PUBLISHED_CFID_MAINNET =
        0x8493ab3adb4f5e8753ee3fe05e377bffe213753e1b4155035fec1705d94615f9;
    bytes32 internal constant PUBLISHED_CFID_BASE = 0x7caa0ee523b99d37d2073eef394484c7b7a29c6d8848a531641c6ad59ac675a3;
    bytes32 internal constant PUBLISHED_CFID_SEPOLIA =
        0xc753b3b34ad2466a045e80c94ee26ac3a47054333762cb429ae7d8f17e12ac0f;

    /// @dev Vector 1 from `docs/fixtures/adapter-attestation-ids.md`.
    bytes32 internal constant PUBLISHED_ATTESTATION_ID =
        0x7fde72c738899c71442073381b50194c322b2ea08732ae9b3ea121e57979b58d;

    Adapter8004 internal adapter;
    Adapter8004HashHarness internal harness;

    function setUp() external {
        MockIdentityRegistry registry = new MockIdentityRegistry();
        adapter = Adapter8004(
            address(
                new ERC1967ProxyShim(
                    address(new Adapter8004(address(registry))), abi.encodeCall(Adapter8004.initialize, (address(this)))
                )
            )
        );
        harness = new Adapter8004HashHarness(address(registry));
    }

    // ----------------------------------------------------------------
    //  1. Exact bytes, derived from the ERC-7930 layout
    // ----------------------------------------------------------------
    //  version(0x0001) || ChainType(0x0000) || ReferenceLength || reference || AddressLength || addr
    //  Every literal below was written out from that layout, not read back off the implementation.

    function testTargetChainEnvelopesAreExactBytes() external view {
        assertEq(
            harness.interoperableAddressFor(1, VECTOR_ADAPTER),
            hex"000100000101141111111111111111111111111111111111111111",
            "Ethereum"
        );
        assertEq(
            harness.interoperableAddressFor(8453, VECTOR_ADAPTER),
            hex"00010000022105141111111111111111111111111111111111111111",
            "Base"
        );
        assertEq(
            harness.interoperableAddressFor(11155111, VECTOR_ADAPTER),
            hex"0001000003aa36a7141111111111111111111111111111111111111111",
            "Sepolia"
        );
    }

    function testTargetChainIdentifiersAreExactBytes() external view {
        assertEq(harness.chainIdentifierFor(1), hex"00010000010100", "Ethereum");
        assertEq(harness.chainIdentifierFor(8453), hex"0001000002210500", "Base");
        assertEq(harness.chainIdentifierFor(11155111), hex"0001000003aa36a700", "Sepolia");
    }

    /// @dev Chains this contract does not target, included because a change in OpenZeppelin's
    /// minimal-length rule would show up at some reference lengths before others.
    function testNonTargetChainEnvelopesAreExactBytes() external view {
        assertEq(
            harness.interoperableAddressFor(10, VECTOR_ADAPTER),
            hex"00010000010a141111111111111111111111111111111111111111",
            "Optimism"
        );
        assertEq(
            harness.interoperableAddressFor(56, VECTOR_ADAPTER),
            hex"000100000138141111111111111111111111111111111111111111",
            "BNB"
        );
        assertEq(
            harness.interoperableAddressFor(137, VECTOR_ADAPTER),
            hex"000100000189141111111111111111111111111111111111111111",
            "Polygon"
        );
        assertEq(
            harness.interoperableAddressFor(324, VECTOR_ADAPTER),
            hex"00010000020144141111111111111111111111111111111111111111",
            "zkSync Era"
        );
        assertEq(
            harness.interoperableAddressFor(42161, VECTOR_ADAPTER),
            hex"0001000002a4b1141111111111111111111111111111111111111111",
            "Arbitrum One"
        );
        assertEq(
            harness.interoperableAddressFor(43114, VECTOR_ADAPTER),
            hex"0001000002a86a141111111111111111111111111111111111111111",
            "Avalanche"
        );
        assertEq(
            harness.interoperableAddressFor(84532, VECTOR_ADAPTER),
            hex"0001000003014a34141111111111111111111111111111111111111111",
            "Base Sepolia"
        );
        assertEq(
            harness.interoperableAddressFor(421614, VECTOR_ADAPTER),
            hex"0001000003066eee141111111111111111111111111111111111111111",
            "Arbitrum Sepolia"
        );
        assertEq(
            harness.interoperableAddressFor(534352, VECTOR_ADAPTER),
            hex"0001000003082750141111111111111111111111111111111111111111",
            "Scroll"
        );
    }

    function testNonTargetChainIdentifiersAreExactBytes() external view {
        assertEq(harness.chainIdentifierFor(10), hex"00010000010a00", "Optimism");
        assertEq(harness.chainIdentifierFor(56), hex"00010000013800", "BNB");
        assertEq(harness.chainIdentifierFor(137), hex"00010000018900", "Polygon");
        assertEq(harness.chainIdentifierFor(324), hex"0001000002014400", "zkSync Era");
        assertEq(harness.chainIdentifierFor(42161), hex"0001000002a4b100", "Arbitrum One");
        assertEq(harness.chainIdentifierFor(43114), hex"0001000002a86a00", "Avalanche");
        assertEq(harness.chainIdentifierFor(84532), hex"0001000003014a3400", "Base Sepolia");
        assertEq(harness.chainIdentifierFor(421614), hex"0001000003066eee00", "Arbitrum Sepolia");
        assertEq(harness.chainIdentifierFor(534352), hex"000100000308275000", "Scroll");
    }

    /// @notice **IF THIS TEST FAILS AFTER BUMPING THE OPENZEPPELIN SUBMODULE, DO NOT UPDATE IT.**
    ///
    /// This test has exactly one job: to fail loudly when OpenZeppelin's ERC-7930 encoding changes.
    /// The library is `draft-` prefixed, so OpenZeppelin does not owe us encoding stability, and a
    /// routine dependency bump is the realistic way this breaks.
    ///
    /// The values below are the encoding every counterfactual `registrationHash` and every
    /// `attestationId` this contract has ever issued was derived from. If the new library produces
    /// anything else, then adopting it would re-key every one of those identities silently — no
    /// revert, nothing visibly wrong, just a different agent named by the same inputs from that
    /// block onward.
    ///
    /// So the correct response to a failure here is to **pin the old OpenZeppelin version, or
    /// reinstate the frozen `WordAlignedErc7930` encoder in `Adapter8004`**, and to treat the
    /// encoding change as a breaking upstream event that needs a decision. Editing these literals to
    /// match the new output silently accepts the re-keying and destroys the only evidence it
    /// happened. There is no situation in which changing this test is the right fix.
    function testOpenZeppelinEncodingIsFrozen() external pure {
        assertEq(
            InteroperableAddress.formatEvmV1(1, 0x1111111111111111111111111111111111111111),
            hex"000100000101141111111111111111111111111111111111111111",
            "OZ encoding changed: see the note on this test before touching anything"
        );
        assertEq(
            InteroperableAddress.formatEvmV1(8453, 0x1111111111111111111111111111111111111111),
            hex"00010000022105141111111111111111111111111111111111111111",
            "OZ encoding changed: see the note on this test before touching anything"
        );
        assertEq(
            InteroperableAddress.formatEvmV1(11155111, 0x1111111111111111111111111111111111111111),
            hex"0001000003aa36a7141111111111111111111111111111111111111111",
            "OZ encoding changed: see the note on this test before touching anything"
        );
        assertEq(
            InteroperableAddress.formatEvmV1(1),
            hex"00010000010100",
            "OZ encoding changed: see the note on this test before touching anything"
        );
    }

    /// @dev The three EVM reference examples from the ERC-7930 text, now asserted through production
    /// rather than only against the library.
    function testErc7930SpecExamplesThroughProduction() external view {
        address vitalik = 0xd8dA6BF26964aF9D7eEd9e03E53415D37aA96045;
        assertEq(
            harness.interoperableAddressFor(1, vitalik),
            hex"00010000010114d8da6bf26964af9d7eed9e03e53415d37aa96045",
            "spec example 1"
        );
        assertEq(
            harness.interoperableAddressFor(42161, vitalik),
            hex"0001000002a4b114d8da6bf26964af9d7eed9e03e53415d37aa96045",
            "spec example 5"
        );
        assertEq(harness.chainIdentifierFor(1), hex"00010000010100", "spec example 6");
    }

    // ----------------------------------------------------------------
    //  2. Three-way agreement: production, and both frozen encoders
    // ----------------------------------------------------------------

    function testThreeWayAgreementAtEveryTargetChain() external view {
        uint256[3] memory ids = [uint256(1), 8453, 11155111];
        for (uint256 i; i < ids.length; ++i) {
            bytes memory production = harness.interoperableAddressFor(ids[i], VECTOR_ADAPTER);
            assertEq(production, ReferenceErc7930.encode(ids[i], VECTOR_ADAPTER, true), "vs byte-loop reference");
            assertEq(production, WordAlignedErc7930.encode(ids[i], VECTOR_ADAPTER, true), "vs word-aligned reference");

            bytes memory bare = harness.chainIdentifierFor(ids[i]);
            assertEq(bare, ReferenceErc7930.encode(ids[i], address(0), false), "bare vs byte-loop reference");
            assertEq(bare, WordAlignedErc7930.encode(ids[i], address(0), false), "bare vs word-aligned reference");
        }
    }

    /// @dev Reference length picked explicitly. A raw `uint256` is almost always 32 bytes long, so an
    /// unconstrained fuzz would spend nearly every run on one length and barely sample the short
    /// references every real chain uses. This trap has been hit twice in this repo; do not reintroduce
    /// it by "simplifying" these to take a bare `chainId`.
    function testFuzzThreeWayAgreementAddressShape(uint256 seed, uint8 lengthPick, address account) external view {
        uint256 l = bound(lengthPick, 1, 32);
        uint256 chainId = _chainIdOfLength(seed, l);

        bytes memory production = harness.interoperableAddressFor(chainId, account);
        assertEq(production.length, l + 26, "premise: the intended reference length was built");
        assertEq(production, ReferenceErc7930.encode(chainId, account, true), "vs byte-loop reference");
        assertEq(production, WordAlignedErc7930.encode(chainId, account, true), "vs word-aligned reference");
    }

    function testFuzzThreeWayAgreementBareShape(uint256 seed, uint8 lengthPick) external view {
        uint256 l = bound(lengthPick, 1, 32);
        uint256 chainId = _chainIdOfLength(seed, l);

        bytes memory production = harness.chainIdentifierFor(chainId);
        assertEq(production.length, l + 6, "premise: the intended reference length was built");
        assertEq(production, ReferenceErc7930.encode(chainId, address(0), false), "vs byte-loop reference");
        assertEq(production, WordAlignedErc7930.encode(chainId, address(0), false), "vs word-aligned reference");
    }

    /// @dev Every reference length from 1 to 32, deterministically, at both ends of each length's
    /// range. Not left to the fuzzer at all.
    function testEveryReferenceLengthAgreesAddressShape() external view {
        for (uint256 l = 1; l <= 32; ++l) {
            uint256 smallest = l == 32 ? (uint256(1) << 255) : (uint256(1) << (8 * l - 8));
            uint256 largest = l == 32 ? type(uint256).max : (uint256(1) << (8 * l)) - 1;
            if (l == 1) smallest = 1;

            for (uint256 k; k < 2; ++k) {
                uint256 chainId = k == 0 ? smallest : largest;
                bytes memory production = harness.interoperableAddressFor(chainId, VECTOR_ADAPTER);
                assertEq(production, ReferenceErc7930.encode(chainId, VECTOR_ADAPTER, true), "byte-loop");
                assertEq(production, WordAlignedErc7930.encode(chainId, VECTOR_ADAPTER, true), "word-aligned");
            }
        }
    }

    function testEveryReferenceLengthAgreesBareShape() external view {
        for (uint256 l = 1; l <= 32; ++l) {
            uint256 smallest = l == 32 ? (uint256(1) << 255) : (uint256(1) << (8 * l - 8));
            uint256 largest = l == 32 ? type(uint256).max : (uint256(1) << (8 * l)) - 1;
            if (l == 1) smallest = 1;

            for (uint256 k; k < 2; ++k) {
                uint256 chainId = k == 0 ? smallest : largest;
                bytes memory production = harness.chainIdentifierFor(chainId);
                assertEq(production, ReferenceErc7930.encode(chainId, address(0), false), "byte-loop");
                assertEq(production, WordAlignedErc7930.encode(chainId, address(0), false), "word-aligned");
            }
        }
    }

    // ----------------------------------------------------------------
    //  3. Structural invariants of the envelope
    // ----------------------------------------------------------------
    //  These would catch an upstream change that produced a valid-but-different ERC-7930 value,
    //  which exact-byte vectors at a handful of chain ids could miss.

    function testFuzzVersionAndChainTypePrefixIsFixed(uint256 seed, uint8 lengthPick, address account) external view {
        uint256 chainId = _chainIdOfLength(seed, bound(lengthPick, 1, 32));
        bytes memory e = harness.interoperableAddressFor(chainId, account);
        assertEq(uint8(e[0]), 0x00, "version high byte");
        assertEq(uint8(e[1]), 0x01, "version low byte: ERC-7930 v1");
        assertEq(uint8(e[2]), 0x00, "ChainType high byte");
        assertEq(uint8(e[3]), 0x00, "ChainType low byte: CAIP-350 eip155");
    }

    function testFuzzReferenceLengthByteMatchesTheReference(uint256 seed, uint8 lengthPick, address account)
        external
        view
    {
        uint256 l = bound(lengthPick, 1, 32);
        uint256 chainId = _chainIdOfLength(seed, l);
        bytes memory e = harness.interoperableAddressFor(chainId, account);

        assertEq(uint8(e[4]), l, "ReferenceLength byte");
        uint256 decoded;
        for (uint256 i; i < l; ++i) {
            decoded = (decoded << 8) | uint8(e[5 + i]);
        }
        assertEq(decoded, chainId, "the reference decodes back to the chain id");
    }

    /// @dev Minimal encoding: the reference must never carry a leading zero byte, or two chain ids
    /// would have two encodings each and identities would stop being canonical.
    function testFuzzReferenceHasNoLeadingZeroByte(uint256 seed, uint8 lengthPick, address account) external view {
        uint256 chainId = _chainIdOfLength(seed, bound(lengthPick, 1, 32));
        bytes memory e = harness.interoperableAddressFor(chainId, account);
        assertTrue(uint8(e[5]) != 0, "reference is minimally encoded");
    }

    function testFuzzAddressLengthByteAndPlacement(uint256 seed, uint8 lengthPick, address account) external view {
        uint256 l = bound(lengthPick, 1, 32);
        uint256 chainId = _chainIdOfLength(seed, l);

        bytes memory withAddr = harness.interoperableAddressFor(chainId, account);
        assertEq(uint8(withAddr[5 + l]), 20, "AddressLength is 20 when an address is present");
        for (uint256 i; i < 20; ++i) {
            assertEq(uint8(withAddr[6 + l + i]), uint8(bytes20(account)[i]), "raw address byte");
        }

        bytes memory bare = harness.chainIdentifierFor(chainId);
        assertEq(uint8(bare[5 + l]), 0, "AddressLength is 0 when absent, and the byte is still there");
    }

    function testFuzzEnvelopeLengthsAreExact(uint256 seed, uint8 lengthPick, address account) external view {
        uint256 l = bound(lengthPick, 1, 32);
        uint256 chainId = _chainIdOfLength(seed, l);
        assertEq(harness.interoperableAddressFor(chainId, account).length, l + 26, "6 header + reference + 20");
        assertEq(harness.chainIdentifierFor(chainId).length, l + 6, "6 header + reference");
    }

    function testFuzzDistinctInputsProduceDistinctEnvelopes(uint256 seedA, uint256 seedB, address a, address b)
        external
        view
    {
        uint256 chainA = _chainIdOfLength(seedA, 4);
        uint256 chainB = _chainIdOfLength(seedB, 4);
        vm.assume(chainA != chainB);
        vm.assume(a != b);

        assertTrue(
            keccak256(harness.interoperableAddressFor(chainA, a))
                != keccak256(harness.interoperableAddressFor(chainB, a)),
            "different chains, different envelopes"
        );
        assertTrue(
            keccak256(harness.interoperableAddressFor(chainA, a))
                != keccak256(harness.interoperableAddressFor(chainA, b)),
            "different accounts, different envelopes"
        );
    }

    // ----------------------------------------------------------------
    //  4. Parsing: what an integrator will actually run
    // ----------------------------------------------------------------

    function testFuzzRoundTripThroughParseEvmV1(uint256 seed, uint8 lengthPick, address account) external view {
        uint256 chainId = _chainIdOfLength(seed, bound(lengthPick, 1, 32));
        (uint256 parsedChainId, address parsedAccount) =
            InteroperableAddress.parseEvmV1(harness.interoperableAddressFor(chainId, account));
        assertEq(parsedChainId, chainId, "chain id survives");
        assertEq(parsedAccount, account, "address survives");
    }

    function testFuzzRoundTripThroughTryParseEvmV1(uint256 seed, uint8 lengthPick, address account) external view {
        uint256 chainId = _chainIdOfLength(seed, bound(lengthPick, 1, 32));
        (bool ok, uint256 parsedChainId, address parsedAccount) =
            InteroperableAddress.tryParseEvmV1(harness.interoperableAddressFor(chainId, account));
        assertTrue(ok, "our envelope is a valid ERC-7930 EVM value");
        assertEq(parsedChainId, chainId);
        assertEq(parsedAccount, account);
    }

    function testFuzzBareEnvelopeParsesAsChainWithNoAddress(uint256 seed, uint8 lengthPick) external view {
        uint256 chainId = _chainIdOfLength(seed, bound(lengthPick, 1, 32));
        (bool ok, uint256 parsedChainId, address parsedAccount) =
            InteroperableAddress.tryParseEvmV1(harness.chainIdentifierFor(chainId));
        assertTrue(ok, "chain identifier is a valid ERC-7930 value");
        assertEq(parsedChainId, chainId);
        assertEq(parsedAccount, address(0), "and names no address");
    }

    // ----------------------------------------------------------------
    //  5. The deliberate divergence from OpenZeppelin
    // ----------------------------------------------------------------

    function testChainIdZeroRevertsOnBothShapes() external {
        vm.expectRevert(Adapter8004.InvalidChainId.selector);
        harness.chainIdentifierFor(0);

        vm.expectRevert(Adapter8004.InvalidChainId.selector);
        harness.interoperableAddressFor(0, VECTOR_ADAPTER);
    }

    /// @dev The guard is ours, not the library's, and adopting OpenZeppelin must not have quietly
    /// handed the decision over. A chain id of zero identifies no chain and `block.chainid` never
    /// returns it, so this contract refuses to mint an identity nothing could ever own; OpenZeppelin
    /// encodes it as a single zero reference byte.
    function testChainIdZeroDivergenceFromOpenZeppelinSurvives() external {
        vm.expectRevert(Adapter8004.InvalidChainId.selector);
        harness.chainIdentifierFor(0);

        assertEq(InteroperableAddress.formatEvmV1(uint256(0)), hex"00010000010000", "OZ encodes it");
    }

    // ----------------------------------------------------------------
    //  6. End to end: the published identities, through the real contract
    // ----------------------------------------------------------------

    function testAdapterLiveEnvelopeIsExactAndRoundTrips() external view {
        bytes memory live = adapter.interoperableAddress(address(adapter));
        assertEq(live, ReferenceErc7930.encode(block.chainid, address(adapter), true), "matches the frozen reference");

        (uint256 chainId, address parsed) = InteroperableAddress.parseEvmV1(live);
        assertEq(chainId, block.chainid);
        assertEq(parsed, address(adapter));
    }

    /// @dev The gate on this whole change: the published counterfactual identities must come back
    /// byte for byte from the contract, on each chain, with the encoder now taken from OpenZeppelin.
    function testRegistrationHashMatchesPublishedVectorsEndToEnd() external {
        _etchAdapterAtVectorAddress();
        Adapter8004 fx = Adapter8004(VECTOR_ADAPTER);

        vm.chainId(1);
        assertEq(
            fx.registrationHash(IERCAgentBindings.TokenStandard.ERC721, VECTOR_TOKEN, 42),
            PUBLISHED_CFID_MAINNET,
            "published Ethereum cfid"
        );
        vm.chainId(8453);
        assertEq(
            fx.registrationHash(IERCAgentBindings.TokenStandard.ERC721, VECTOR_TOKEN, 42),
            PUBLISHED_CFID_BASE,
            "published Base cfid"
        );
        vm.chainId(11155111);
        assertEq(
            fx.registrationHash(IERCAgentBindings.TokenStandard.ERC721, VECTOR_TOKEN, 42),
            PUBLISHED_CFID_SEPOLIA,
            "published Sepolia cfid"
        );
    }

    /// @dev The same gate for the attestation identifier, reproducing vector 1's exact environment.
    function testAttestationIdentifierMatchesPublishedVectorEndToEnd() external {
        _etchAdapterAtVectorAddress();
        vm.chainId(1);
        vm.roll(19000000);

        vm.recordLogs();
        vm.prank(ALICE);
        IERC8004AdapterAttestation(VECTOR_ADAPTER).confirmAdditionalAccount(PUBLISHED_CFID_MAINNET);

        Vm.Log[] memory logs = vm.getRecordedLogs();
        assertEq(logs.length, 1);
        (bytes32 emittedId,,) = abi.decode(logs[0].data, (bytes32, bytes32, bytes));
        assertEq(emittedId, PUBLISHED_ATTESTATION_ID, "published attestation identifier");
    }

    /// @dev And through an actual counterfactual emission, so the value an indexer reads off the log
    /// is the published one rather than only what a view returns.
    function testCounterfactualEventCarriesThePublishedHash() external {
        _etchAdapterAtVectorAddress();
        vm.chainId(1);

        MockERC721 token = new MockERC721();
        vm.etch(VECTOR_TOKEN, address(token).code);
        MockERC721(VECTOR_TOKEN).mint(ALICE, 42);

        vm.recordLogs();
        vm.prank(ALICE);
        bytes32 returned = Adapter8004(VECTOR_ADAPTER).counterfactualRegister(
            IERCAgentBindings.TokenStandard.ERC721, VECTOR_TOKEN, 42, "ipfs://cf"
        );

        Vm.Log[] memory logs = vm.getRecordedLogs();
        assertEq(logs.length, 1);
        assertEq(logs[0].topics[0], IERC8004AdapterCounterfactual.CounterfactualAgentRegistered.selector);
        assertEq(logs[0].topics[1], PUBLISHED_CFID_MAINNET, "the indexed identity is the published one");
        assertEq(returned, PUBLISHED_CFID_MAINNET, "and so is the returned value");
    }

    // ----------------------------------------------------------------
    //  Helpers
    // ----------------------------------------------------------------

    function _etchAdapterAtVectorAddress() private {
        vm.etch(VECTOR_ADAPTER, address(new Adapter8004(address(adapter.identityRegistry()))).code);
    }

    /// @dev Builds a chain id whose shortest big-endian encoding is exactly `l` bytes.
    function _chainIdOfLength(uint256 seed, uint256 l) private pure returns (uint256) {
        uint256 topBit = uint256(1) << (8 * l - 1);
        if (l == 32) return seed | topBit;
        return (seed & ((uint256(1) << (8 * l)) - 1)) | topBit;
    }
}

/// @dev Local minimal ERC-1967 proxy so this file does not depend on the OZ proxy import path used
/// elsewhere; behaviour is identical for these tests.
contract ERC1967ProxyShim {
    constructor(address implementation, bytes memory data) {
        assembly {
            sstore(0x360894a13ba1a3210667c828492db98dca3e2076cc3735a920a3ca505d382bbc, implementation)
        }
        (bool ok,) = implementation.delegatecall(data);
        require(ok, "init failed");
    }

    fallback() external payable {
        assembly {
            let impl := sload(0x360894a13ba1a3210667c828492db98dca3e2076cc3735a920a3ca505d382bbc)
            calldatacopy(0, 0, calldatasize())
            let result := delegatecall(gas(), impl, 0, calldatasize(), 0, 0)
            returndatacopy(0, 0, returndatasize())
            switch result
            case 0 { revert(0, returndatasize()) }
            default { return(0, returndatasize()) }
        }
    }
}
