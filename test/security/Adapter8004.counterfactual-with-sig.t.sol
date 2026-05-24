// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Test, Vm} from "forge-std/Test.sol";
import {ERC1967Proxy} from "@openzeppelin/contracts/proxy/ERC1967/ERC1967Proxy.sol";
import {IERC1271} from "@openzeppelin/contracts/interfaces/IERC1271.sol";

import {Adapter8004} from "../../src/Adapter8004.sol";
import {IERC8004AdapterCounterfactual} from "../../src/interfaces/IERC8004AdapterCounterfactual.sol";
import {IERCAgentBindings} from "../../src/interfaces/IERCAgentBindings.sol";
import {IERC8004IdentityRegistry} from "../../src/interfaces/IERC8004IdentityRegistry.sol";

import {MockIdentityRegistry} from "../mocks/MockIdentityRegistry.sol";
import {MockERC721} from "../mocks/MockERC721.sol";
import {MockERC1155} from "../mocks/MockERC1155.sol";
import {MockERC1155F} from "../mocks/MockERC1155F.sol";
import {MockERC6909} from "../mocks/MockERC6909.sol";
import {MockERC6909F} from "../mocks/MockERC6909F.sol";
import {MockDelegateRegistry} from "../mocks/MockDelegateRegistry.sol";
import {ReentrantERC721} from "./mocks/ReentrantERC721.sol";

interface ICounterfactualWithSigReentrancyErrors {
    error ReentrancyGuardReentrantCall();
}

