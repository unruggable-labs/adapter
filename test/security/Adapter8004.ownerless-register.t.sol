// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Test} from "forge-std/Test.sol";
import {ERC1967Proxy} from "@openzeppelin/contracts/proxy/ERC1967/ERC1967Proxy.sol";
import {IERC721} from "@openzeppelin/contracts/token/ERC721/IERC721.sol";

import {Adapter8004} from "../../src/Adapter8004.sol";
import {IERCAgentBindings} from "../../src/interfaces/IERCAgentBindings.sol";
import {IERC8004IdentityRegistry} from "../../src/interfaces/IERC8004IdentityRegistry.sol";
import {MockIdentityRegistry} from "../mocks/MockIdentityRegistry.sol";

contract OwnerlessRegisterCollection {
    Adapter8004 internal immutable ADAPTER;
    IERCAgentBindings.TokenStandard internal immutable STANDARD;
    bool internal immutable MISSING_RETURNS_ZERO;

    mapping(uint256 tokenId => address owner) internal _owners;

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

    function mint(address to, uint256 tokenId) external {
        require(_owners[tokenId] == address(0), "already minted");
        _owners[tokenId] = to;
    }

    function register(uint256 tokenId) external returns (uint256) {
        return ADAPTER.register(STANDARD, address(this), tokenId, "ipfs://agent");
    }

    function registerAndSetPrimary(uint256 tokenId) external returns (uint256) {
        return ADAPTER.registerAndSetPrimary(STANDARD, address(this), tokenId, "ipfs://agent");
    }

    function prepareExistingAgent(MockIdentityRegistry registry) external returns (uint256 agentId) {
        agentId = registry.register("ipfs://existing");
        IERC721(address(registry)).approve(address(ADAPTER), agentId);
    }

    function bindExisting(uint256 agentId, uint256 tokenId) external {
        ADAPTER.bindExisting(agentId, STANDARD, address(this), tokenId);
    }

    function onERC721Received(address, address, uint256, bytes calldata) external pure returns (bytes4) {
        return this.onERC721Received.selector;
    }
}

contract OwnerlessRegisterPlainMultiToken {
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

    function register(uint256 tokenId) external returns (uint256) {
        return ADAPTER.register(STANDARD, address(this), tokenId, "ipfs://agent");
    }
}

