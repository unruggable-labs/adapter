// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Test, Vm} from "forge-std/Test.sol";
import {ERC1967Proxy} from "@openzeppelin/contracts/proxy/ERC1967/ERC1967Proxy.sol";

import {Adapter8004} from "../../src/Adapter8004.sol";
import {IERCAgentBindings} from "../../src/interfaces/IERCAgentBindings.sol";
import {IERC8004IdentityRegistry} from "../../src/interfaces/IERC8004IdentityRegistry.sol";
import {MockIdentityRegistry} from "../mocks/MockIdentityRegistry.sol";

contract CounterfactualCollection {
    Adapter8004 internal immutable ADAPTER;
    IERCAgentBindings.TokenStandard internal immutable STANDARD;
    bool internal immutable MISSING_RETURNS_ZERO;

    mapping(uint256 tokenId => address owner) internal _owners;

    event Transfer(address indexed from, address indexed to, uint256 indexed tokenId);

    constructor(Adapter8004 adapter, IERCAgentBindings.TokenStandard standard, bool missingReturnsZero) {
        ADAPTER = adapter;
        STANDARD = standard;
        MISSING_RETURNS_ZERO = missingReturnsZero;
    }

    function ownerOf(uint256 tokenId) external view returns (address) {
        address owner = _owners[tokenId];
        if (owner == address(0) && !MISSING_RETURNS_ZERO) revert("nonexistent token");
        return owner;
    }

    function mint(address to, uint256 tokenId) public {
        require(_owners[tokenId] == address(0), "already minted");
        _owners[tokenId] = to;
        emit Transfer(address(0), to, tokenId);
    }

    function burn(uint256 tokenId) external {
        address owner = _owners[tokenId];
        require(owner != address(0), "not minted");
        delete _owners[tokenId];
        emit Transfer(owner, address(0), tokenId);
    }

    function registerFull(
        uint256 tokenId,
        string calldata agentURI,
        IERC8004IdentityRegistry.MetadataEntry[] calldata metadata
    ) public returns (bytes32) {
        return ADAPTER.counterfactualRegister(STANDARD, address(this), tokenId, agentURI, metadata);
    }

    function registerShort(uint256 tokenId, string calldata agentURI) external returns (bytes32) {
        return ADAPTER.counterfactualRegister(STANDARD, address(this), tokenId, agentURI);
    }

    function registerThenMint(
        address buyer,
        uint256 tokenId,
        string calldata agentURI,
        IERC8004IdentityRegistry.MetadataEntry[] calldata metadata
    ) external returns (bytes32 hash) {
        hash = registerFull(tokenId, agentURI, metadata);
        mint(buyer, tokenId);
    }

    function mintThenRegister(
        address buyer,
        uint256 tokenId,
        string calldata agentURI,
        IERC8004IdentityRegistry.MetadataEntry[] calldata metadata
    ) external returns (bytes32 hash) {
        mint(buyer, tokenId);
        hash = registerFull(tokenId, agentURI, metadata);
    }

    function setURI(uint256 tokenId, string calldata value) external {
        ADAPTER.counterfactualSetAgentURI(STANDARD, address(this), tokenId, value);
    }

    function setMetadata(uint256 tokenId, string calldata key, bytes calldata value) external {
        ADAPTER.counterfactualSetMetadata(STANDARD, address(this), tokenId, key, value);
    }

    function setMetadataBatch(uint256 tokenId, IERC8004IdentityRegistry.MetadataEntry[] calldata metadata) external {
        ADAPTER.counterfactualSetMetadataBatch(STANDARD, address(this), tokenId, metadata);
    }

    function setWallet(uint256 tokenId, address wallet) external {
        ADAPTER.counterfactualSetAgentWallet(STANDARD, address(this), tokenId, wallet);
    }

    function unsetWallet(uint256 tokenId) external {
        ADAPTER.counterfactualUnsetAgentWallet(STANDARD, address(this), tokenId);
    }
}