contract CounterfactualWithSigSecurityTest is Test {
    bytes32 internal constant DOMAIN_TYPEHASH =
        keccak256("EIP712Domain(string name,string version,uint256 chainId,address verifyingContract)");
    bytes32 internal constant COUNTERFACTUAL_REGISTER_TYPEHASH = keccak256(
        "CounterfactualRegister(uint8 standard,address tokenContract,uint256 tokenId,bytes32 agentURIHash,bytes32 metadataHash,address agentWallet,address owner,uint256 expiration)"
    );
    bytes32 internal constant METADATA_ENTRY_TYPEHASH =
        keccak256("MetadataEntry(string metadataKey,bytes metadataValue)");
    uint256 internal constant MAX_EXPIRATION_DELAY = 30 minutes;

    MockIdentityRegistry internal registry;
    Adapter8004 internal adapter;
    MockERC721 internal token721;
    MockERC1155 internal token1155;
    MockERC1155F internal token1155F;
    MockERC6909 internal token6909;
    MockERC6909F internal token6909F;

    uint256 internal alicePk = 0xA11CE;
    uint256 internal bobPk = 0xB0B;
    uint256 internal hotPk = 0xA11CEB0B;
    address internal alice;
    address internal bob;
    address internal hot;
    address internal relayer = makeAddr("relayer");
    address internal wallet = makeAddr("wallet");
    address internal admin = makeAddr("admin");

    function setUp() external {
        alice = vm.addr(alicePk);
        bob = vm.addr(bobPk);
        hot = vm.addr(hotPk);

        registry = new MockIdentityRegistry();
        Adapter8004 implementation = new Adapter8004();
        ERC1967Proxy proxy = new ERC1967Proxy(
            address(implementation), abi.encodeCall(Adapter8004.initialize, (address(registry), admin))
        );
        adapter = Adapter8004(address(proxy));

        token721 = new MockERC721();
        token1155 = new MockERC1155();
        token1155F = new MockERC1155F();
        token6909 = new MockERC6909();
        token6909F = new MockERC6909F();

        token721.mint(alice, 1);
        token721.mint(alice, 2);
        token721.mint(bob, 3);
        token1155.mint(alice, 10, 1);
        token1155F.mint(alice, 50);
        token6909.mint(alice, 42, 1);
        token6909F.mint(alice, 60);
    }

    function testCounterfactualRegisterWithSigEOAHappyPathRelayer() external {
        IERC8004IdentityRegistry.MetadataEntry[] memory metadata = _metadata("name", bytes("alpha"));
        uint256 expiration = block.timestamp + 10 minutes;
        bytes memory signature =
            _sign(alicePk, address(adapter), block.chainid, 1, "ipfs://agent", metadata, address(0), alice, expiration);
        bytes32 expectedHash = adapter.registrationHash(IERCAgentBindings.TokenStandard.ERC721, address(token721), 1);

        vm.prank(relayer);
        vm.expectEmit(true, true, true, true, address(adapter));
        emit IERC8004AdapterCounterfactual.CounterfactualAgentRegistered(
            expectedHash,
            address(token721),
            1,
            uint8(1),
            IERCAgentBindings.TokenStandard.ERC721,
            "ipfs://agent",
            metadata,
            alice
        );
        bytes32 actual = adapter.counterfactualRegisterWithSig(
            IERCAgentBindings.TokenStandard.ERC721,
            address(token721),
            1,
            "ipfs://agent",
            metadata,
            address(0),
            alice,
            expiration,
            signature
        );

        assertEq(actual, expectedHash);
    }

    function testCounterfactualRegisterWithSigEOAWithBundledWallet() external {
        IERC8004IdentityRegistry.MetadataEntry[] memory metadata = _emptyMetadata();
        uint256 expiration = block.timestamp + 10 minutes;
        bytes memory signature =
            _sign(alicePk, address(adapter), block.chainid, 1, "ipfs://agent", metadata, wallet, alice, expiration);
        bytes32 expectedHash = adapter.registrationHash(IERCAgentBindings.TokenStandard.ERC721, address(token721), 1);

        vm.prank(relayer);
        vm.expectEmit(true, true, true, true, address(adapter));
        emit IERC8004AdapterCounterfactual.CounterfactualAgentRegistered(
            expectedHash,
            address(token721),
            1,
            uint8(1),
            IERCAgentBindings.TokenStandard.ERC721,
            "ipfs://agent",
            metadata,
            alice
        );
        vm.expectEmit(true, true, true, true, address(adapter));
        emit IERC8004AdapterCounterfactual.CounterfactualAgentWalletSet(
            expectedHash, address(token721), 1, uint8(1), wallet, alice
        );
        adapter.counterfactualRegisterWithSig(
            IERCAgentBindings.TokenStandard.ERC721,
            address(token721),
            1,
            "ipfs://agent",
            metadata,
            wallet,
            alice,
            expiration,
            signature
        );
    }

    function testCounterfactualRegisterWithSigZeroWalletEmitsOnlyRegistration() external {
        IERC8004IdentityRegistry.MetadataEntry[] memory metadata = _emptyMetadata();
        uint256 expiration = block.timestamp + 10 minutes;
        bytes memory signature =
            _sign(alicePk, address(adapter), block.chainid, 1, "ipfs://agent", metadata, address(0), alice, expiration);

        vm.recordLogs();
        vm.prank(relayer);
        adapter.counterfactualRegisterWithSig(
            IERCAgentBindings.TokenStandard.ERC721,
            address(token721),
            1,
            "ipfs://agent",
            metadata,
            address(0),
            alice,
            expiration,
            signature
        );

        Vm.Log[] memory logs = vm.getRecordedLogs();
        assertEq(logs.length, 1);
        assertEq(logs[0].topics[0], IERC8004AdapterCounterfactual.CounterfactualAgentRegistered.selector);
    }

    function testCounterfactualRegisterWithSigERC1271OwnerHappyPath() external {
        IERC8004IdentityRegistry.MetadataEntry[] memory metadata = _metadata("k", bytes("v"));
        MockERC1271Owner owner = new MockERC1271Owner();
        token721.mint(address(owner), 99);
        uint256 expiration = block.timestamp + 10 minutes;
        bytes32 digest = _digest(
            address(adapter), block.chainid, 99, "ipfs://1271", metadata, address(0), address(owner), expiration
        );
        owner.setValidDigest(digest, true);

        vm.prank(relayer);
        bytes32 actual = adapter.counterfactualRegisterWithSig(
            IERCAgentBindings.TokenStandard.ERC721,
            address(token721),
            99,
            "ipfs://1271",
            metadata,
            address(0),
            address(owner),
            expiration,
            hex"1234"
        );

        assertEq(actual, adapter.registrationHash(IERCAgentBindings.TokenStandard.ERC721, address(token721), 99));
    }

    function testCounterfactualRegisterWithSigRejectsBadERC1271Signature() external {
        IERC8004IdentityRegistry.MetadataEntry[] memory metadata = _emptyMetadata();
        MockERC1271Owner owner = new MockERC1271Owner();
        token721.mint(address(owner), 99);
        uint256 expiration = block.timestamp + 10 minutes;

        vm.prank(relayer);
        vm.expectRevert(Adapter8004.InvalidSignature.selector);
        adapter.counterfactualRegisterWithSig(
            IERCAgentBindings.TokenStandard.ERC721,
            address(token721),
            99,
            "ipfs://1271",
            metadata,
            address(0),
            address(owner),
            expiration,
            hex"1234"
        );
    }

    function testCounterfactualRegisterWithSigExpiredExpiration() external {
        IERC8004IdentityRegistry.MetadataEntry[] memory metadata = _emptyMetadata();
        uint256 expiration = block.timestamp;
        bytes memory signature =
            _sign(alicePk, address(adapter), block.chainid, 1, "ipfs://agent", metadata, address(0), alice, expiration);
        vm.warp(expiration + 1);

        vm.expectRevert(abi.encodeWithSelector(Adapter8004.SignatureExpired.selector, expiration));
        adapter.counterfactualRegisterWithSig(
            IERCAgentBindings.TokenStandard.ERC721,
            address(token721),
            1,
            "ipfs://agent",
            metadata,
            address(0),
            alice,
            expiration,
            signature
        );
    }

    function testCounterfactualRegisterWithSigExpirationTooFar() external {
        IERC8004IdentityRegistry.MetadataEntry[] memory metadata = _emptyMetadata();
        uint256 expiration = block.timestamp + MAX_EXPIRATION_DELAY + 1;

        vm.expectRevert(abi.encodeWithSelector(Adapter8004.ExpirationTooFar.selector, expiration));
        adapter.counterfactualRegisterWithSig(
            IERCAgentBindings.TokenStandard.ERC721,
            address(token721),
            1,
            "ipfs://agent",
            metadata,
            address(0),
            alice,
            expiration,
            hex""
        );
    }

    function testCounterfactualRegisterWithSigAtExpirationSucceeds() external {
        IERC8004IdentityRegistry.MetadataEntry[] memory metadata = _emptyMetadata();
        uint256 expiration = block.timestamp + 10 minutes;
        bytes memory signature =
            _sign(alicePk, address(adapter), block.chainid, 1, "ipfs://agent", metadata, address(0), alice, expiration);
        vm.warp(expiration);

        adapter.counterfactualRegisterWithSig(
            IERCAgentBindings.TokenStandard.ERC721,
            address(token721),
            1,
            "ipfs://agent",
            metadata,
            address(0),
            alice,
            expiration,
            signature
        );
    }

    function testCounterfactualRegisterWithSigAtMaxExpirationSucceeds() external {
        IERC8004IdentityRegistry.MetadataEntry[] memory metadata = _emptyMetadata();
        uint256 expiration = block.timestamp + MAX_EXPIRATION_DELAY;
        bytes memory signature =
            _sign(alicePk, address(adapter), block.chainid, 1, "ipfs://agent", metadata, address(0), alice, expiration);

        adapter.counterfactualRegisterWithSig(
            IERCAgentBindings.TokenStandard.ERC721,
            address(token721),
            1,
            "ipfs://agent",
            metadata,
            address(0),
            alice,
            expiration,
            signature
        );
    }

    function testCounterfactualRegisterWithSigNonOwnerSignerRejected() external {
        IERC8004IdentityRegistry.MetadataEntry[] memory metadata = _emptyMetadata();
        uint256 expiration = block.timestamp + 10 minutes;
        bytes memory signature =
            _sign(bobPk, address(adapter), block.chainid, 1, "ipfs://agent", metadata, address(0), bob, expiration);

        vm.expectRevert(abi.encodeWithSelector(Adapter8004.NotController.selector, bob, type(uint256).max));
        adapter.counterfactualRegisterWithSig(
            IERCAgentBindings.TokenStandard.ERC721,
            address(token721),
            1,
            "ipfs://agent",
            metadata,
            address(0),
            bob,
            expiration,
            signature
        );
    }

    function testCounterfactualRegisterWithSigFormerOwnerReplayAfterTransferRejected() external {
        IERC8004IdentityRegistry.MetadataEntry[] memory metadata = _emptyMetadata();
        uint256 expiration = block.timestamp + 10 minutes;
        bytes memory signature =
            _sign(alicePk, address(adapter), block.chainid, 1, "ipfs://agent", metadata, address(0), alice, expiration);
        vm.prank(alice);
        token721.safeTransferFrom(alice, bob, 1);

        vm.expectRevert(abi.encodeWithSelector(Adapter8004.NotController.selector, alice, type(uint256).max));
        adapter.counterfactualRegisterWithSig(
            IERCAgentBindings.TokenStandard.ERC721,
            address(token721),
            1,
            "ipfs://agent",
            metadata,
            address(0),
            alice,
            expiration,
            signature
        );
    }

    function testCounterfactualRegisterWithSigIdenticalReplayDuringTenureEmitsAgain() external {
        IERC8004IdentityRegistry.MetadataEntry[] memory metadata = _metadata("name", bytes("alpha"));
        uint256 expiration = block.timestamp + 10 minutes;
        bytes memory signature =
            _sign(alicePk, address(adapter), block.chainid, 1, "ipfs://agent", metadata, wallet, alice, expiration);

        vm.recordLogs();
        adapter.counterfactualRegisterWithSig(
            IERCAgentBindings.TokenStandard.ERC721,
            address(token721),
            1,
            "ipfs://agent",
            metadata,
            wallet,
            alice,
            expiration,
            signature
        );
        adapter.counterfactualRegisterWithSig(
            IERCAgentBindings.TokenStandard.ERC721,
            address(token721),
            1,
            "ipfs://agent",
            metadata,
            wallet,
            alice,
            expiration,
            signature
        );

        Vm.Log[] memory logs = vm.getRecordedLogs();
        assertEq(logs.length, 4);
        assertEq(logs[0].topics[1], logs[2].topics[1]);
        assertEq(logs[1].topics[1], logs[3].topics[1]);
    }

    function testCounterfactualRegisterWithSigSupersededReplayAllowedUntilExpiration() external {
        IERC8004IdentityRegistry.MetadataEntry[] memory metadata = _emptyMetadata();
        uint256 expiration = block.timestamp + 10 minutes;
        bytes memory sigA =
            _sign(alicePk, address(adapter), block.chainid, 1, "ipfs://a", metadata, address(0), alice, expiration);
        bytes memory sigB =
            _sign(alicePk, address(adapter), block.chainid, 1, "ipfs://b", metadata, address(0), alice, expiration);

        adapter.counterfactualRegisterWithSig(
            IERCAgentBindings.TokenStandard.ERC721,
            address(token721),
            1,
            "ipfs://b",
            metadata,
            address(0),
            alice,
            expiration,
            sigB
        );
        adapter.counterfactualRegisterWithSig(
            IERCAgentBindings.TokenStandard.ERC721,
            address(token721),
            1,
            "ipfs://a",
            metadata,
            address(0),
            alice,
            expiration,
            sigA
        );
    }

    function testCounterfactualRegisterWithSigSupersededReplayRejectedAfterExpiration() external {
        IERC8004IdentityRegistry.MetadataEntry[] memory metadata = _emptyMetadata();
        uint256 expiration = block.timestamp + 10 minutes;
        bytes memory sigA =
            _sign(alicePk, address(adapter), block.chainid, 1, "ipfs://a", metadata, address(0), alice, expiration);
        bytes memory sigB = _sign(
            alicePk,
            address(adapter),
            block.chainid,
            1,
            "ipfs://b",
            metadata,
            address(0),
            alice,
            block.timestamp + 20 minutes
        );

        adapter.counterfactualRegisterWithSig(
            IERCAgentBindings.TokenStandard.ERC721,
            address(token721),
            1,
            "ipfs://b",
            metadata,
            address(0),
            alice,
            block.timestamp + 20 minutes,
            sigB
        );
        vm.warp(expiration + 1);
        vm.expectRevert(abi.encodeWithSelector(Adapter8004.SignatureExpired.selector, expiration));
        adapter.counterfactualRegisterWithSig(
            IERCAgentBindings.TokenStandard.ERC721,
            address(token721),
            1,
            "ipfs://a",
            metadata,
            address(0),
            alice,
            expiration,
            sigA
        );
    }

    function testCounterfactualRegisterWithSigRejectsTamperedAgentURI() external {
        IERC8004IdentityRegistry.MetadataEntry[] memory metadata = _emptyMetadata();
        uint256 expiration = block.timestamp + 10 minutes;
        bytes memory signature =
            _sign(alicePk, address(adapter), block.chainid, 1, "ipfs://a", metadata, address(0), alice, expiration);
        _expectInvalidSignature(1, "ipfs://b", metadata, address(0), alice, expiration, signature);
    }

    function testCounterfactualRegisterWithSigRejectsTamperedMetadataValue() external {
        IERC8004IdentityRegistry.MetadataEntry[] memory signedMetadata = _metadata("k", bytes("a"));
        IERC8004IdentityRegistry.MetadataEntry[] memory submittedMetadata = _metadata("k", bytes("b"));
        uint256 expiration = block.timestamp + 10 minutes;
        bytes memory signature = _sign(
            alicePk, address(adapter), block.chainid, 1, "ipfs://agent", signedMetadata, address(0), alice, expiration
        );
        _expectInvalidSignature(1, "ipfs://agent", submittedMetadata, address(0), alice, expiration, signature);
    }

    function testCounterfactualRegisterWithSigRejectsTamperedMetadataOrder() external {
        IERC8004IdentityRegistry.MetadataEntry[] memory signedMetadata = _metadata2("a", bytes("1"), "b", bytes("2"));
        IERC8004IdentityRegistry.MetadataEntry[] memory submittedMetadata = _metadata2("b", bytes("2"), "a", bytes("1"));
        uint256 expiration = block.timestamp + 10 minutes;
        bytes memory signature = _sign(
            alicePk, address(adapter), block.chainid, 1, "ipfs://agent", signedMetadata, address(0), alice, expiration
        );
        _expectInvalidSignature(1, "ipfs://agent", submittedMetadata, address(0), alice, expiration, signature);
    }

    function testCounterfactualRegisterWithSigRejectsTamperedTokenId() external {
        IERC8004IdentityRegistry.MetadataEntry[] memory metadata = _emptyMetadata();
        uint256 expiration = block.timestamp + 10 minutes;
        bytes memory signature =
            _sign(alicePk, address(adapter), block.chainid, 1, "ipfs://agent", metadata, address(0), alice, expiration);
        _expectInvalidSignature(2, "ipfs://agent", metadata, address(0), alice, expiration, signature);
    }

    function testCounterfactualRegisterWithSigRejectsTamperedWallet() external {
        IERC8004IdentityRegistry.MetadataEntry[] memory metadata = _emptyMetadata();
        uint256 expiration = block.timestamp + 10 minutes;
        bytes memory signature =
            _sign(alicePk, address(adapter), block.chainid, 1, "ipfs://agent", metadata, wallet, alice, expiration);
        _expectInvalidSignature(1, "ipfs://agent", metadata, makeAddr("otherWallet"), alice, expiration, signature);
    }

    function testCounterfactualRegisterWithSigRejectsTamperedExpiration() external {
        IERC8004IdentityRegistry.MetadataEntry[] memory metadata = _emptyMetadata();
        uint256 expiration = block.timestamp + 10 minutes;
        uint256 submittedExpiration = block.timestamp + 11 minutes;
        bytes memory signature =
            _sign(alicePk, address(adapter), block.chainid, 1, "ipfs://agent", metadata, address(0), alice, expiration);
        _expectInvalidSignature(1, "ipfs://agent", metadata, address(0), alice, submittedExpiration, signature);
    }

    function testCounterfactualRegisterWithSigRejectsCrossChainDigest() external {
        IERC8004IdentityRegistry.MetadataEntry[] memory metadata = _emptyMetadata();
        uint256 expiration = block.timestamp + 10 minutes;
        bytes memory signature = _sign(
            alicePk, address(adapter), block.chainid + 1, 1, "ipfs://agent", metadata, address(0), alice, expiration
        );
        _expectInvalidSignature(1, "ipfs://agent", metadata, address(0), alice, expiration, signature);
    }

    function testCounterfactualRegisterWithSigRejectsCrossAdapterDigest() external {
        IERC8004IdentityRegistry.MetadataEntry[] memory metadata = _emptyMetadata();
        Adapter8004 secondAdapter = _newAdapter();
        uint256 expiration = block.timestamp + 10 minutes;
        bytes memory signature =
            _sign(alicePk, address(adapter), block.chainid, 1, "ipfs://agent", metadata, address(0), alice, expiration);

        vm.expectRevert(Adapter8004.InvalidSignature.selector);
        secondAdapter.counterfactualRegisterWithSig(
            IERCAgentBindings.TokenStandard.ERC721,
            address(token721),
            1,
            "ipfs://agent",
            metadata,
            address(0),
            alice,
            expiration,
            signature
        );
    }

    function testCounterfactualRegisterWithSigRejectsZeroTokenContract() external {
        IERC8004IdentityRegistry.MetadataEntry[] memory metadata = _emptyMetadata();
        uint256 expiration = block.timestamp + 10 minutes;

        vm.expectRevert(Adapter8004.InvalidTokenContract.selector);
        adapter.counterfactualRegisterWithSig(
            IERCAgentBindings.TokenStandard.ERC721,
            address(0),
            1,
            "ipfs://agent",
            metadata,
            address(0),
            alice,
            expiration,
            hex""
        );
    }

    function testCounterfactualRegisterWithSigRejectsRegistryAsTokenContract() external {
        IERC8004IdentityRegistry.MetadataEntry[] memory metadata = _emptyMetadata();
        uint256 expiration = block.timestamp + 10 minutes;

        vm.expectRevert(Adapter8004.InvalidTokenContractIsRegistry.selector);
        adapter.counterfactualRegisterWithSig(
            IERCAgentBindings.TokenStandard.ERC721,
            address(registry),
            1,
            "ipfs://agent",
            metadata,
            address(0),
            alice,
            expiration,
            hex""
        );
    }

    function testCounterfactualRegisterWithSigRejectsReservedAgentBindingMetadata() external {
        IERC8004IdentityRegistry.MetadataEntry[] memory metadata =
            _metadata(adapter.BINDING_METADATA_KEY(), bytes("bad"));
        uint256 expiration = block.timestamp + 10 minutes;

        vm.expectRevert(
            abi.encodeWithSelector(Adapter8004.ReservedMetadataKey.selector, adapter.BINDING_METADATA_KEY())
        );
        adapter.counterfactualRegisterWithSig(
            IERCAgentBindings.TokenStandard.ERC721,
            address(token721),
            1,
            "ipfs://agent",
            metadata,
            address(0),
            alice,
            expiration,
            hex""
        );
    }

    function testCounterfactualRegisterWithSigRejectsReservedCfRegistrationMetadata() external {
        IERC8004IdentityRegistry.MetadataEntry[] memory metadata =
            _metadata(adapter.CF_REGISTRATION_KEY(), bytes("bad"));
        uint256 expiration = block.timestamp + 10 minutes;

        vm.expectRevert(abi.encodeWithSelector(Adapter8004.ReservedMetadataKey.selector, adapter.CF_REGISTRATION_KEY()));
        adapter.counterfactualRegisterWithSig(
            IERCAgentBindings.TokenStandard.ERC721,
            address(token721),
            1,
            "ipfs://agent",
            metadata,
            address(0),
            alice,
            expiration,
            hex""
        );
    }

    function testCounterfactualRegisterWithSigERC1155HappyPathRelayerWithBundledWallet() external {
        IERC8004IdentityRegistry.MetadataEntry[] memory metadata = _emptyMetadata();
        uint256 expiration = block.timestamp + 10 minutes;
        bytes memory signature = _signForStandard(
            alicePk,
            address(adapter),
            block.chainid,
            IERCAgentBindings.TokenStandard.ERC1155,
            address(token1155),
            10,
            "ipfs://agent-1155",
            metadata,
            wallet,
            alice,
            expiration
        );
        bytes32 expectedHash = adapter.registrationHash(IERCAgentBindings.TokenStandard.ERC1155, address(token1155), 10);

        vm.prank(relayer);
        vm.expectEmit(true, true, true, true, address(adapter));
        emit IERC8004AdapterCounterfactual.CounterfactualAgentRegistered(
            expectedHash,
            address(token1155),
            10,
            uint8(1),
            IERCAgentBindings.TokenStandard.ERC1155,
            "ipfs://agent-1155",
            metadata,
            alice
        );
        vm.expectEmit(true, true, true, true, address(adapter));
        emit IERC8004AdapterCounterfactual.CounterfactualAgentWalletSet(
            expectedHash, address(token1155), 10, uint8(1), wallet, alice
        );
        bytes32 actual = adapter.counterfactualRegisterWithSig(
            IERCAgentBindings.TokenStandard.ERC1155,
            address(token1155),
            10,
            "ipfs://agent-1155",
            metadata,
            wallet,
            alice,
            expiration,
            signature
        );

        assertEq(actual, expectedHash);
    }

    function testCounterfactualRegisterWithSigERC6909HappyPathRelayer() external {
        IERC8004IdentityRegistry.MetadataEntry[] memory metadata = _emptyMetadata();
        uint256 expiration = block.timestamp + 10 minutes;
        bytes memory signature = _signForStandard(
            alicePk,
            address(adapter),
            block.chainid,
            IERCAgentBindings.TokenStandard.ERC6909,
            address(token6909),
            42,
            "ipfs://agent-6909",
            metadata,
            address(0),
            alice,
            expiration
        );
        bytes32 expectedHash = adapter.registrationHash(IERCAgentBindings.TokenStandard.ERC6909, address(token6909), 42);

        vm.prank(relayer);
        vm.expectEmit(true, true, true, true, address(adapter));
        emit IERC8004AdapterCounterfactual.CounterfactualAgentRegistered(
            expectedHash,
            address(token6909),
            42,
            uint8(1),
            IERCAgentBindings.TokenStandard.ERC6909,
            "ipfs://agent-6909",
            metadata,
            alice
        );
        bytes32 actual = adapter.counterfactualRegisterWithSig(
            IERCAgentBindings.TokenStandard.ERC6909,
            address(token6909),
            42,
            "ipfs://agent-6909",
            metadata,
            address(0),
            alice,
            expiration,
            signature
        );

        assertEq(actual, expectedHash);
    }

    function testCounterfactualRegisterWithSigERC1155ZeroBalanceRevertsNotController() external {
        IERC8004IdentityRegistry.MetadataEntry[] memory metadata = _emptyMetadata();
        uint256 expiration = block.timestamp + 10 minutes;
        bytes memory signature = _signForStandard(
            bobPk,
            address(adapter),
            block.chainid,
            IERCAgentBindings.TokenStandard.ERC1155,
            address(token1155),
            10,
            "ipfs://agent",
            metadata,
            address(0),
            bob,
            expiration
        );

        vm.expectRevert(abi.encodeWithSelector(Adapter8004.NotController.selector, bob, type(uint256).max));
        adapter.counterfactualRegisterWithSig(
            IERCAgentBindings.TokenStandard.ERC1155,
            address(token1155),
            10,
            "ipfs://agent",
            metadata,
            address(0),
            bob,
            expiration,
            signature
        );
    }

    function testCounterfactualRegisterWithSigERC6909ZeroBalanceRevertsNotController() external {
        IERC8004IdentityRegistry.MetadataEntry[] memory metadata = _emptyMetadata();
        uint256 expiration = block.timestamp + 10 minutes;
        bytes memory signature = _signForStandard(
            bobPk,
            address(adapter),
            block.chainid,
            IERCAgentBindings.TokenStandard.ERC6909,
            address(token6909),
            42,
            "ipfs://agent",
            metadata,
            address(0),
            bob,
            expiration
        );

        vm.expectRevert(abi.encodeWithSelector(Adapter8004.NotController.selector, bob, type(uint256).max));
        adapter.counterfactualRegisterWithSig(
            IERCAgentBindings.TokenStandard.ERC6909,
            address(token6909),
            42,
            "ipfs://agent",
            metadata,
            address(0),
            bob,
            expiration,
            signature
        );
    }

    function testCounterfactualRegisterWithSigERC1155OldSignatureFailsAfterBalanceTransferredAway() external {
        IERC8004IdentityRegistry.MetadataEntry[] memory metadata = _emptyMetadata();
        uint256 expiration = block.timestamp + 10 minutes;
        bytes memory signature = _signForStandard(
            alicePk,
            address(adapter),
            block.chainid,
            IERCAgentBindings.TokenStandard.ERC1155,
            address(token1155),
            10,
            "ipfs://agent",
            metadata,
            address(0),
            alice,
            expiration
        );
        vm.prank(alice);
        token1155.safeTransferFrom(alice, bob, 10, 1, "");

        vm.expectRevert(abi.encodeWithSelector(Adapter8004.NotController.selector, alice, type(uint256).max));
        adapter.counterfactualRegisterWithSig(
            IERCAgentBindings.TokenStandard.ERC1155,
            address(token1155),
            10,
            "ipfs://agent",
            metadata,
            address(0),
            alice,
            expiration,
            signature
        );
    }

    function testCounterfactualRegisterWithSigERC6909OldSignatureFailsAfterBalanceTransferredAway() external {
        IERC8004IdentityRegistry.MetadataEntry[] memory metadata = _emptyMetadata();
        uint256 expiration = block.timestamp + 10 minutes;
        bytes memory signature = _signForStandard(
            alicePk,
            address(adapter),
            block.chainid,
            IERCAgentBindings.TokenStandard.ERC6909,
            address(token6909),
            42,
            "ipfs://agent",
            metadata,
            address(0),
            alice,
            expiration
        );
        vm.prank(alice);
        token6909.transfer(bob, 42, 1);

        vm.expectRevert(abi.encodeWithSelector(Adapter8004.NotController.selector, alice, type(uint256).max));
        adapter.counterfactualRegisterWithSig(
            IERCAgentBindings.TokenStandard.ERC6909,
            address(token6909),
            42,
            "ipfs://agent",
            metadata,
            address(0),
            alice,
            expiration,
            signature
        );
    }

    function testCounterfactualRegisterWithSigRejectsDelegateSigner() external {
        MockDelegateRegistry mockImpl = new MockDelegateRegistry();
        vm.etch(adapter.DELEGATE_REGISTRY(), address(mockImpl).code);
        MockDelegateRegistry(adapter.DELEGATE_REGISTRY()).delegateERC721(
            hot, alice, address(token721), 1, adapter.DELEGATE_RIGHTS(), true
        );
        IERC8004IdentityRegistry.MetadataEntry[] memory metadata = _emptyMetadata();
        uint256 expiration = block.timestamp + 10 minutes;
        bytes memory signature =
            _sign(hotPk, address(adapter), block.chainid, 1, "ipfs://agent", metadata, address(0), hot, expiration);

        vm.expectRevert(abi.encodeWithSelector(Adapter8004.NotController.selector, hot, type(uint256).max));
        adapter.counterfactualRegisterWithSig(
            IERCAgentBindings.TokenStandard.ERC721,
            address(token721),
            1,
            "ipfs://agent",
            metadata,
            address(0),
            hot,
            expiration,
            signature
        );
    }

    function testCounterfactualRegisterWithSigERC1155FHappyPathUsesOwnerOf() external {
        IERC8004IdentityRegistry.MetadataEntry[] memory metadata = _emptyMetadata();
        uint256 expiration = block.timestamp + 10 minutes;
        bytes memory signature = _signForStandard(
            alicePk,
            address(adapter),
            block.chainid,
            IERCAgentBindings.TokenStandard.ERC1155F,
            address(token1155F),
            50,
            "ipfs://agent-1155f",
            metadata,
            address(0),
            alice,
            expiration
        );

        bytes32 actual = adapter.counterfactualRegisterWithSig(
            IERCAgentBindings.TokenStandard.ERC1155F,
            address(token1155F),
            50,
            "ipfs://agent-1155f",
            metadata,
            address(0),
            alice,
            expiration,
            signature
        );

        assertEq(actual, adapter.registrationHash(IERCAgentBindings.TokenStandard.ERC1155F, address(token1155F), 50));
    }

    function testCounterfactualRegisterWithSigERC6909FHappyPathUsesOwnerOf() external {
        IERC8004IdentityRegistry.MetadataEntry[] memory metadata = _emptyMetadata();
        uint256 expiration = block.timestamp + 10 minutes;
        bytes memory signature = _signForStandard(
            alicePk,
            address(adapter),
            block.chainid,
            IERCAgentBindings.TokenStandard.ERC6909F,
            address(token6909F),
            60,
            "ipfs://agent-6909f",
            metadata,
            address(0),
            alice,
            expiration
        );

        bytes32 actual = adapter.counterfactualRegisterWithSig(
            IERCAgentBindings.TokenStandard.ERC6909F,
            address(token6909F),
            60,
            "ipfs://agent-6909f",
            metadata,
            address(0),
            alice,
            expiration,
            signature
        );

        assertEq(actual, adapter.registrationHash(IERCAgentBindings.TokenStandard.ERC6909F, address(token6909F), 60));
    }

    function testCounterfactualRegisterWithSigFTypeRejectsDelegateSigner() external {
        MockDelegateRegistry mockImpl = new MockDelegateRegistry();
        vm.etch(adapter.DELEGATE_REGISTRY(), address(mockImpl).code);
        MockDelegateRegistry(adapter.DELEGATE_REGISTRY()).delegateERC721(
            hot, alice, address(token1155F), 50, adapter.DELEGATE_RIGHTS(), true
        );
        IERC8004IdentityRegistry.MetadataEntry[] memory metadata = _emptyMetadata();
        uint256 expiration = block.timestamp + 10 minutes;
        bytes memory signature = _signForStandard(
            hotPk,
            address(adapter),
            block.chainid,
            IERCAgentBindings.TokenStandard.ERC1155F,
            address(token1155F),
            50,
            "ipfs://agent",
            metadata,
            address(0),
            hot,
            expiration
        );

        vm.expectRevert(abi.encodeWithSelector(Adapter8004.NotController.selector, hot, type(uint256).max));
        adapter.counterfactualRegisterWithSig(
            IERCAgentBindings.TokenStandard.ERC1155F,
            address(token1155F),
            50,
            "ipfs://agent",
            metadata,
            address(0),
            hot,
            expiration,
            signature
        );
    }

    function testCounterfactualRegisterWithSigERC1155FOldSignatureFailsAfterTransfer() external {
        IERC8004IdentityRegistry.MetadataEntry[] memory metadata = _emptyMetadata();
        uint256 expiration = block.timestamp + 10 minutes;
        bytes memory signature = _signForStandard(
            alicePk,
            address(adapter),
            block.chainid,
            IERCAgentBindings.TokenStandard.ERC1155F,
            address(token1155F),
            50,
            "ipfs://agent",
            metadata,
            address(0),
            alice,
            expiration
        );
        vm.prank(alice);
        token1155F.transferOwner(alice, bob, 50);

        vm.expectRevert(abi.encodeWithSelector(Adapter8004.NotController.selector, alice, type(uint256).max));
        adapter.counterfactualRegisterWithSig(
            IERCAgentBindings.TokenStandard.ERC1155F,
            address(token1155F),
            50,
            "ipfs://agent",
            metadata,
            address(0),
            alice,
            expiration,
            signature
        );
    }

    function testCounterfactualRegisterWithSigERC6909FOldSignatureFailsAfterTransfer() external {
        IERC8004IdentityRegistry.MetadataEntry[] memory metadata = _emptyMetadata();
        uint256 expiration = block.timestamp + 10 minutes;
        bytes memory signature = _signForStandard(
            alicePk,
            address(adapter),
            block.chainid,
            IERCAgentBindings.TokenStandard.ERC6909F,
            address(token6909F),
            60,
            "ipfs://agent",
            metadata,
            address(0),
            alice,
            expiration
        );
        vm.prank(alice);
        token6909F.transferOwner(alice, bob, 60);

        vm.expectRevert(abi.encodeWithSelector(Adapter8004.NotController.selector, alice, type(uint256).max));
        adapter.counterfactualRegisterWithSig(
            IERCAgentBindings.TokenStandard.ERC6909F,
            address(token6909F),
            60,
            "ipfs://agent",
            metadata,
            address(0),
            alice,
            expiration,
            signature
        );
    }

    function testCounterfactualRegisterWithSigMetadataHashingNonEmptyArray() external {
        IERC8004IdentityRegistry.MetadataEntry[] memory metadata =
            _metadata2("bytes", abi.encodePacked(uint256(1), bytes("tail")), "emoji-free", bytes(hex"000102ff"));
        uint256 expiration = block.timestamp + 10 minutes;
        bytes memory signature =
            _sign(alicePk, address(adapter), block.chainid, 1, "ipfs://agent", metadata, address(0), alice, expiration);

        adapter.counterfactualRegisterWithSig(
            IERCAgentBindings.TokenStandard.ERC721,
            address(token721),
            1,
            "ipfs://agent",
            metadata,
            address(0),
            alice,
            expiration,
            signature
        );
    }

    function testCounterfactualRegisterWithSigEmptyMetadataHashMatchesEIP712ArrayRule() external {
        IERC8004IdentityRegistry.MetadataEntry[] memory metadata = _emptyMetadata();
        assertEq(_hashMetadata(metadata), keccak256(""));
        uint256 expiration = block.timestamp + 10 minutes;
        bytes memory signature =
            _sign(alicePk, address(adapter), block.chainid, 1, "ipfs://agent", metadata, address(0), alice, expiration);

        adapter.counterfactualRegisterWithSig(
            IERCAgentBindings.TokenStandard.ERC721,
            address(token721),
            1,
            "ipfs://agent",
            metadata,
            address(0),
            alice,
            expiration,
            signature
        );
    }

    function testCounterfactualRegisterWithSigHasNoRegistryOrAdapterSideEffects() external {
        IERC8004IdentityRegistry.MetadataEntry[] memory metadata = _metadata("name", bytes("alpha"));
        uint256 registryBefore = _registryNextId();
        uint256 expiration = block.timestamp + 10 minutes;
        bytes memory signature =
            _sign(alicePk, address(adapter), block.chainid, 1, "ipfs://agent", metadata, wallet, alice, expiration);

        adapter.counterfactualRegisterWithSig(
            IERCAgentBindings.TokenStandard.ERC721,
            address(token721),
            1,
            "ipfs://agent",
            metadata,
            wallet,
            alice,
            expiration,
            signature
        );

        assertEq(_registryNextId(), registryBefore);
        assertEq(registry.getMetadata(0, "name").length, 0);
        assertEq(registry.getMetadata(0, adapter.BINDING_METADATA_KEY()).length, 0);
        assertEq(registry.getAgentWallet(0), address(0));
        vm.expectRevert(abi.encodeWithSelector(Adapter8004.UnknownAgent.selector, 0));
        adapter.bindingOf(0);
    }

    function testCounterfactualRegisterWithSigDomainNameAndVersion() external {
        IERC8004IdentityRegistry.MetadataEntry[] memory metadata = _emptyMetadata();
        uint256 expiration = block.timestamp + 10 minutes;
        bytes memory good =
            _sign(alicePk, address(adapter), block.chainid, 1, "ipfs://agent", metadata, address(0), alice, expiration);
        bytes memory bad = _signWithDomain(
            alicePk,
            address(adapter),
            block.chainid,
            "Wrong",
            "1",
            1,
            "ipfs://agent",
            metadata,
            address(0),
            alice,
            expiration
        );

        adapter.counterfactualRegisterWithSig(
            IERCAgentBindings.TokenStandard.ERC721,
            address(token721),
            1,
            "ipfs://agent",
            metadata,
            address(0),
            alice,
            expiration,
            good
        );
        vm.expectRevert(Adapter8004.InvalidSignature.selector);
        adapter.counterfactualRegisterWithSig(
            IERCAgentBindings.TokenStandard.ERC721,
            address(token721),
            1,
            "ipfs://agent",
            metadata,
            address(0),
            alice,
            expiration,
            bad
        );
    }

    function testCounterfactualRegisterWithSigExactTypehashes() external pure {
        assertEq(
            DOMAIN_TYPEHASH,
            keccak256("EIP712Domain(string name,string version,uint256 chainId,address verifyingContract)")
        );
        assertEq(
            COUNTERFACTUAL_REGISTER_TYPEHASH,
            keccak256(
                "CounterfactualRegister(uint8 standard,address tokenContract,uint256 tokenId,bytes32 agentURIHash,bytes32 metadataHash,address agentWallet,address owner,uint256 expiration)"
            )
        );
        assertEq(METADATA_ENTRY_TYPEHASH, keccak256("MetadataEntry(string metadataKey,bytes metadataValue)"));
    }

    function testCounterfactualRegisterWithSigReentrancyGuardCoversOwnerOf() external {
        IERC8004IdentityRegistry.MetadataEntry[] memory metadata = _emptyMetadata();
        ReentrantERC721 mal = new ReentrantERC721();
        mal.setOwner(1, alice);
        mal.setReentry(
            address(adapter),
            abi.encodeWithSignature(
                "counterfactualRegisterWithSig(uint8,address,uint256,string,(string,bytes)[],address,address,uint256,bytes)",
                IERCAgentBindings.TokenStandard.ERC721,
                address(mal),
                1,
                "ipfs://reentrant",
                metadata,
                address(0),
                alice,
                block.timestamp,
                hex""
            )
        );

        vm.expectRevert(ICounterfactualWithSigReentrancyErrors.ReentrancyGuardReentrantCall.selector);
        adapter.counterfactualRegisterWithSig(
            IERCAgentBindings.TokenStandard.ERC721,
            address(mal),
            1,
            "ipfs://outer",
            metadata,
            address(0),
            alice,
            block.timestamp,
            hex""
        );
    }

    function testCounterfactualRegisterWithSigReentrancyGuardCoversERC1271() external {
        IERC8004IdentityRegistry.MetadataEntry[] memory metadata = _emptyMetadata();
        ReentrantERC1271Owner owner = new ReentrantERC1271Owner();
        token721.mint(address(owner), 100);
        owner.setReentry(
            address(adapter),
            abi.encodeWithSignature(
                "counterfactualRegisterWithSig(uint8,address,uint256,string,(string,bytes)[],address,address,uint256,bytes)",
                IERCAgentBindings.TokenStandard.ERC721,
                address(token721),
                100,
                "ipfs://reentrant",
                metadata,
                address(0),
                address(owner),
                block.timestamp,
                hex""
            )
        );

        // OpenZeppelin SignatureChecker treats a reverting ERC-1271 call as an invalid signature, so the
        // inner reentrancy guard failure is intentionally surfaced through the adapter's signature taxonomy.
        vm.expectRevert(Adapter8004.InvalidSignature.selector);
        adapter.counterfactualRegisterWithSig(
            IERCAgentBindings.TokenStandard.ERC721,
            address(token721),
            100,
            "ipfs://outer",
            metadata,
            address(0),
            address(owner),
            block.timestamp,
            hex""
        );
    }

    function testCounterfactualRegisterWithSigDoesNotRequireWalletConsent() external {
        IERC8004IdentityRegistry.MetadataEntry[] memory metadata = _emptyMetadata();
        uint256 expiration = block.timestamp + 10 minutes;
        address rejectingWallet = address(new MockERC1271Owner());
        bytes memory signature = _sign(
            alicePk, address(adapter), block.chainid, 1, "ipfs://agent", metadata, rejectingWallet, alice, expiration
        );

        adapter.counterfactualRegisterWithSig(
            IERCAgentBindings.TokenStandard.ERC721,
            address(token721),
            1,
            "ipfs://agent",
            metadata,
            rejectingWallet,
            alice,
            expiration,
            signature
        );
    }

    function testCounterfactualRegisterWithSigReturnHashMatchesPublicRegistrationHash() external {
        IERC8004IdentityRegistry.MetadataEntry[] memory metadata = _emptyMetadata();
        uint256 expiration = block.timestamp + 10 minutes;
        bytes memory signature =
            _sign(alicePk, address(adapter), block.chainid, 1, "ipfs://agent", metadata, address(0), alice, expiration);
        bytes32 expected = adapter.registrationHash(IERCAgentBindings.TokenStandard.ERC721, address(token721), 1);

        bytes32 actual = adapter.counterfactualRegisterWithSig(
            IERCAgentBindings.TokenStandard.ERC721,
            address(token721),
            1,
            "ipfs://agent",
            metadata,
            address(0),
            alice,
            expiration,
            signature
        );

        assertEq(actual, expected);
    }

    function _expectInvalidSignature(
        uint256 tokenId,
        string memory agentURI,
        IERC8004IdentityRegistry.MetadataEntry[] memory metadata,
        address agentWallet,
        address owner,
        uint256 expiration,
        bytes memory signature
    ) internal {
        vm.expectRevert(Adapter8004.InvalidSignature.selector);
        adapter.counterfactualRegisterWithSig(
            IERCAgentBindings.TokenStandard.ERC721,
            address(token721),
            tokenId,
            agentURI,
            metadata,
            agentWallet,
            owner,
            expiration,
            signature
        );
    }

    function _sign(
        uint256 signerPk,
        address verifyingContract,
        uint256 chainId,
        uint256 tokenId,
        string memory agentURI,
        IERC8004IdentityRegistry.MetadataEntry[] memory metadata,
        address agentWallet,
        address owner,
        uint256 expiration
    ) internal view returns (bytes memory) {
        return _signForStandard(
            signerPk,
            verifyingContract,
            chainId,
            IERCAgentBindings.TokenStandard.ERC721,
            address(token721),
            tokenId,
            agentURI,
            metadata,
            agentWallet,
            owner,
            expiration
        );
    }

    function _signForStandard(
        uint256 signerPk,
        address verifyingContract,
        uint256 chainId,
        IERCAgentBindings.TokenStandard standard,
        address tokenContract,
        uint256 tokenId,
        string memory agentURI,
        IERC8004IdentityRegistry.MetadataEntry[] memory metadata,
        address agentWallet,
        address owner,
        uint256 expiration
    ) internal pure returns (bytes memory) {
        return _signWithDomain(
            signerPk,
            verifyingContract,
            chainId,
            "Adapter8004",
            "1",
            standard,
            tokenContract,
            tokenId,
            agentURI,
            metadata,
            agentWallet,
            owner,
            expiration
        );
    }

    function _signWithDomain(
        uint256 signerPk,
        address verifyingContract,
        uint256 chainId,
        string memory name,
        string memory version,
        uint256 tokenId,
        string memory agentURI,
        IERC8004IdentityRegistry.MetadataEntry[] memory metadata,
        address agentWallet,
        address owner,
        uint256 expiration
    ) internal view returns (bytes memory) {
        return _signWithDomain(
            signerPk,
            verifyingContract,
            chainId,
            name,
            version,
            IERCAgentBindings.TokenStandard.ERC721,
            address(token721),
            tokenId,
            agentURI,
            metadata,
            agentWallet,
            owner,
            expiration
        );
    }

    function _signWithDomain(
        uint256 signerPk,
        address verifyingContract,
        uint256 chainId,
        string memory name,
        string memory version,
        IERCAgentBindings.TokenStandard standard,
        address tokenContract,
        uint256 tokenId,
        string memory agentURI,
        IERC8004IdentityRegistry.MetadataEntry[] memory metadata,
        address agentWallet,
        address owner,
        uint256 expiration
    ) internal pure returns (bytes memory) {
        return _signDigest(
            signerPk,
            _digestWithDomain(
                verifyingContract,
                chainId,
                name,
                version,
                standard,
                tokenContract,
                tokenId,
                agentURI,
                metadata,
                agentWallet,
                owner,
                expiration
            )
        );
    }

    function _signDigest(uint256 signerPk, bytes32 digest) internal pure returns (bytes memory) {
        (uint8 v, bytes32 r, bytes32 s) = vm.sign(signerPk, digest);
        return abi.encodePacked(r, s, v);
    }

    function _digestWithDomain(
        address verifyingContract,
        uint256 chainId,
        string memory name,
        string memory version,
        uint256 tokenId,
        string memory agentURI,
        IERC8004IdentityRegistry.MetadataEntry[] memory metadata,
        address agentWallet,
        address owner,
        uint256 expiration
    ) internal view returns (bytes32) {
        return _digestWithDomain(
            verifyingContract,
            chainId,
            name,
            version,
            IERCAgentBindings.TokenStandard.ERC721,
            address(token721),
            tokenId,
            agentURI,
            metadata,
            agentWallet,
            owner,
            expiration
        );
    }

    function _digestWithDomain(
        address verifyingContract,
        uint256 chainId,
        string memory name,
        string memory version,
        IERCAgentBindings.TokenStandard standard,
        address tokenContract,
        uint256 tokenId,
        string memory agentURI,
        IERC8004IdentityRegistry.MetadataEntry[] memory metadata,
        address agentWallet,
        address owner,
        uint256 expiration
    ) internal pure returns (bytes32) {
        return keccak256(
            abi.encodePacked(
                hex"1901",
                _domainSeparator(verifyingContract, chainId, name, version),
                _structHash(standard, tokenContract, tokenId, agentURI, metadata, agentWallet, owner, expiration)
            )
        );
    }

    function _domainSeparator(address verifyingContract, uint256 chainId, string memory name, string memory version)
        internal
        pure
        returns (bytes32)
    {
        return keccak256(
            abi.encode(DOMAIN_TYPEHASH, keccak256(bytes(name)), keccak256(bytes(version)), chainId, verifyingContract)
        );
    }

    function _structHash(
        IERCAgentBindings.TokenStandard standard,
        address tokenContract,
        uint256 tokenId,
        string memory agentURI,
        IERC8004IdentityRegistry.MetadataEntry[] memory metadata,
        address agentWallet,
        address owner,
        uint256 expiration
    ) internal pure returns (bytes32) {
        return keccak256(
            abi.encode(
                COUNTERFACTUAL_REGISTER_TYPEHASH,
                uint8(standard),
                tokenContract,
                tokenId,
                keccak256(bytes(agentURI)),
                _hashMetadata(metadata),
                agentWallet,
                owner,
                expiration
            )
        );
    }

    function _digest(
        address verifyingContract,
        uint256 chainId,
        uint256 tokenId,
        string memory agentURI,
        IERC8004IdentityRegistry.MetadataEntry[] memory metadata,
        address agentWallet,
        address owner,
        uint256 expiration
    ) internal view returns (bytes32) {
        return _digestWithDomain(
            verifyingContract, chainId, "Adapter8004", "1", tokenId, agentURI, metadata, agentWallet, owner, expiration
        );
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

    function _metadata(string memory key, bytes memory value)
        internal
        pure
        returns (IERC8004IdentityRegistry.MetadataEntry[] memory metadata)
    {
        metadata = new IERC8004IdentityRegistry.MetadataEntry[](1);
        metadata[0] = IERC8004IdentityRegistry.MetadataEntry({metadataKey: key, metadataValue: value});
    }

    function _metadata2(string memory keyA, bytes memory valueA, string memory keyB, bytes memory valueB)
        internal
        pure
        returns (IERC8004IdentityRegistry.MetadataEntry[] memory metadata)
    {
        metadata = new IERC8004IdentityRegistry.MetadataEntry[](2);
        metadata[0] = IERC8004IdentityRegistry.MetadataEntry({metadataKey: keyA, metadataValue: valueA});
        metadata[1] = IERC8004IdentityRegistry.MetadataEntry({metadataKey: keyB, metadataValue: valueB});
    }

    function _emptyMetadata() internal pure returns (IERC8004IdentityRegistry.MetadataEntry[] memory metadata) {
        metadata = new IERC8004IdentityRegistry.MetadataEntry[](0);
    }

    function _registryNextId() internal view returns (uint256 next) {
        while (true) {
            try registry.ownerOf(next) returns (address) {
                ++next;
            } catch {
                return next;
            }
        }
    }

    function _newAdapter() internal returns (Adapter8004 secondAdapter) {
        Adapter8004 implementation = new Adapter8004();
        ERC1967Proxy proxy = new ERC1967Proxy(
            address(implementation), abi.encodeCall(Adapter8004.initialize, (address(registry), admin))
        );
        secondAdapter = Adapter8004(address(proxy));
    }
}

contract MockERC1271Owner is IERC1271 {
    bytes4 internal constant MAGICVALUE = 0x1626ba7e;
    mapping(bytes32 => bool) public validDigest;

    function setValidDigest(bytes32 digest, bool valid) external {
        validDigest[digest] = valid;
    }

    function isValidSignature(bytes32 digest, bytes memory) external view returns (bytes4) {
        return validDigest[digest] ? MAGICVALUE : bytes4(0xffffffff);
    }
}

contract ReentrantERC1271Owner is IERC1271 {
    address public reenterTarget;
    bytes public reenterData;

    function setReentry(address target, bytes calldata data) external {
        reenterTarget = target;
        reenterData = data;
    }

    function isValidSignature(bytes32, bytes memory) external view returns (bytes4) {
        (bool ok, bytes memory ret) = reenterTarget.staticcall(reenterData);
        if (!ok) {
            assembly {
                revert(add(ret, 0x20), mload(ret))
            }
        }
        return 0x1626ba7e;
    }
}