contract OwnerlessRegisterTest is Test {
    MockIdentityRegistry internal registry;
    Adapter8004 internal adapter;

    address internal admin = makeAddr("admin");
    address internal buyer = makeAddr("buyer");
    address internal stranger = makeAddr("stranger");

    function setUp() external {
        registry = new MockIdentityRegistry();
        Adapter8004 implementation = new Adapter8004();
        ERC1967Proxy proxy = new ERC1967Proxy(
            address(implementation), abi.encodeCall(Adapter8004.initialize, (address(registry), admin))
        );
        adapter = Adapter8004(address(proxy));
    }

    function testOwnerlessCollectionsCanRegisterForEverySingleOwnerStandard() external {
        _assertOwnerlessRegister(IERCAgentBindings.TokenStandard.ERC721, 1);
        _assertOwnerlessRegister(IERCAgentBindings.TokenStandard.ERC1155F, 2);
        _assertOwnerlessRegister(IERCAgentBindings.TokenStandard.ERC6909F, 3);
    }

    function testStrangerCannotRegisterOwnerlessCollectionToken() external {
        OwnerlessRegisterCollection collection =
            new OwnerlessRegisterCollection(adapter, IERCAgentBindings.TokenStandard.ERC721, false);

        vm.prank(stranger);
        vm.expectRevert();
        adapter.register(IERCAgentBindings.TokenStandard.ERC721, address(collection), 10, "ipfs://stranger");
    }

    function testOwnerlessCollectionCanRegisterWhenOwnerOfReturnsZero() external {
        OwnerlessRegisterCollection collection =
            new OwnerlessRegisterCollection(adapter, IERCAgentBindings.TokenStandard.ERC721, true);

        uint256 agentId = collection.register(9);
        assertEq(adapter.bindingOf(agentId).tokenContract, address(collection));
    }

    function testAfterMintCollectionLosesSpecialPathAndBuyerControlsAgent() external {
        OwnerlessRegisterCollection collection =
            new OwnerlessRegisterCollection(adapter, IERCAgentBindings.TokenStandard.ERC721, false);
        uint256 agentId = collection.register(11);
        collection.mint(buyer, 11);

        vm.expectRevert(
            abi.encodeWithSelector(Adapter8004.NotController.selector, address(collection), type(uint256).max)
        );
        collection.register(11);

        assertFalse(adapter.isController(agentId, address(collection)));
        assertTrue(adapter.isController(agentId, buyer));

        vm.prank(buyer);
        adapter.setMetadata(agentId, "controller", bytes("buyer"));
        assertEq(registry.getMetadata(agentId, "controller"), bytes("buyer"));
    }

    function testAfterMintCollectionCanRegisterWhenItIsCurrentController() external {
        OwnerlessRegisterCollection collection =
            new OwnerlessRegisterCollection(adapter, IERCAgentBindings.TokenStandard.ERC721, false);
        collection.mint(address(collection), 12);

        uint256 agentId = collection.register(12);
        assertTrue(adapter.isController(agentId, address(collection)));
    }

    function testRegisterAndSetPrimarySetsPrimaryForCallingCollection() external {
        OwnerlessRegisterCollection collection =
            new OwnerlessRegisterCollection(adapter, IERCAgentBindings.TokenStandard.ERC721, false);

        uint256 agentId = collection.registerAndSetPrimary(13);
        assertEq(adapter.primaryAgentOf(address(collection)), agentId);
        assertEq(adapter.primaryAgentOf(buyer), adapter.PRIMARY_AGENT_UNSET());
    }

    function testBindExistingStillRejectsOwnerlessCollectionWithoutCurrentControl() external {
        OwnerlessRegisterCollection collection =
            new OwnerlessRegisterCollection(adapter, IERCAgentBindings.TokenStandard.ERC721, false);
        uint256 agentId = collection.prepareExistingAgent(registry);

        vm.expectRevert();
        collection.bindExisting(agentId, 14);

        assertEq(registry.ownerOf(agentId), address(collection));

        collection.mint(address(collection), 14);
        collection.bindExisting(agentId, 14);
        assertEq(registry.ownerOf(agentId), address(adapter));
    }

    function testPlainERC1155AndERC6909RemainBalanceOnly() external {
        _assertPlainMultiTokenExcluded(IERCAgentBindings.TokenStandard.ERC1155, 20);
        _assertPlainMultiTokenExcluded(IERCAgentBindings.TokenStandard.ERC6909, 21);
    }

    function _assertOwnerlessRegister(IERCAgentBindings.TokenStandard standard, uint256 tokenId) internal {
        OwnerlessRegisterCollection collection = new OwnerlessRegisterCollection(adapter, standard, false);
        uint256 agentId = collection.register(tokenId);

        IERCAgentBindings.Binding memory binding = adapter.bindingOf(agentId);
        assertEq(uint8(binding.standard), uint8(standard));
        assertEq(binding.tokenContract, address(collection));
        assertEq(binding.tokenId, tokenId);
        assertEq(registry.ownerOf(agentId), address(adapter));
    }

    function _assertPlainMultiTokenExcluded(IERCAgentBindings.TokenStandard standard, uint256 tokenId) internal {
        OwnerlessRegisterPlainMultiToken token = new OwnerlessRegisterPlainMultiToken(adapter, standard);
        vm.expectRevert(abi.encodeWithSelector(Adapter8004.NotController.selector, address(token), type(uint256).max));
        token.register(tokenId);
    }
}
