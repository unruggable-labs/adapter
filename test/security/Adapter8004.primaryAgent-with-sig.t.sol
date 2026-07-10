// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Test, Vm} from "forge-std/Test.sol";
import {ERC1967Proxy} from "@openzeppelin/contracts/proxy/ERC1967/ERC1967Proxy.sol";
import {UUPSUpgradeable} from "@openzeppelin/contracts-upgradeable/proxy/utils/UUPSUpgradeable.sol";
import {IERC1271} from "@openzeppelin/contracts/interfaces/IERC1271.sol";

import {Adapter8004} from "../../src/Adapter8004.sol";
import {IERC8004AdapterPrimaryAgent} from "../../src/interfaces/IERC8004AdapterPrimaryAgent.sol";
import {IERC8004AdapterCounterfactual} from "../../src/interfaces/IERC8004AdapterCounterfactual.sol";
import {IERCAgentBindings} from "../../src/interfaces/IERCAgentBindings.sol";
import {IERC8004IdentityRegistry} from "../../src/interfaces/IERC8004IdentityRegistry.sol";

import {MockIdentityRegistry} from "../mocks/MockIdentityRegistry.sol";
import {MockERC721} from "../mocks/MockERC721.sol";

/// @dev Test-only subclass that forces `_registrationHash` to the reserved all-ones sentinel so the
/// combined flow's second half (`_setPrimaryAgent`) reverts `PrimaryAgentIdReserved`. This is the
/// "harness" the design's acceptance matrix calls for to exercise the atomic-rollback path, since a
/// real keccak256 registration hash cannot be steered to all-ones.
contract Adapter8004ReservedHashHarness is Adapter8004 {
    function _registrationHash(address, uint256) internal pure override returns (bytes32) {
        return bytes32(type(uint256).max);
    }
}