contract CounterfactualPlainMultiToken {
    Adapter8004 internal immutable ADAPTER;
    IERCAgentBindings.TokenStandard internal immutable STANDARD;

    mapping(address account => mapping(uint256 tokenId => uint256 balance)) internal _balances;

    constructor(Adapter8004 adapter, IERCAgentBindings.TokenStandard standard) {
        ADAPTER = adapter;
        STANDARD = standard;
    }

    function balanceOf(address account, uint256 tokenId) external view returns (uint256) {
        return _balances[account][tokenId];
    }

    function mint(address to, uint256 tokenId, uint256 amount) external {
        _balances[to][tokenId] += amount;
    }

    function registerAsCollection(uint256 tokenId) external returns (bytes32) {
        return ADAPTER.counterfactualRegister(STANDARD, address(this), tokenId, "ipfs://collection");
    }
}

contract CounterfactualMalformedOwnerCollection {
    enum Mode {
        WrongLength,
        DirtyAddress
    }

    Adapter8004 internal immutable ADAPTER;
    Mode internal immutable MODE;

    constructor(Adapter8004 adapter, Mode mode) {
        ADAPTER = adapter;
        MODE = mode;
    }

    function register(uint256 tokenId) external returns (bytes32) {
        return ADAPTER.counterfactualRegister(
            IERCAgentBindings.TokenStandard.ERC721, address(this), tokenId, "ipfs://malformed"
        );
    }

    fallback() external {
        if (MODE == Mode.WrongLength) {
            assembly ("memory-safe") {
                mstore(0, 1)
                return(1, 31)
            }
        }
        assembly ("memory-safe") {
            mstore(0, or(shl(200, 1), 1))
            return(0, 32)
        }
    }
}

contract CounterfactualReentrantOwnerCollection {
    Adapter8004 internal immutable ADAPTER;

    constructor(Adapter8004 adapter) {
        ADAPTER = adapter;
    }

    function register(uint256 tokenId) external returns (bytes32) {
        return ADAPTER.counterfactualRegister(
            IERCAgentBindings.TokenStandard.ERC721, address(this), tokenId, "ipfs://outer"
        );
    }

    fallback() external {
        (bool success, bytes memory result) = address(ADAPTER).staticcall(
            abi.encodeWithSignature(
                "counterfactualSetAgentURI(uint8,address,uint256,string)",
                IERCAgentBindings.TokenStandard.ERC721,
                address(this),
                uint256(80),
                "ipfs://reentrant"
            )
        );

        bytes4 selector;
        if (result.length >= 4) {
            assembly ("memory-safe") {
                selector := mload(add(result, 0x20))
            }
        }
        if (success || selector != bytes4(keccak256("ReentrancyGuardReentrantCall()"))) {
            assembly ("memory-safe") {
                mstore(0, or(shl(200, 1), 1))
                return(0, 32)
            }
        }
        assembly ("memory-safe") {
            mstore(0, 0)
            return(0, 32)
        }
    }
}