contract PrimaryAgentWithSigTest is Test {
    bytes32 internal constant DOMAIN_TYPEHASH =
        keccak256("EIP712Domain(string name,string version,uint256 chainId,address verifyingContract)");
    bytes32 internal constant SET_PRIMARY_AGENT_TYPEHASH =
        keccak256("SetPrimaryAgent(address account,bytes32 agentId,uint256 nonce,uint256 deadline)");
    bytes32 internal constant CLEAR_PRIMARY_AGENT_TYPEHASH =
        keccak256("ClearPrimaryAgent(address account,uint256 nonce,uint256 deadline)");
    bytes32 internal constant COMBINED_TYPEHASH = keccak256(
        "CounterfactualRegisterAndSetPrimary(uint8 standard,address tokenContract,uint256 tokenId,string agentURI,MetadataEntry[] metadata,address agentWallet,address signer,uint256 nonce,uint256 deadline)MetadataEntry(string metadataKey,bytes metadataValue)"
    );
    bytes32 internal constant METADATA_ENTRY_TYPEHASH =
        keccak256("MetadataEntry(string metadataKey,bytes metadataValue)");
    uint256 internal constant MAX_LIFETIME = 30 minutes;
    bytes32 internal constant UNSET = bytes32(type(uint256).max);

    // Events under test (mirrored for vm.expectEmit).
    event PrimaryAgentSet(address indexed account, bytes32 indexed agentId, address indexed setBy);
    event PrimaryAgentCleared(address indexed account, address indexed clearedBy);
    event PrimaryAgentSetWithSig(
        address indexed account, bytes32 indexed agentId, address indexed relayer, uint256 nonce
    );
    event PrimaryAgentClearedWithSig(address indexed account, address indexed relayer, uint256 nonce);

    MockIdentityRegistry internal registry;
    Adapter8004 internal adapter;
    MockERC721 internal token721;

    uint256 internal alicePk = 0xA11CE;
    uint256 internal bobPk = 0xB0B;
    address internal alice;
    address internal bob;
    address internal relayer = makeAddr("relayer");
    address internal admin = makeAddr("admin");
    address internal wallet = makeAddr("wallet");

    bytes32 internal constant SMALL_ID = bytes32(uint256(42));
    bytes32 internal constant HASH_ID = keccak256("a-counterfactual-hash");

    function setUp() external {
        alice = vm.addr(alicePk);
        bob = vm.addr(bobPk);

        registry = new MockIdentityRegistry();
        Adapter8004 implementation = new Adapter8004();
        ERC1967Proxy proxy = new ERC1967Proxy(
            address(implementation), abi.encodeCall(Adapter8004.initialize, (address(registry), admin))
        );
        adapter = Adapter8004(address(proxy));

        token721 = new MockERC721();
        token721.mint(alice, 1);
        token721.mint(bob, 3);
    }

    /* --------------------------- setPrimaryAgentWithSig --------------------------- */

    function testSetWithSigEOAHappyPathRelayer() external {
        uint256 deadline = block.timestamp + 5 minutes;
        bytes memory sig = _sign(alicePk, _setDigest(alice, SMALL_ID, 0, deadline));

        vm.expectEmit(true, true, true, true, address(adapter));
        emit PrimaryAgentSet(alice, SMALL_ID, relayer);
        vm.expectEmit(true, true, true, true, address(adapter));
        emit PrimaryAgentSetWithSig(alice, SMALL_ID, relayer, 0);

        vm.prank(relayer);
        adapter.setPrimaryAgentWithSig(alice, SMALL_ID, deadline, sig);

        assertEq(adapter.primaryAgentOf(alice), SMALL_ID);
        assertEq(adapter.nonces(alice), 1);
    }

    function testSetWithSigERC1271HappyPath() external {
        MockERC1271Account acct = new MockERC1271Account();
        uint256 deadline = block.timestamp + 5 minutes;
        acct.approve(_setDigest(address(acct), HASH_ID, 0, deadline));

        vm.prank(relayer);
        adapter.setPrimaryAgentWithSig(address(acct), HASH_ID, deadline, hex"1234");
        assertEq(adapter.primaryAgentOf(address(acct)), HASH_ID);
        assertEq(adapter.nonces(address(acct)), 1);
    }

    function testSetWithSigERC1271RejectionReverts() external {
        MockERC1271Account acct = new MockERC1271Account(); // approves nothing
        uint256 deadline = block.timestamp + 5 minutes;
        vm.prank(relayer);
        vm.expectRevert(Adapter8004.InvalidSignature.selector);
        adapter.setPrimaryAgentWithSig(address(acct), HASH_ID, deadline, hex"1234");
        assertEq(adapter.nonces(address(acct)), 0);
    }

    /// The adapter must validate strictly against the account's own ERC-1271 policy and NOT fall back
    /// to owner()/getOwner()/admin discovery the paid path uses.
    function testSetWithSigDoesNotConsultPaidControllerDiscovery() external {
        RejectingOwnedERC1271 acct = new RejectingOwnedERC1271(alice); // owner() == alice, 1271 rejects all
        uint256 deadline = block.timestamp + 5 minutes;
        bytes memory ownerSig = _sign(alicePk, _setDigest(address(acct), SMALL_ID, 0, deadline));

        vm.prank(relayer);
        vm.expectRevert(Adapter8004.InvalidSignature.selector);
        adapter.setPrimaryAgentWithSig(address(acct), SMALL_ID, deadline, ownerSig);
        assertEq(adapter.nonces(address(acct)), 0);
    }

    function testSetWithSigAgentIdZeroIsValid() external {
        uint256 deadline = block.timestamp + 5 minutes;
        bytes memory sig = _sign(alicePk, _setDigest(alice, bytes32(0), 0, deadline));
        vm.prank(relayer);
        adapter.setPrimaryAgentWithSig(alice, bytes32(0), deadline, sig);
        assertEq(adapter.primaryAgentOf(alice), bytes32(0));
        assertTrue(adapter.primaryAgentOf(alice) != UNSET);
    }

    function testSetWithSigReservedSentinelRevertsAndConsumesNoNonce() external {
        uint256 deadline = block.timestamp + 5 minutes;
        bytes memory sig = _sign(alicePk, _setDigest(alice, UNSET, 0, deadline));
        vm.prank(relayer);
        vm.expectRevert(abi.encodeWithSelector(Adapter8004.PrimaryAgentIdReserved.selector, UNSET));
        adapter.setPrimaryAgentWithSig(alice, UNSET, deadline, sig);
        assertEq(adapter.nonces(alice), 0);
    }

    /* ------------------------------ deadline bounds ------------------------------ */

    function testDeadlinePastReverts() external {
        uint256 deadline = block.timestamp + 5 minutes;
        bytes memory sig = _sign(alicePk, _setDigest(alice, SMALL_ID, 0, deadline));
        vm.warp(deadline + 1);
        vm.expectRevert(abi.encodeWithSelector(Adapter8004.SignatureExpired.selector, deadline));
        adapter.setPrimaryAgentWithSig(alice, SMALL_ID, deadline, sig);
    }

    function testDeadlineTooFarReverts() external {
        uint256 deadline = block.timestamp + MAX_LIFETIME + 1;
        vm.expectRevert(abi.encodeWithSelector(Adapter8004.SignatureDeadlineTooFar.selector, deadline));
        adapter.setPrimaryAgentWithSig(alice, SMALL_ID, deadline, hex"");
    }

    function testDeadlineEqualToNowSucceeds() external {
        uint256 deadline = block.timestamp;
        bytes memory sig = _sign(alicePk, _setDigest(alice, SMALL_ID, 0, deadline));
        vm.prank(relayer);
        adapter.setPrimaryAgentWithSig(alice, SMALL_ID, deadline, sig);
        assertEq(adapter.primaryAgentOf(alice), SMALL_ID);
    }

    function testDeadlineAtMaxCapSucceeds() external {
        uint256 deadline = block.timestamp + MAX_LIFETIME;
        bytes memory sig = _sign(alicePk, _setDigest(alice, SMALL_ID, 0, deadline));
        vm.prank(relayer);
        adapter.setPrimaryAgentWithSig(alice, SMALL_ID, deadline, sig);
        assertEq(adapter.primaryAgentOf(alice), SMALL_ID);
    }

    /* --------------------------- wrong payload / signer -------------------------- */

    function testWrongSignerReverts() external {
        uint256 deadline = block.timestamp + 5 minutes;
        bytes memory sig = _sign(bobPk, _setDigest(alice, SMALL_ID, 0, deadline)); // bob signs alice's struct
        vm.expectRevert(Adapter8004.InvalidSignature.selector);
        adapter.setPrimaryAgentWithSig(alice, SMALL_ID, deadline, sig);
    }

    function testTamperedAgentIdReverts() external {
        uint256 deadline = block.timestamp + 5 minutes;
        bytes memory sig = _sign(alicePk, _setDigest(alice, SMALL_ID, 0, deadline));
        vm.expectRevert(Adapter8004.InvalidSignature.selector);
        adapter.setPrimaryAgentWithSig(alice, HASH_ID, deadline, sig); // different id submitted
    }

    function testTamperedDeadlineReverts() external {
        uint256 deadline = block.timestamp + 5 minutes;
        bytes memory sig = _sign(alicePk, _setDigest(alice, SMALL_ID, 0, deadline));
        vm.expectRevert(Adapter8004.InvalidSignature.selector);
        adapter.setPrimaryAgentWithSig(alice, SMALL_ID, deadline + 1, sig);
    }

    function testStaleNonceReverts() external {
        uint256 deadline = block.timestamp + 5 minutes;
        // sign against nonce 1 while on-chain nonce is 0
        bytes memory sig = _sign(alicePk, _setDigest(alice, SMALL_ID, 1, deadline));
        vm.expectRevert(Adapter8004.InvalidSignature.selector);
        adapter.setPrimaryAgentWithSig(alice, SMALL_ID, deadline, sig);
    }

    function testWrongOperationTypeReverts() external {
        // A clear-typed signature must not authorize a set.
        uint256 deadline = block.timestamp + 5 minutes;
        bytes memory clearSig = _sign(alicePk, _clearDigest(alice, 0, deadline));
        vm.expectRevert(Adapter8004.InvalidSignature.selector);
        adapter.setPrimaryAgentWithSig(alice, SMALL_ID, deadline, clearSig);
    }

    function testMalformedSignatureReverts() external {
        uint256 deadline = block.timestamp + 5 minutes;
        vm.expectRevert(Adapter8004.InvalidSignature.selector);
        adapter.setPrimaryAgentWithSig(alice, SMALL_ID, deadline, hex"deadbeef");
    }

    /* ------------------------------- domain sep --------------------------------- */

    function testCrossChainSignatureRejected() external {
        uint256 deadline = block.timestamp + 5 minutes;
        bytes32 digest =
            _digest(_domainSep(address(adapter), block.chainid + 1), _setStruct(alice, SMALL_ID, 0, deadline));
        bytes memory sig = _sign(alicePk, digest);
        vm.expectRevert(Adapter8004.InvalidSignature.selector);
        adapter.setPrimaryAgentWithSig(alice, SMALL_ID, deadline, sig);
    }

    function testCrossProxySignatureRejected() external {
        Adapter8004 other = _newAdapter();
        uint256 deadline = block.timestamp + 5 minutes;
        bytes memory sig = _sign(alicePk, _setDigest(alice, SMALL_ID, 0, deadline)); // bound to `adapter`
        vm.expectRevert(Adapter8004.InvalidSignature.selector);
        other.setPrimaryAgentWithSig(alice, SMALL_ID, deadline, sig);
    }

    /* --------------------------- replay / stale ordering ------------------------- */

    function testReplayConsumedSignatureReverts() external {
        uint256 deadline = block.timestamp + 5 minutes;
        bytes memory sig = _sign(alicePk, _setDigest(alice, SMALL_ID, 0, deadline));
        vm.prank(relayer);
        adapter.setPrimaryAgentWithSig(alice, SMALL_ID, deadline, sig);
        // second submission now fails against the incremented nonce
        vm.expectRevert(Adapter8004.InvalidSignature.selector);
        adapter.setPrimaryAgentWithSig(alice, SMALL_ID, deadline, sig);
        assertEq(adapter.nonces(alice), 1);
    }

    function testTwoSignaturesSameNonceOnlyOneSucceeds() external {
        uint256 deadline = block.timestamp + 5 minutes;
        bytes memory sigA = _sign(alicePk, _setDigest(alice, SMALL_ID, 0, deadline));
        bytes memory sigB = _sign(alicePk, _setDigest(alice, HASH_ID, 0, deadline));
        adapter.setPrimaryAgentWithSig(alice, SMALL_ID, deadline, sigA);
        vm.expectRevert(Adapter8004.InvalidSignature.selector);
        adapter.setPrimaryAgentWithSig(alice, HASH_ID, deadline, sigB);
    }

    function testSignedClearInvalidatesPriorSignedSet() external {
        uint256 deadline = block.timestamp + 5 minutes;
        bytes memory setSig = _sign(alicePk, _setDigest(alice, SMALL_ID, 0, deadline));
        bytes memory clearSig = _sign(alicePk, _clearDigest(alice, 0, deadline));
        // clear consumes nonce 0 first
        adapter.clearPrimaryAgentWithSig(alice, deadline, clearSig);
        assertEq(adapter.nonces(alice), 1);
        // the set pre-signed against nonce 0 is now stale
        vm.expectRevert(Adapter8004.InvalidSignature.selector);
        adapter.setPrimaryAgentWithSig(alice, SMALL_ID, deadline, setSig);
    }

    function testSignedSetInvalidatesPriorSignedClear() external {
        uint256 deadline = block.timestamp + 5 minutes;
        bytes memory setSig = _sign(alicePk, _setDigest(alice, SMALL_ID, 0, deadline));
        bytes memory clearSig = _sign(alicePk, _clearDigest(alice, 0, deadline));
        adapter.setPrimaryAgentWithSig(alice, SMALL_ID, deadline, setSig);
        vm.expectRevert(Adapter8004.InvalidSignature.selector);
        adapter.clearPrimaryAgentWithSig(alice, deadline, clearSig);
    }

    /* --------------------------- clearPrimaryAgentWithSig ------------------------ */

    function testClearWithSigHappyPathRelayer() external {
        uint256 deadline = block.timestamp + 5 minutes;
        // first set (nonce 0), then signed clear (nonce 1)
        adapter.setPrimaryAgentWithSig(
            alice, SMALL_ID, deadline, _sign(alicePk, _setDigest(alice, SMALL_ID, 0, deadline))
        );

        bytes memory clearSig = _sign(alicePk, _clearDigest(alice, 1, deadline));
        vm.expectEmit(true, true, true, true, address(adapter));
        emit PrimaryAgentCleared(alice, relayer);
        vm.expectEmit(true, true, true, true, address(adapter));
        emit PrimaryAgentClearedWithSig(alice, relayer, 1);
        vm.prank(relayer);
        adapter.clearPrimaryAgentWithSig(alice, deadline, clearSig);

        assertEq(adapter.primaryAgentOf(alice), UNSET);
        assertEq(adapter.nonces(alice), 2);
    }

    function testClearWithSigWrongSignerReverts() external {
        uint256 deadline = block.timestamp + 5 minutes;
        bytes memory sig = _sign(bobPk, _clearDigest(alice, 0, deadline));
        vm.expectRevert(Adapter8004.InvalidSignature.selector);
        adapter.clearPrimaryAgentWithSig(alice, deadline, sig);
    }

    /* -------------------- counterfactualRegisterAndSetPrimaryWithSig ------------- */

    function testCombinedEOAHappyPath() external {
        uint256 deadline = block.timestamp + 5 minutes;
        IERC8004IdentityRegistry.MetadataEntry[] memory md = _md("name", bytes("alpha"));
        bytes32 expectedHash = adapter.registrationHash(address(token721), 1);
        bytes memory sig =
            _sign(alicePk, _combinedDigest(address(token721), 1, "ipfs://a", md, address(0), alice, 0, deadline));

        vm.expectEmit(true, true, true, true, address(adapter));
        emit IERC8004AdapterCounterfactual.CounterfactualAgentRegistered(
            expectedHash, address(token721), 1, uint8(1), IERCAgentBindings.TokenStandard.ERC721, "ipfs://a", md, alice
        );
        vm.expectEmit(true, true, true, true, address(adapter));
        emit PrimaryAgentSet(alice, expectedHash, relayer);
        vm.expectEmit(true, true, true, true, address(adapter));
        emit PrimaryAgentSetWithSig(alice, expectedHash, relayer, 0);

        vm.prank(relayer);
        bytes32 got = adapter.counterfactualRegisterAndSetPrimaryWithSig(
            IERCAgentBindings.TokenStandard.ERC721,
            address(token721),
            1,
            "ipfs://a",
            md,
            address(0),
            alice,
            deadline,
            sig
        );

        assertEq(got, expectedHash);
        assertEq(adapter.primaryAgentOf(alice), expectedHash);
        assertEq(adapter.nonces(alice), 1);
    }

    function testCombinedEOAWithBundledWalletEmitsWalletEvent() external {
        uint256 deadline = block.timestamp + 5 minutes;
        IERC8004IdentityRegistry.MetadataEntry[] memory md = _empty();
        bytes32 expectedHash = adapter.registrationHash(address(token721), 1);
        bytes memory sig =
            _sign(alicePk, _combinedDigest(address(token721), 1, "ipfs://a", md, wallet, alice, 0, deadline));

        vm.recordLogs();
        vm.prank(relayer);
        adapter.counterfactualRegisterAndSetPrimaryWithSig(
            IERCAgentBindings.TokenStandard.ERC721, address(token721), 1, "ipfs://a", md, wallet, alice, deadline, sig
        );
        Vm.Log[] memory logs = vm.getRecordedLogs();
        // CounterfactualAgentRegistered, CounterfactualAgentWalletSet, PrimaryAgentSet, PrimaryAgentSetWithSig
        assertEq(logs.length, 4);
        assertEq(logs[0].topics[0], IERC8004AdapterCounterfactual.CounterfactualAgentRegistered.selector);
        assertEq(logs[1].topics[0], IERC8004AdapterCounterfactual.CounterfactualAgentWalletSet.selector);
        assertEq(logs[2].topics[0], PrimaryAgentSet.selector);
        assertEq(logs[3].topics[0], PrimaryAgentSetWithSig.selector);
        assertEq(adapter.primaryAgentOf(alice), expectedHash);
    }

    function testCombinedERC1271HappyPath() external {
        MockERC1271Account acct = new MockERC1271Account();
        token721.mint(address(acct), 7);
        uint256 deadline = block.timestamp + 5 minutes;
        IERC8004IdentityRegistry.MetadataEntry[] memory md = _empty();
        acct.approve(_combinedDigest(address(token721), 7, "ipfs://c", md, address(0), address(acct), 0, deadline));
        bytes32 expectedHash = adapter.registrationHash(address(token721), 7);

        vm.prank(relayer);
        bytes32 got = adapter.counterfactualRegisterAndSetPrimaryWithSig(
            IERCAgentBindings.TokenStandard.ERC721,
            address(token721),
            7,
            "ipfs://c",
            md,
            address(0),
            address(acct),
            deadline,
            hex"aa"
        );
        assertEq(got, expectedHash);
        assertEq(adapter.primaryAgentOf(address(acct)), expectedHash);
        assertEq(adapter.nonces(address(acct)), 1);
    }

    function testCombinedERC1271RejectionLeavesNoState() external {
        MockERC1271Account acct = new MockERC1271Account(); // approves nothing
        token721.mint(address(acct), 7);
        uint256 deadline = block.timestamp + 5 minutes;
        IERC8004IdentityRegistry.MetadataEntry[] memory md = _empty();

        vm.recordLogs();
        vm.prank(relayer);
        vm.expectRevert(Adapter8004.InvalidSignature.selector);
        adapter.counterfactualRegisterAndSetPrimaryWithSig(
            IERCAgentBindings.TokenStandard.ERC721,
            address(token721),
            7,
            "ipfs://c",
            md,
            address(0),
            address(acct),
            deadline,
            hex"aa"
        );
        assertEq(adapter.nonces(address(acct)), 0);
        assertEq(adapter.primaryAgentOf(address(acct)), UNSET);
    }

    function testCombinedNonHolderSignerReverts() external {
        // bob signs a combined payload for a token bob does not own (token 1 is alice's).
        uint256 deadline = block.timestamp + 5 minutes;
        IERC8004IdentityRegistry.MetadataEntry[] memory md = _empty();
        bytes memory sig =
            _sign(bobPk, _combinedDigest(address(token721), 1, "ipfs://a", md, address(0), bob, 0, deadline));
        vm.expectRevert(abi.encodeWithSelector(Adapter8004.NotController.selector, bob, type(uint256).max));
        adapter.counterfactualRegisterAndSetPrimaryWithSig(
            IERCAgentBindings.TokenStandard.ERC721, address(token721), 1, "ipfs://a", md, address(0), bob, deadline, sig
        );
    }

    /// Single-signer boundary: a signature is bound to one `signer` used for BOTH the direct-control
    /// check and the primary account; you cannot register with alice's token but point bob.
    function testCombinedSingleSignerBoundaryCannotRegisterXPointY() external {
        uint256 deadline = block.timestamp + 5 minutes;
        IERC8004IdentityRegistry.MetadataEntry[] memory md = _empty();
        // alice (token owner) signs, but caller submits signer=bob -> alice's sig invalid for bob struct,
        // and bob doesn't own the token. Either way it cannot bind alice's token to bob's pointer.
        bytes memory aliceSig =
            _sign(alicePk, _combinedDigest(address(token721), 1, "ipfs://a", md, address(0), alice, 0, deadline));
        // Submit with signer=bob: bob is not the token holder -> NotController before signature check.
        vm.expectRevert(abi.encodeWithSelector(Adapter8004.NotController.selector, bob, type(uint256).max));
        adapter.counterfactualRegisterAndSetPrimaryWithSig(
            IERCAgentBindings.TokenStandard.ERC721,
            address(token721),
            1,
            "ipfs://a",
            md,
            address(0),
            bob,
            deadline,
            aliceSig
        );
    }

    /// The deliberately-split X/Y workflow works only as two standalone signed calls.
    function testSplitWorkflowWorksAsTwoStandaloneCalls() external {
        uint256 deadline = block.timestamp + 5 minutes;
        IERC8004IdentityRegistry.MetadataEntry[] memory md = _empty();
        // 1) alice registers her counterfactual agent for token 1 (standalone signed register).
        bytes memory regSig =
            _signCounterfactual(alicePk, address(token721), 1, "ipfs://a", md, address(0), alice, deadline);
        bytes32 hash = adapter.counterfactualRegisterWithSig(
            IERCAgentBindings.TokenStandard.ERC721,
            address(token721),
            1,
            "ipfs://a",
            md,
            address(0),
            alice,
            deadline,
            regSig
        );
        // 2) bob points his own primary agent at that hash via a standalone signed set.
        bytes memory setSig = _sign(bobPk, _setDigest(bob, hash, 0, deadline));
        adapter.setPrimaryAgentWithSig(bob, hash, deadline, setSig);
        assertEq(adapter.primaryAgentOf(bob), hash);
    }

    /// Derived-id correctness: independently derive the hash and mutate a coordinate to prove binding.
    function testCombinedDerivedIdMatchesAndTamperFails() external {
        uint256 deadline = block.timestamp + 5 minutes;
        IERC8004IdentityRegistry.MetadataEntry[] memory md = _empty();
        bytes32 derived = keccak256(abi.encode(block.chainid, address(adapter), address(token721), uint256(1)));
        assertEq(derived, adapter.registrationHash(address(token721), 1));

        bytes memory sig =
            _sign(alicePk, _combinedDigest(address(token721), 1, "ipfs://a", md, address(0), alice, 0, deadline));
        // Tamper the tokenId submitted vs signed -> InvalidSignature (and alice owns 1 not 2, but sig check fails first on payload binding for id 1's sig used against id-2 struct). Use token 1 signed, submit token owned check ok but struct differs.
        bytes memory sig2 = _sign(
            alicePk, _combinedDigest(address(token721), 1, "ipfs://DIFFERENT", md, address(0), alice, 0, deadline)
        );
        vm.expectRevert(Adapter8004.InvalidSignature.selector);
        adapter.counterfactualRegisterAndSetPrimaryWithSig(
            IERCAgentBindings.TokenStandard.ERC721,
            address(token721),
            1,
            "ipfs://a",
            md,
            address(0),
            alice,
            deadline,
            sig2
        );
        // Correct sig sets the derived hash.
        vm.prank(relayer);
        bytes32 got = adapter.counterfactualRegisterAndSetPrimaryWithSig(
            IERCAgentBindings.TokenStandard.ERC721,
            address(token721),
            1,
            "ipfs://a",
            md,
            address(0),
            alice,
            deadline,
            sig
        );
        assertEq(got, derived);
        assertEq(adapter.primaryAgentOf(alice), derived);
    }

    function testCombinedReRegistrationIdempotencyConsumesFreshNonce() external {
        uint256 deadline = block.timestamp + 5 minutes;
        IERC8004IdentityRegistry.MetadataEntry[] memory md = _empty();
        bytes memory sig0 =
            _sign(alicePk, _combinedDigest(address(token721), 1, "ipfs://a", md, address(0), alice, 0, deadline));
        adapter.counterfactualRegisterAndSetPrimaryWithSig(
            IERCAgentBindings.TokenStandard.ERC721,
            address(token721),
            1,
            "ipfs://a",
            md,
            address(0),
            alice,
            deadline,
            sig0
        );
        assertEq(adapter.nonces(alice), 1);
        // identical coordinates, fresh nonce 1 -> not an error, re-emits and reaffirms primary.
        bytes memory sig1 =
            _sign(alicePk, _combinedDigest(address(token721), 1, "ipfs://a", md, address(0), alice, 1, deadline));
        bytes32 got = adapter.counterfactualRegisterAndSetPrimaryWithSig(
            IERCAgentBindings.TokenStandard.ERC721,
            address(token721),
            1,
            "ipfs://a",
            md,
            address(0),
            alice,
            deadline,
            sig1
        );
        assertEq(got, adapter.registrationHash(address(token721), 1));
        assertEq(adapter.nonces(alice), 2);
    }

    function testCombinedReplayConsumedNonceReverts() external {
        uint256 deadline = block.timestamp + 5 minutes;
        IERC8004IdentityRegistry.MetadataEntry[] memory md = _empty();
        bytes memory sig =
            _sign(alicePk, _combinedDigest(address(token721), 1, "ipfs://a", md, address(0), alice, 0, deadline));
        adapter.counterfactualRegisterAndSetPrimaryWithSig(
            IERCAgentBindings.TokenStandard.ERC721,
            address(token721),
            1,
            "ipfs://a",
            md,
            address(0),
            alice,
            deadline,
            sig
        );
        vm.expectRevert(Adapter8004.InvalidSignature.selector);
        adapter.counterfactualRegisterAndSetPrimaryWithSig(
            IERCAgentBindings.TokenStandard.ERC721,
            address(token721),
            1,
            "ipfs://a",
            md,
            address(0),
            alice,
            deadline,
            sig
        );
    }

    /// Shared stream: a successful combined call invalidates a set pre-signed with the same nonce.
    function testCombinedSharesNonceStreamWithSet() external {
        uint256 deadline = block.timestamp + 5 minutes;
        IERC8004IdentityRegistry.MetadataEntry[] memory md = _empty();
        bytes memory setSig = _sign(alicePk, _setDigest(alice, SMALL_ID, 0, deadline));
        bytes memory combinedSig =
            _sign(alicePk, _combinedDigest(address(token721), 1, "ipfs://a", md, address(0), alice, 0, deadline));
        adapter.counterfactualRegisterAndSetPrimaryWithSig(
            IERCAgentBindings.TokenStandard.ERC721,
            address(token721),
            1,
            "ipfs://a",
            md,
            address(0),
            alice,
            deadline,
            combinedSig
        );
        vm.expectRevert(Adapter8004.InvalidSignature.selector);
        adapter.setPrimaryAgentWithSig(alice, SMALL_ID, deadline, setSig);
    }

    function testCombinedDeadlineTooFarReverts() external {
        uint256 deadline = block.timestamp + MAX_LIFETIME + 1;
        IERC8004IdentityRegistry.MetadataEntry[] memory md = _empty();
        vm.expectRevert(abi.encodeWithSelector(Adapter8004.SignatureDeadlineTooFar.selector, deadline));
        adapter.counterfactualRegisterAndSetPrimaryWithSig(
            IERCAgentBindings.TokenStandard.ERC721,
            address(token721),
            1,
            "ipfs://a",
            md,
            address(0),
            alice,
            deadline,
            hex""
        );
    }

    /// Atomic rollback: force the second half (`_setPrimaryAgent`) to revert via the reserved-hash
    /// harness; the whole call reverts, no nonce consumed, no pointer change, and no logs.
    function testCombinedReservedDerivedHashRollsBackAtomically() external {
        Adapter8004 harness = _newHarness();
        MockERC721 t = new MockERC721();
        t.mint(alice, 1);
        uint256 deadline = block.timestamp + 5 minutes;
        IERC8004IdentityRegistry.MetadataEntry[] memory md = _empty();
        // Sign against the harness's domain (its own address) with nonce 0.
        bytes32 digest = _digest(
            _domainSep(address(harness), block.chainid),
            _combinedStruct(address(t), 1, "ipfs://a", md, address(0), alice, 0, deadline)
        );
        bytes memory sig = _sign(alicePk, digest);

        // The second half (`_setPrimaryAgent`) reverts on the reserved all-ones derived hash; the whole
        // transaction reverts, so the earlier nonce increment and counterfactual emission are rolled
        // back (a reverted tx persists no logs on-chain). State assertions below prove the rollback;
        // `vm.recordLogs` is intentionally not used here because it captures LOG opcodes before a revert
        // unwinds and therefore cannot model on-chain log rollback.
        vm.expectRevert(abi.encodeWithSelector(Adapter8004.PrimaryAgentIdReserved.selector, UNSET));
        harness.counterfactualRegisterAndSetPrimaryWithSig(
            IERCAgentBindings.TokenStandard.ERC721, address(t), 1, "ipfs://a", md, address(0), alice, deadline, sig
        );
        assertEq(harness.nonces(alice), 0);
        assertEq(harness.primaryAgentOf(alice), UNSET);
    }

    /* ------------------------------ upgrade / layout ---------------------------- */

    function testSeededProxyUpgradePreservesSlot2AndNoncesStartZero() external {
        // Seed a nonzero complement-encoded slot-2 value via a paid set.
        vm.prank(alice);
        adapter.setPrimaryAgent(HASH_ID);
        assertEq(adapter.primaryAgentOf(alice), HASH_ID);

        // Upgrade the proxy to a freshly deployed implementation (same layout).
        Adapter8004 newImpl = new Adapter8004();
        vm.prank(admin);
        UUPSUpgradeable(address(adapter)).upgradeToAndCall(address(newImpl), "");

        // Slot-2 claim reads identically; nonces begin at zero.
        assertEq(adapter.primaryAgentOf(alice), HASH_ID);
        assertEq(adapter.nonces(alice), 0);
    }

    /* --------------------------------- ABI/types -------------------------------- */

    function testExactTypehashes() external pure {
        assertEq(
            SET_PRIMARY_AGENT_TYPEHASH,
            keccak256("SetPrimaryAgent(address account,bytes32 agentId,uint256 nonce,uint256 deadline)")
        );
        assertEq(
            CLEAR_PRIMARY_AGENT_TYPEHASH, keccak256("ClearPrimaryAgent(address account,uint256 nonce,uint256 deadline)")
        );
        assertEq(
            COMBINED_TYPEHASH,
            keccak256(
                "CounterfactualRegisterAndSetPrimary(uint8 standard,address tokenContract,uint256 tokenId,string agentURI,MetadataEntry[] metadata,address agentWallet,address signer,uint256 nonce,uint256 deadline)MetadataEntry(string metadataKey,bytes metadataValue)"
            )
        );
    }

    /// Interface implementation coverage: the adapter satisfies the extended interface incl. the new
    /// signed functions and `nonces`.
    function testImplementsExtendedPrimaryAgentInterface() external view {
        IERC8004AdapterPrimaryAgent i = IERC8004AdapterPrimaryAgent(address(adapter));
        assertEq(i.nonces(alice), 0);
        assertEq(i.PRIMARY_AGENT_UNSET(), UNSET);
    }

    /* ---------------------------------- helpers --------------------------------- */

    function _setStruct(address account, bytes32 agentId, uint256 nonce, uint256 deadline)
        internal
        pure
        returns (bytes32)
    {
        return keccak256(abi.encode(SET_PRIMARY_AGENT_TYPEHASH, account, agentId, nonce, deadline));
    }

    function _clearStruct(address account, uint256 nonce, uint256 deadline) internal pure returns (bytes32) {
        return keccak256(abi.encode(CLEAR_PRIMARY_AGENT_TYPEHASH, account, nonce, deadline));
    }

    function _combinedStruct(
        address tokenContract,
        uint256 tokenId,
        string memory agentURI,
        IERC8004IdentityRegistry.MetadataEntry[] memory md,
        address agentWallet,
        address signer,
        uint256 nonce,
        uint256 deadline
    ) internal pure returns (bytes32) {
        return keccak256(
            abi.encode(
                COMBINED_TYPEHASH,
                uint8(IERCAgentBindings.TokenStandard.ERC721),
                tokenContract,
                tokenId,
                keccak256(bytes(agentURI)),
                _hashMetadata(md),
                agentWallet,
                signer,
                nonce,
                deadline
            )
        );
    }

    function _setDigest(address account, bytes32 agentId, uint256 nonce, uint256 deadline)
        internal
        view
        returns (bytes32)
    {
        return _digest(_domainSep(address(adapter), block.chainid), _setStruct(account, agentId, nonce, deadline));
    }

    function _clearDigest(address account, uint256 nonce, uint256 deadline) internal view returns (bytes32) {
        return _digest(_domainSep(address(adapter), block.chainid), _clearStruct(account, nonce, deadline));
    }

    function _combinedDigest(
        address tokenContract,
        uint256 tokenId,
        string memory agentURI,
        IERC8004IdentityRegistry.MetadataEntry[] memory md,
        address agentWallet,
        address signer,
        uint256 nonce,
        uint256 deadline
    ) internal view returns (bytes32) {
        return _digest(
            _domainSep(address(adapter), block.chainid),
            _combinedStruct(tokenContract, tokenId, agentURI, md, agentWallet, signer, nonce, deadline)
        );
    }

    function _digest(bytes32 domainSep, bytes32 structHash) internal pure returns (bytes32) {
        return keccak256(abi.encodePacked(hex"1901", domainSep, structHash));
    }

    function _domainSep(address verifyingContract, uint256 chainId) internal pure returns (bytes32) {
        return keccak256(
            abi.encode(
                DOMAIN_TYPEHASH, keccak256(bytes("Adapter8004")), keccak256(bytes("1")), chainId, verifyingContract
            )
        );
    }

    function _sign(uint256 pk, bytes32 digest) internal pure returns (bytes memory) {
        (uint8 v, bytes32 r, bytes32 s) = vm.sign(pk, digest);
        return abi.encodePacked(r, s, v);
    }

    // Standalone counterfactual register digest (for the split-workflow test).
    function _signCounterfactual(
        uint256 pk,
        address tokenContract,
        uint256 tokenId,
        string memory agentURI,
        IERC8004IdentityRegistry.MetadataEntry[] memory md,
        address agentWallet,
        address owner,
        uint256 expiration
    ) internal view returns (bytes memory) {
        bytes32 typehash = keccak256(
            "CounterfactualRegister(uint8 standard,address tokenContract,uint256 tokenId,string agentURI,MetadataEntry[] metadata,address agentWallet,address owner,uint256 expiration)MetadataEntry(string metadataKey,bytes metadataValue)"
        );
        bytes32 structHash = keccak256(
            abi.encode(
                typehash,
                uint8(IERCAgentBindings.TokenStandard.ERC721),
                tokenContract,
                tokenId,
                keccak256(bytes(agentURI)),
                _hashMetadata(md),
                agentWallet,
                owner,
                expiration
            )
        );
        return _sign(pk, _digest(_domainSep(address(adapter), block.chainid), structHash));
    }

    function _hashMetadata(IERC8004IdentityRegistry.MetadataEntry[] memory entries) internal pure returns (bytes32) {
        bytes32[] memory hashes = new bytes32[](entries.length);
        for (uint256 i; i < entries.length; ++i) {
            hashes[i] = keccak256(
                abi.encode(
                    METADATA_ENTRY_TYPEHASH,
                    keccak256(bytes(entries[i].metadataKey)),
                    keccak256(entries[i].metadataValue)
                )
            );
        }
        return keccak256(abi.encodePacked(hashes));
    }

    function _md(string memory k, bytes memory v)
        internal
        pure
        returns (IERC8004IdentityRegistry.MetadataEntry[] memory md)
    {
        md = new IERC8004IdentityRegistry.MetadataEntry[](1);
        md[0] = IERC8004IdentityRegistry.MetadataEntry({metadataKey: k, metadataValue: v});
    }

    function _empty() internal pure returns (IERC8004IdentityRegistry.MetadataEntry[] memory md) {
        md = new IERC8004IdentityRegistry.MetadataEntry[](0);
    }

    function _newAdapter() internal returns (Adapter8004) {
        Adapter8004 impl = new Adapter8004();
        ERC1967Proxy proxy =
            new ERC1967Proxy(address(impl), abi.encodeCall(Adapter8004.initialize, (address(registry), admin)));
        return Adapter8004(address(proxy));
    }

    function _newHarness() internal returns (Adapter8004) {
        Adapter8004ReservedHashHarness impl = new Adapter8004ReservedHashHarness();
        ERC1967Proxy proxy =
            new ERC1967Proxy(address(impl), abi.encodeCall(Adapter8004.initialize, (address(registry), admin)));
        return Adapter8004(address(proxy));
    }
}

/// @dev Minimal ERC-1271 account that returns the magic value only for pre-approved digests.
contract MockERC1271Account is IERC1271 {
    bytes4 internal constant MAGIC = 0x1626ba7e;
    mapping(bytes32 => bool) public approved;

    function approve(bytes32 digest) external {
        approved[digest] = true;
    }

    function isValidSignature(bytes32 digest, bytes memory) external view returns (bytes4) {
        return approved[digest] ? MAGIC : bytes4(0xffffffff);
    }
}

/// @dev ERC-1271 account that ALWAYS rejects but exposes an `owner()`. Proves the signed path does not
/// fall back to owner()/controller discovery: even the owner's valid EOA signature is refused.
contract RejectingOwnedERC1271 is IERC1271 {
    address public owner;

    constructor(address owner_) {
        owner = owner_;
    }

    function isValidSignature(bytes32, bytes memory) external pure returns (bytes4) {
        return bytes4(0xffffffff);
    }
}