/// @notice Locks in collection-only authority while a single-owner id has no current owner.
/// Counterfactual state remains event-only and latest-event-wins; minting closes the temporary
/// window and restores the ordinary owner/delegate controller model.
contract CounterfactualUnmintedTest is Test {
    event CounterfactualAgentURISet(
        bytes32 indexed registrationHash,
        address indexed tokenContract,
        uint256 indexed tokenId,
        bytes32 extraData,
        string newURI,
        address emitter
    );
    event CounterfactualMetadataSet(
        bytes32 indexed registrationHash,
        address indexed tokenContract,
        uint256 indexed tokenId,
        bytes32 extraData,
        string metadataKey,
        bytes metadataValue,
        address emitter
    );
    event CounterfactualMetadataBatchSet(
        bytes32 indexed registrationHash,
        address indexed tokenContract,
        uint256 indexed tokenId,
        bytes32 extraData,
        IERC8004IdentityRegistry.MetadataEntry[] metadata,
        address emitter
    );
    event CounterfactualAgentWalletSet(
        bytes32 indexed registrationHash,
        address indexed tokenContract,
        uint256 indexed tokenId,
        bytes32 extraData,
        address newWallet,
        address emitter
    );
    event CounterfactualAgentWalletUnset(
        bytes32 indexed registrationHash,
        address indexed tokenContract,
        uint256 indexed tokenId,
        bytes32 extraData,
        address emitter
    );

    MockIdentityRegistry internal registry;
    Adapter8004 internal adapter;

    address internal admin = makeAddr("admin");
    address internal alice = makeAddr("alice");
    address internal eve = makeAddr("eve");

    function setUp() external {
        registry = new MockIdentityRegistry();
        Adapter8004 implementation = new Adapter8004();
        ERC1967Proxy proxy = new ERC1967Proxy(
            address(implementation), abi.encodeCall(Adapter8004.initialize, (address(registry), admin))
        );
        adapter = Adapter8004(address(proxy));
    }

    function testERC721OwnerlessCollectionCanUseFullRegisterOverload() external {
        CounterfactualCollection collection = _collection(IERCAgentBindings.TokenStandard.ERC721, false);
        IERC8004IdentityRegistry.MetadataEntry[] memory metadata = _metadata("role", "builder");
        bytes32 expectedHash = adapter.registrationHash(address(collection), 1);

        vm.recordLogs();
        assertEq(collection.registerFull(1, "ipfs://full", metadata), expectedHash);
        _assertRegistrationLog(vm.getRecordedLogs()[0], expectedHash, address(collection), 1, "ipfs://full", metadata);
    }

    function testERC721OwnerlessCollectionCanUseShortRegisterOverload() external {
        CounterfactualCollection collection = _collection(IERCAgentBindings.TokenStandard.ERC721, false);
        bytes32 expectedHash = adapter.registrationHash(address(collection), 1);
        IERC8004IdentityRegistry.MetadataEntry[] memory empty = new IERC8004IdentityRegistry.MetadataEntry[](0);
        vm.recordLogs();
        assertEq(collection.registerShort(1, "ipfs://short"), expectedHash);
        _assertRegistrationLog(vm.getRecordedLogs()[0], expectedHash, address(collection), 1, "ipfs://short", empty);
    }

    function testOwnerlessCollectionCanUseEveryUnsignedSetter() external {
        CounterfactualCollection collection = _collection(IERCAgentBindings.TokenStandard.ERC721, false);
        bytes32 hash = adapter.registrationHash(address(collection), 7);
        IERC8004IdentityRegistry.MetadataEntry[] memory metadata = _metadata("a", "b");

        vm.expectEmit(true, true, true, true, address(adapter));
        emit CounterfactualAgentURISet(hash, address(collection), 7, bytes32(0), "ipfs://uri", address(collection));
        collection.setURI(7, "ipfs://uri");

        vm.expectEmit(true, true, true, true, address(adapter));
        emit CounterfactualMetadataSet(hash, address(collection), 7, bytes32(0), "k", bytes("v"), address(collection));
        collection.setMetadata(7, "k", bytes("v"));

        vm.expectEmit(true, true, true, true, address(adapter));
        emit CounterfactualMetadataBatchSet(hash, address(collection), 7, bytes32(0), metadata, address(collection));
        collection.setMetadataBatch(7, metadata);

        vm.expectEmit(true, true, true, true, address(adapter));
        emit CounterfactualAgentWalletSet(hash, address(collection), 7, bytes32(0), alice, address(collection));
        collection.setWallet(7, alice);

        vm.expectEmit(true, true, true, true, address(adapter));
        emit CounterfactualAgentWalletUnset(hash, address(collection), 7, bytes32(0), address(collection));
        collection.unsetWallet(7);
    }

    function testRegisterThenMintOrdersRegistrationBeforeTransfer() external {
        CounterfactualCollection collection = _collection(IERCAgentBindings.TokenStandard.ERC721, false);
        IERC8004IdentityRegistry.MetadataEntry[] memory metadata = _metadata("k", "v");
        bytes32 expectedHash = adapter.registrationHash(address(collection), 11);

        vm.recordLogs();
        assertEq(collection.registerThenMint(alice, 11, "ipfs://born", metadata), expectedHash);
        Vm.Log[] memory logs = vm.getRecordedLogs();

        assertEq(logs.length, 2);
        assertEq(
            logs[0].topics[0],
            keccak256(
                "CounterfactualAgentRegistered(bytes32,address,uint256,bytes32,uint8,string,(string,bytes)[],address)"
            )
        );
        assertEq(logs[0].emitter, address(adapter));
        assertEq(logs[1].topics[0], keccak256("Transfer(address,address,uint256)"));
        assertEq(logs[1].emitter, address(collection));
        assertEq(collection.ownerOf(11), alice);
    }

    function testMintThenRegisterRevertsAtomically() external {
        CounterfactualCollection collection = _collection(IERCAgentBindings.TokenStandard.ERC721, false);
        IERC8004IdentityRegistry.MetadataEntry[] memory empty = new IERC8004IdentityRegistry.MetadataEntry[](0);

        vm.expectRevert(
            abi.encodeWithSelector(Adapter8004.NotController.selector, address(collection), type(uint256).max)
        );
        collection.mintThenRegister(alice, 12, "ipfs://too-late", empty);
        // The whole transaction reverted, so neither the attempted mint state nor any receipt logs
        // persist. (`recordLogs` intentionally records reverted-frame traces, so state is the
        // meaningful atomicity assertion here.)
        vm.expectRevert();
        collection.ownerOf(12);
    }

    function testAfterMintCollectionEveryUnsignedWriteRevertsButOwnerCanOverwrite() external {
        CounterfactualCollection collection = _collection(IERCAgentBindings.TokenStandard.ERC721, false);
        collection.mint(alice, 13);
        _assertEveryCollectionWriteReverts(collection, 13);
        _assertOwnerCanOverwriteEveryField(collection, 13);
    }

    function _assertEveryCollectionWriteReverts(CounterfactualCollection collection, uint256 tokenId) internal {
        IERC8004IdentityRegistry.MetadataEntry[] memory metadata = _metadata("a", "b");
        bytes memory expected =
            abi.encodeWithSelector(Adapter8004.NotController.selector, address(collection), type(uint256).max);

        vm.expectRevert(expected);
        collection.registerFull(tokenId, "u", metadata);
        vm.expectRevert(expected);
        collection.registerShort(tokenId, "u");
        vm.expectRevert(expected);
        collection.setURI(tokenId, "u");
        vm.expectRevert(expected);
        collection.setMetadata(tokenId, "k", bytes("v"));
        vm.expectRevert(expected);
        collection.setMetadataBatch(tokenId, metadata);
        vm.expectRevert(expected);
        collection.setWallet(tokenId, eve);
        vm.expectRevert(expected);
        collection.unsetWallet(tokenId);
    }

    function _assertOwnerCanOverwriteEveryField(CounterfactualCollection collection, uint256 tokenId) internal {
        IERC8004IdentityRegistry.MetadataEntry[] memory metadata = _metadata("a", "b");
        bytes32 hash = adapter.registrationHash(address(collection), tokenId);
        vm.startPrank(alice);
        adapter.counterfactualRegister(
            IERCAgentBindings.TokenStandard.ERC721, address(collection), tokenId, "ipfs://owner", metadata
        );
        vm.expectEmit(true, true, true, true, address(adapter));
        emit CounterfactualAgentURISet(hash, address(collection), tokenId, bytes32(0), "ipfs://latest", alice);
        adapter.counterfactualSetAgentURI(
            IERCAgentBindings.TokenStandard.ERC721, address(collection), tokenId, "ipfs://latest"
        );
        adapter.counterfactualSetMetadata(
            IERCAgentBindings.TokenStandard.ERC721, address(collection), tokenId, "owner", bytes("yes")
        );
        adapter.counterfactualSetMetadataBatch(
            IERCAgentBindings.TokenStandard.ERC721, address(collection), tokenId, metadata
        );
        adapter.counterfactualSetAgentWallet(IERCAgentBindings.TokenStandard.ERC721, address(collection), tokenId, eve);
        adapter.counterfactualUnsetAgentWallet(IERCAgentBindings.TokenStandard.ERC721, address(collection), tokenId);
        vm.stopPrank();
    }

    function testCollectionCanStillCallAfterMintWhenItIsNormalController() external {
        CounterfactualCollection collection = _collection(IERCAgentBindings.TokenStandard.ERC721, false);
        collection.mint(address(collection), 14);
        collection.setURI(14, "ipfs://owned-by-collection");
    }

    function testStrangerCannotClaimOwnerlessIdAndEOACannotMasqueradeAsCollection() external {
        CounterfactualCollection zeroOwnerCollection = _collection(IERCAgentBindings.TokenStandard.ERC721, true);

        vm.prank(eve);
        vm.expectRevert(abi.encodeWithSelector(Adapter8004.NotController.selector, eve, type(uint256).max));
        adapter.counterfactualRegister(
            IERCAgentBindings.TokenStandard.ERC721, address(zeroOwnerCollection), 1, "ipfs://stranger"
        );

        vm.prank(eve);
        vm.expectRevert(Adapter8004.InvalidTokenContract.selector);
        adapter.counterfactualRegister(IERCAgentBindings.TokenStandard.ERC721, eve, 1, "ipfs://eoa");
    }

    function testMultipleOwnerlessRegistrationsUseSameHashAndLastLogWins() external {
        CounterfactualCollection collection = _collection(IERCAgentBindings.TokenStandard.ERC721, false);
        IERC8004IdentityRegistry.MetadataEntry[] memory first = _metadata("seq", "one");
        IERC8004IdentityRegistry.MetadataEntry[] memory second = _metadata("seq", "two");

        vm.recordLogs();
        bytes32 firstHash = collection.registerFull(21, "ipfs://one", first);
        bytes32 secondHash = collection.registerFull(21, "ipfs://two", second);
        Vm.Log[] memory logs = vm.getRecordedLogs();

        assertEq(firstHash, secondHash);
        assertEq(logs.length, 2);
        _assertRegistrationLog(logs[1], secondHash, address(collection), 21, "ipfs://two", second);
    }

    function testOwnerlessAndPostMintClosureForEverySingleOwnerStandard() external {
        _assertSingleOwnerStandard(IERCAgentBindings.TokenStandard.ERC721, 31);
        _assertSingleOwnerStandard(IERCAgentBindings.TokenStandard.ERC1155F, 32);
        _assertSingleOwnerStandard(IERCAgentBindings.TokenStandard.ERC6909F, 33);
    }

    function testZeroOwnerResponseOpensWindowAndNonzeroOwnerClosesIt() external {
        CounterfactualCollection collection = _collection(IERCAgentBindings.TokenStandard.ERC721, true);
        collection.registerShort(40, "ipfs://zero");
        collection.mint(alice, 40);

        vm.expectRevert(
            abi.encodeWithSelector(Adapter8004.NotController.selector, address(collection), type(uint256).max)
        );
        collection.registerShort(40, "ipfs://closed");
    }

    function testMalformedSuccessfulOwnerOfResponsesFailClosed() external {
        CounterfactualMalformedOwnerCollection shortResponse =
            new CounterfactualMalformedOwnerCollection(adapter, CounterfactualMalformedOwnerCollection.Mode.WrongLength);
        vm.expectRevert(abi.encodeWithSelector(Adapter8004.InvalidOwnerOfResponse.selector, address(shortResponse), 1));
        shortResponse.register(1);

        CounterfactualMalformedOwnerCollection dirtyResponse = new CounterfactualMalformedOwnerCollection(
            adapter, CounterfactualMalformedOwnerCollection.Mode.DirtyAddress
        );
        vm.expectRevert(abi.encodeWithSelector(Adapter8004.InvalidOwnerOfResponse.selector, address(dirtyResponse), 2));
        dirtyResponse.register(2);
    }

    function testOwnerOfCannotReenterUnsignedCounterfactualWrite() external {
        CounterfactualReentrantOwnerCollection collection = new CounterfactualReentrantOwnerCollection(adapter);

        vm.recordLogs();
        collection.register(80);
        Vm.Log[] memory logs = vm.getRecordedLogs();

        assertEq(logs.length, 1, "reentrant URI write must not emit");
        assertEq(
            logs[0].topics[0],
            keccak256(
                "CounterfactualAgentRegistered(bytes32,address,uint256,bytes32,uint8,string,(string,bytes)[],address)"
            )
        );
    }

    function testBurnReopensOnlyCollectionOwnerlessWindow() external {
        CounterfactualCollection collection = _collection(IERCAgentBindings.TokenStandard.ERC721, false);
        collection.mint(alice, 50);
        collection.burn(50);
        collection.registerShort(50, "ipfs://after-burn");

        vm.prank(eve);
        vm.expectRevert();
        adapter.counterfactualRegister(
            IERCAgentBindings.TokenStandard.ERC721, address(collection), 50, "ipfs://stranger"
        );
    }

    function testPlainERC1155AndERC6909HaveNoOwnerlessCollectionAuthority() external {
        _assertPlainMultiTokenExcluded(IERCAgentBindings.TokenStandard.ERC1155, 61);
        _assertPlainMultiTokenExcluded(IERCAgentBindings.TokenStandard.ERC6909, 62);
    }

    function testPlainERC1155AndERC6909PositiveHolderBehaviorIsUnchanged() external {
        CounterfactualPlainMultiToken token1155 =
            new CounterfactualPlainMultiToken(adapter, IERCAgentBindings.TokenStandard.ERC1155);
        CounterfactualPlainMultiToken token6909 =
            new CounterfactualPlainMultiToken(adapter, IERCAgentBindings.TokenStandard.ERC6909);
        token1155.mint(alice, 71, 1);
        token6909.mint(alice, 72, 1);

        vm.startPrank(alice);
        adapter.counterfactualRegister(
            IERCAgentBindings.TokenStandard.ERC1155, address(token1155), 71, "ipfs://1155-holder"
        );
        adapter.counterfactualRegister(
            IERCAgentBindings.TokenStandard.ERC6909, address(token6909), 72, "ipfs://6909-holder"
        );
        vm.stopPrank();
    }

    function _assertSingleOwnerStandard(IERCAgentBindings.TokenStandard standard, uint256 tokenId) internal {
        CounterfactualCollection collection = _collection(standard, false);
        collection.registerShort(tokenId, "ipfs://ownerless");
        collection.mint(alice, tokenId);

        vm.expectRevert(
            abi.encodeWithSelector(Adapter8004.NotController.selector, address(collection), type(uint256).max)
        );
        collection.registerShort(tokenId, "ipfs://closed");

        vm.prank(alice);
        adapter.counterfactualRegister(standard, address(collection), tokenId, "ipfs://owner");
    }

    function _assertPlainMultiTokenExcluded(IERCAgentBindings.TokenStandard standard, uint256 tokenId) internal {
        CounterfactualPlainMultiToken token = new CounterfactualPlainMultiToken(adapter, standard);
        vm.expectRevert(abi.encodeWithSelector(Adapter8004.NotController.selector, address(token), type(uint256).max));
        token.registerAsCollection(tokenId);
    }

    function _collection(IERCAgentBindings.TokenStandard standard, bool missingReturnsZero)
        internal
        returns (CounterfactualCollection)
    {
        return new CounterfactualCollection(adapter, standard, missingReturnsZero);
    }

    function _assertRegistrationLog(
        Vm.Log memory entry,
        bytes32 expectedHash,
        address collection,
        uint256 tokenId,
        string memory uri,
        IERC8004IdentityRegistry.MetadataEntry[] memory metadata
    ) internal view {
        assertEq(entry.emitter, address(adapter));
        assertEq(
            entry.topics[0],
            keccak256(
                "CounterfactualAgentRegistered(bytes32,address,uint256,bytes32,uint8,string,(string,bytes)[],address)"
            )
        );
        assertEq(entry.topics[1], expectedHash);
        assertEq(entry.topics[2], bytes32(uint256(uint160(collection))));
        assertEq(entry.topics[3], bytes32(tokenId));
        assertEq(
            keccak256(entry.data),
            keccak256(abi.encode(bytes32(0), IERCAgentBindings.TokenStandard.ERC721, uri, metadata, collection))
        );
    }

    function _metadata(string memory key, string memory value)
        internal
        pure
        returns (IERC8004IdentityRegistry.MetadataEntry[] memory metadata)
    {
        metadata = new IERC8004IdentityRegistry.MetadataEntry[](1);
        metadata[0] = IERC8004IdentityRegistry.MetadataEntry({metadataKey: key, metadataValue: bytes(value)});
    }
}
