// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Test, Vm} from "forge-std/Test.sol";
import {ERC1967Proxy} from "@openzeppelin/contracts/proxy/ERC1967/ERC1967Proxy.sol";

import {Adapter8004} from "../src/Adapter8004.sol";
import {IERC8004AdapterCounterfactual} from "../src/interfaces/IERC8004AdapterCounterfactual.sol";
import {IERC8004IdentityRegistry} from "../src/interfaces/IERC8004IdentityRegistry.sol";
import {IERCAgentBindings} from "../src/interfaces/IERCAgentBindings.sol";
import {MockIdentityRegistry} from "./mocks/MockIdentityRegistry.sol";
import {MockContractBinder} from "./mocks/MockContractBinder.sol";
import {MockERC20} from "./mocks/MockERC20.sol";

/// @dev A binder that also answers the two ownership shapes the adapter uses for the other
/// standards, and reverts on both. Any accidental `ownerOf` / `balanceOf(address,uint256)` probe on
/// the contract-binding path therefore fails loudly instead of silently resolving.
contract ProbeTrapBinder is MockERC20 {
    error OwnershipProbe();

    constructor(Adapter8004 adapter) MockERC20(adapter) {}

    function ownerOf(uint256) external pure returns (address) {
        revert OwnershipProbe();
    }

    function balanceOf(address, uint256) external pure returns (uint256) {
        revert OwnershipProbe();
    }
}

/// @dev One contract that can claim under two standards at the same coordinate: an ERC-721-shaped
/// collection whose ids are all unminted, so the temporary single-owner window is open for id 0, and
/// a contract binding of itself at id 0. Used to pin the deliberate alias: `registrationHash` is
/// computed from `(adapter, tokenContract, tokenId)` only, so it is standard-independent — any two
/// standards claiming the same `(tokenContract, tokenId)` land on one counterfactual identity and
/// last-event-wins applies. Nothing about the alias depends on the fixture being a token; it
/// inherits `MockERC20` only because that is a convenient concrete binder.
contract HybridERC721Contract is MockERC20 {
    constructor(Adapter8004 adapter) MockERC20(adapter) {}

    function owner() external view returns (address) {
        return address(this);
    }

    function ownerOf(uint256) external pure returns (address) {
        revert("nonexistent token");
    }

    function counterfactualRegisterAsERC721(uint256 tokenId, string calldata agentURI) external returns (bytes32) {
        return ADAPTER.counterfactualRegister(IERCAgentBindings.TokenStandard.ERC721, address(this), tokenId, agentURI);
    }

    function counterfactualRegisterAsOwnable(uint256 tokenId, string calldata agentURI) external returns (bytes32) {
        return ADAPTER.counterfactualRegister(
            IERCAgentBindings.TokenStandard.CONTRACT_OWNABLE, address(this), tokenId, agentURI
        );
    }
}

contract OwnableERC20Binder is MockERC20 {
    address internal currentOwner;

    constructor(Adapter8004 adapter, address initialOwner) MockERC20(adapter) {
        currentOwner = initialOwner;
    }

    function owner() external view virtual returns (address) {
        return currentOwner;
    }

    function transferOwnership(address newOwner) external {
        require(msg.sender == currentOwner, "not owner");
        currentOwner = newOwner;
    }

    function registerOwnable(uint256 tokenId) external returns (uint256) {
        return ADAPTER.register(
            IERCAgentBindings.TokenStandard.CONTRACT_OWNABLE, address(this), tokenId, "ipfs://ownable-agent"
        );
    }

    function counterfactualRegisterOwnable(uint256 tokenId) external returns (bytes32) {
        return ADAPTER.counterfactualRegister(
            IERCAgentBindings.TokenStandard.CONTRACT_OWNABLE, address(this), tokenId, "ipfs://ownable-agent"
        );
    }

    function bindExistingOwnable(uint256 agentId, uint256 tokenId) external {
        ADAPTER.bindExisting(agentId, IERCAgentBindings.TokenStandard.CONTRACT_OWNABLE, address(this), tokenId);
    }

    function setOwnableMetadata(uint256 agentId, string calldata key, bytes calldata value) external {
        ADAPTER.setMetadata(agentId, key, value);
    }
}

contract RevertingOwnerBinder is OwnableERC20Binder {
    constructor(Adapter8004 adapter, address allegedOwner) OwnableERC20Binder(adapter, allegedOwner) {}

    function owner() external pure override returns (address) {
        revert("owner unavailable");
    }
}

contract DirtyOwnerBinder is OwnableERC20Binder {
    constructor(Adapter8004 adapter, address allegedOwner) OwnableERC20Binder(adapter, allegedOwner) {}

    function owner() external view override returns (address) {
        assembly ("memory-safe") {
            mstore(0, or(sload(currentOwner.slot), shl(160, 1)))
            return(0, 0x20)
        }
    }
}

contract ShortOwnerBinder is OwnableERC20Binder {
    constructor(Adapter8004 adapter, address allegedOwner) OwnableERC20Binder(adapter, allegedOwner) {}

    function owner() external view override returns (address) {
        assembly ("memory-safe") {
            mstore(0, sload(currentOwner.slot))
            return(1, 0x1f)
        }
    }
}

contract Adapter8004ContractBindingTest is Test {
    bytes32 internal constant DOMAIN_TYPEHASH =
        keccak256("EIP712Domain(string name,string version,uint256 chainId,address verifyingContract)");
    bytes32 internal constant AGENT_WALLET_SET_TYPEHASH =
        keccak256("AgentWalletSet(uint256 agentId,address newWallet,address owner,uint256 deadline)");

    MockIdentityRegistry internal registry;
    Adapter8004 internal adapter;
    /// @dev The concrete token fixture: an ERC-20 binding itself as a contract. Used for the
    /// holder-versus-contract cases, since a plain contract has no holders to test against.
    MockERC20 internal token;

    uint256 internal walletPk = 0xCAFE;

    address internal wallet;
    address internal admin = makeAddr("admin");
    address internal holder = makeAddr("holder");
    address internal stranger = makeAddr("stranger");

    function setUp() external {
        wallet = vm.addr(walletPk);

        registry = new MockIdentityRegistry();
        Adapter8004 implementation = new Adapter8004();
        ERC1967Proxy proxy = new ERC1967Proxy(
            address(implementation), abi.encodeCall(Adapter8004.initialize, (address(registry), admin))
        );
        adapter = Adapter8004(address(proxy));

        token = new MockERC20(adapter);
        token.mint(holder, 1_000 ether);
    }

    // -----------------------------------------------------------------
    //  Register authority
    // -----------------------------------------------------------------
    //  Enum values are pinned by the canonical append-only test in
    //  Adapter8004.interfaces.t.sol::testTokenStandardValuesAreAdditive.

    function testContractRegistersItsOwnAgent() external {
        vm.expectEmit(true, true, true, true, address(adapter));
        emit Adapter8004.AgentBound(0, IERCAgentBindings.TokenStandard.CONTRACT, address(token), 0, address(token));
        uint256 agentId = token.register(0);

        IERCAgentBindings.Binding memory binding = adapter.bindingOf(agentId);
        assertEq(uint8(binding.standard), uint8(IERCAgentBindings.TokenStandard.CONTRACT));
        assertEq(binding.tokenContract, address(token));
        assertEq(binding.tokenId, 0);

        assertEq(registry.ownerOf(agentId), address(adapter));
        assertEq(registry.getMetadata(agentId, adapter.BINDING_METADATA_KEY()), abi.encodePacked(address(adapter)));
        assertEq(registry.getAgentWallet(agentId), address(0));

        assertTrue(adapter.isController(agentId, address(token)));
        assertFalse(adapter.isController(agentId, holder));
        assertFalse(adapter.isController(agentId, stranger));
        assertFalse(adapter.isController(agentId, admin));
    }

    /// @dev A binder with no token interface at all: nothing to own, nothing to hold, nothing for the
    /// adapter to probe. This is the general case; the ERC-20 fixture is only one instance of it.
    function testNonTokenContractRegistersItselfAndIsPermanentSoleController() external {
        MockContractBinder binder = new MockContractBinder(adapter);

        // Whatever the adapter might have probed simply does not exist on this contract.
        _assertNoOwnershipSurface(address(binder));

        // And it is not probed either.
        vm.expectCall(address(binder), abi.encodeWithSignature("ownerOf(uint256)"), 0);
        vm.expectCall(address(binder), abi.encodeWithSignature("balanceOf(address,uint256)"), 0);
        vm.expectCall(address(binder), abi.encodeWithSignature("balanceOf(address)"), 0);

        uint256 agentId = binder.register(0);

        IERCAgentBindings.Binding memory binding = adapter.bindingOf(agentId);
        assertEq(uint8(binding.standard), uint8(IERCAgentBindings.TokenStandard.CONTRACT));
        assertEq(binding.tokenContract, address(binder));
        assertEq(binding.tokenId, 0);
        assertEq(registry.ownerOf(agentId), address(adapter));

        // Sole controller: the binder, and no address that merely interacts with it.
        assertTrue(adapter.isController(agentId, address(binder)));
        assertFalse(adapter.isController(agentId, admin));
        assertFalse(adapter.isController(agentId, stranger));

        _expectNotController(stranger);
        vm.prank(stranger);
        adapter.register(IERCAgentBindings.TokenStandard.CONTRACT, address(binder), 0, "ipfs://stranger");

        // Permanent: activity on the binder changes nothing, and it keeps full control afterwards.
        binder.doWork();
        vm.prank(stranger);
        binder.doWork();
        assertEq(binder.callCount(), 2);

        assertTrue(adapter.isController(agentId, address(binder)));
        binder.setMetadata(agentId, "controller", bytes("binder"));
        assertEq(registry.getMetadata(agentId, "controller"), bytes("binder"));

        _expectNotControllerOf(stranger, agentId);
        vm.prank(stranger);
        adapter.setMetadata(agentId, "controller", bytes("stranger"));

        // And it can keep registering further agents for itself.
        uint256 secondAgentId = binder.register(0);
        assertTrue(secondAgentId != agentId);
        assertTrue(adapter.isController(secondAgentId, address(binder)));
    }

    function testRegisterAndSetPrimaryGivesThePrimaryToTheCallingContract() external {
        uint256 agentId = token.registerAndSetPrimary(0);

        IERCAgentBindings.Binding memory binding = adapter.bindingOf(agentId);
        assertEq(uint8(binding.standard), uint8(IERCAgentBindings.TokenStandard.CONTRACT));
        assertEq(binding.tokenContract, address(token));
        assertEq(binding.tokenId, 0);
        assertEq(registry.ownerOf(agentId), address(adapter));

        // The primary belongs to the bound contract — the caller — and to nobody else.
        assertEq(adapter.primaryAgentOf(address(token)), agentId);
        assertTrue(adapter.primaryAgentOf(address(token)) != adapter.PRIMARY_AGENT_UNSET());
        assertEq(adapter.primaryAgentOf(holder), adapter.PRIMARY_AGENT_UNSET());
        assertEq(adapter.primaryAgentOf(admin), adapter.PRIMARY_AGENT_UNSET());
        assertEq(adapter.primaryAgentOf(stranger), adapter.PRIMARY_AGENT_UNSET());
    }

    function testRegisterAndSetPrimaryRejectsEveryCallerThatIsNotTheBoundContract() external {
        _expectNotController(holder);
        vm.prank(holder);
        adapter.registerAndSetPrimary(IERCAgentBindings.TokenStandard.CONTRACT, address(token), 0, "ipfs://holder");
        assertEq(adapter.primaryAgentOf(holder), adapter.PRIMARY_AGENT_UNSET());

        _expectNotController(admin);
        vm.prank(admin);
        adapter.registerAndSetPrimary(IERCAgentBindings.TokenStandard.CONTRACT, address(token), 0, "ipfs://admin");
        assertEq(adapter.primaryAgentOf(admin), adapter.PRIMARY_AGENT_UNSET());

        _expectNotController(stranger);
        vm.prank(stranger);
        adapter.registerAndSetPrimary(IERCAgentBindings.TokenStandard.CONTRACT, address(token), 0, "ipfs://stranger");
        assertEq(adapter.primaryAgentOf(stranger), adapter.PRIMARY_AGENT_UNSET());
    }

    function testHolderAdminAndStrangerCannotRegisterAContractBinding() external {
        _expectNotController(holder);
        vm.prank(holder);
        adapter.register(IERCAgentBindings.TokenStandard.CONTRACT, address(token), 0, "ipfs://holder");

        _expectNotController(admin);
        vm.prank(admin);
        adapter.register(IERCAgentBindings.TokenStandard.CONTRACT, address(token), 0, "ipfs://admin");

        _expectNotController(stranger);
        vm.prank(stranger);
        adapter.register(IERCAgentBindings.TokenStandard.CONTRACT, address(token), 0, "ipfs://stranger");
    }

    function testContractPathNeverProbesOwnerOfOrEitherBalanceOf() external {
        ProbeTrapBinder trap = new ProbeTrapBinder(adapter);
        trap.mint(holder, 1 ether);

        // Count 0: neither ownership shape nor the plain balance shape may be called on the binder.
        vm.expectCall(address(trap), abi.encodeWithSignature("ownerOf(uint256)"), 0);
        vm.expectCall(address(trap), abi.encodeWithSignature("balanceOf(address,uint256)"), 0);
        vm.expectCall(address(trap), abi.encodeWithSignature("balanceOf(address)"), 0);

        uint256 agentId = trap.register(0);

        // Post-bind control re-evaluation must stay probe-free too.
        assertTrue(adapter.isController(agentId, address(trap)));
        assertFalse(adapter.isController(agentId, holder));
    }

    function testContractAuthorityNeverClosesAsBoundContractStateMoves() external {
        uint256 agentId = token.register(0);

        // State inside the bound contract is irrelevant to its binding authority: unlike the
        // single-owner collection window, this one neither closes on a mint nor reopens on a burn.
        vm.prank(holder);
        token.transfer(stranger, 500 ether);
        token.mint(address(token), 1 ether);

        assertTrue(adapter.isController(agentId, address(token)));
        assertFalse(adapter.isController(agentId, holder));
        assertFalse(adapter.isController(agentId, stranger));

        // The same authority can keep registering further agents for the same contract.
        uint256 secondAgentId = token.register(0);
        assertTrue(adapter.isController(secondAgentId, address(token)));
    }

    // -----------------------------------------------------------------
    //  Explicit ownable contract authority
    // -----------------------------------------------------------------

    function testOwnableOwnerAndContractCanRegisterAndManageWhileOthersAreDenied() external {
        address contractOwner = makeAddr("contractOwner");
        OwnableERC20Binder ownable = new OwnableERC20Binder(adapter, contractOwner);
        ownable.mint(holder, 1_000 ether);

        vm.prank(contractOwner);
        uint256 ownerRegisteredId = adapter.register(
            IERCAgentBindings.TokenStandard.CONTRACT_OWNABLE, address(ownable), 0, "ipfs://owner-registered"
        );
        assertTrue(adapter.isController(ownerRegisteredId, contractOwner));
        assertTrue(adapter.isController(ownerRegisteredId, address(ownable)));

        vm.prank(contractOwner);
        adapter.setMetadata(ownerRegisteredId, "controller", bytes("owner"));
        assertEq(registry.getMetadata(ownerRegisteredId, "controller"), bytes("owner"));

        ownable.setOwnableMetadata(ownerRegisteredId, "controller", bytes("contract"));
        assertEq(registry.getMetadata(ownerRegisteredId, "controller"), bytes("contract"));

        uint256 contractRegisteredId = ownable.registerOwnable(0);
        IERCAgentBindings.Binding memory binding = adapter.bindingOf(contractRegisteredId);
        assertEq(uint8(binding.standard), 6);
        assertEq(binding.tokenContract, address(ownable));
        assertEq(binding.tokenId, 0);
        assertTrue(adapter.isController(contractRegisteredId, contractOwner));
        assertTrue(adapter.isController(contractRegisteredId, address(ownable)));

        address[3] memory denied = [holder, admin, stranger];
        for (uint256 i; i < denied.length; ++i) {
            _expectNotController(denied[i]);
            vm.prank(denied[i]);
            adapter.register(IERCAgentBindings.TokenStandard.CONTRACT_OWNABLE, address(ownable), 0, "ipfs://denied");

            _expectNotControllerOf(denied[i], ownerRegisteredId);
            vm.prank(denied[i]);
            adapter.setMetadata(ownerRegisteredId, "controller", bytes("denied"));
        }
    }

    function testOwnableAuthorityFollowsTransferAndOldOwnerLosesControl() external {
        address oldOwner = makeAddr("oldOwner");
        address newOwner = makeAddr("newOwner");
        OwnableERC20Binder ownable = new OwnableERC20Binder(adapter, oldOwner);

        vm.prank(oldOwner);
        uint256 agentId = adapter.register(
            IERCAgentBindings.TokenStandard.CONTRACT_OWNABLE, address(ownable), 0, "ipfs://before-transfer"
        );

        vm.prank(oldOwner);
        ownable.transferOwnership(newOwner);

        assertFalse(adapter.isController(agentId, oldOwner));
        assertTrue(adapter.isController(agentId, newOwner));
        assertTrue(adapter.isController(agentId, address(ownable)));

        _expectNotControllerOf(oldOwner, agentId);
        vm.prank(oldOwner);
        adapter.setMetadata(agentId, "controller", bytes("old"));

        vm.prank(newOwner);
        adapter.setMetadata(agentId, "controller", bytes("new"));
        assertEq(registry.getMetadata(agentId, "controller"), bytes("new"));

        IERCAgentBindings.Binding memory binding = adapter.bindingOf(agentId);
        assertEq(uint8(binding.standard), 6, "authority changes, binding does not");
        assertEq(binding.tokenContract, address(ownable));
        assertEq(binding.tokenId, 0);
    }

    function testRevertingOwnerFailsClosedButContractSelfStillWorks() external {
        address allegedOwner = makeAddr("revertingOwner");
        RevertingOwnerBinder ownable = new RevertingOwnerBinder(adapter, allegedOwner);
        uint256 agentId = ownable.registerOwnable(0);

        assertFalse(adapter.isController(agentId, allegedOwner));
        assertTrue(adapter.isController(agentId, address(ownable)));

        _expectNotControllerOf(allegedOwner, agentId);
        vm.prank(allegedOwner);
        adapter.setMetadata(agentId, "controller", bytes("owner"));

        ownable.setOwnableMetadata(agentId, "controller", bytes("contract"));
        assertEq(registry.getMetadata(agentId, "controller"), bytes("contract"));
    }

    function testDirtyAndWrongLengthOwnerResponsesFailClosed() external {
        address allegedOwner = makeAddr("malformedOwner");
        DirtyOwnerBinder dirty = new DirtyOwnerBinder(adapter, allegedOwner);
        ShortOwnerBinder short = new ShortOwnerBinder(adapter, allegedOwner);

        uint256 dirtyAgentId = dirty.registerOwnable(0);
        uint256 shortAgentId = short.registerOwnable(0);

        assertFalse(adapter.isController(dirtyAgentId, allegedOwner));
        assertFalse(adapter.isController(shortAgentId, allegedOwner));
        assertTrue(adapter.isController(dirtyAgentId, address(dirty)));
        assertTrue(adapter.isController(shortAgentId, address(short)));
    }

    function testZeroOwnerGrantsNobodyAndContractSelfStillWorks() external {
        OwnableERC20Binder ownable = new OwnableERC20Binder(adapter, address(0));
        uint256 agentId = ownable.registerOwnable(0);

        assertFalse(adapter.isController(agentId, address(0)));
        assertFalse(adapter.isController(agentId, stranger));
        assertTrue(adapter.isController(agentId, address(ownable)));
    }

    function testOwnableNonZeroTokenIdRevertsAtBothAuthorityChokePoints() external {
        address contractOwner = makeAddr("canonicalOwner");
        OwnableERC20Binder ownable = new OwnableERC20Binder(adapter, contractOwner);

        _expectNonZeroTokenId(address(ownable), 1);
        vm.prank(contractOwner);
        adapter.register(IERCAgentBindings.TokenStandard.CONTRACT_OWNABLE, address(ownable), 1, "ipfs://non-canonical");

        vm.prank(contractOwner);
        uint256 agentId = registry.register("ipfs://existing");
        vm.prank(contractOwner);
        registry.approve(address(adapter), agentId);

        _expectNonZeroTokenId(address(ownable), 1);
        vm.prank(contractOwner);
        adapter.bindExisting(agentId, IERCAgentBindings.TokenStandard.CONTRACT_OWNABLE, address(ownable), 1);

        assertEq(registry.ownerOf(agentId), contractOwner);
        vm.expectRevert(abi.encodeWithSelector(Adapter8004.UnknownAgent.selector, agentId));
        adapter.bindingOf(agentId);
    }

    // -----------------------------------------------------------------
    //  Unsigned counterfactual surface
    // -----------------------------------------------------------------

    function testEveryUnsignedCounterfactualWriterAcceptsTheBoundContract() external {
        bytes32 expectedHash = adapter.registrationHash(address(token), 0);
        IERC8004IdentityRegistry.MetadataEntry[] memory metadata = _metadata("k", "v");
        IERC8004IdentityRegistry.MetadataEntry[] memory empty = new IERC8004IdentityRegistry.MetadataEntry[](0);

        // Register, short overload (empty metadata array).
        vm.expectEmit(true, true, true, true, address(adapter));
        emit IERC8004AdapterCounterfactual.CounterfactualAgentRegistered(
            expectedHash,
            address(token),
            0,
            1,
            IERCAgentBindings.TokenStandard.CONTRACT,
            "ipfs://erc20-agent",
            empty,
            address(token)
        );
        assertEq(token.counterfactualRegister(0), expectedHash);

        // Register, full overload (caller-supplied metadata).
        vm.expectEmit(true, true, true, true, address(adapter));
        emit IERC8004AdapterCounterfactual.CounterfactualAgentRegistered(
            expectedHash,
            address(token),
            0,
            1,
            IERCAgentBindings.TokenStandard.CONTRACT,
            "ipfs://full",
            metadata,
            address(token)
        );
        assertEq(token.counterfactualRegisterWithMetadata(0, "ipfs://full", metadata), expectedHash);

        vm.expectEmit(true, true, true, true, address(adapter));
        emit IERC8004AdapterCounterfactual.CounterfactualAgentURISet(
            expectedHash, address(token), 0, 1, "ipfs://cf-uri", address(token)
        );
        token.counterfactualSetAgentURI(0, "ipfs://cf-uri");

        vm.expectEmit(true, true, true, true, address(adapter));
        emit IERC8004AdapterCounterfactual.CounterfactualMetadataSet(
            expectedHash, address(token), 0, 1, "k", bytes("v"), address(token)
        );
        token.counterfactualSetMetadata(0, "k", bytes("v"));

        vm.expectEmit(true, true, true, true, address(adapter));
        emit IERC8004AdapterCounterfactual.CounterfactualMetadataBatchSet(
            expectedHash, address(token), 0, 1, metadata, address(token)
        );
        token.counterfactualSetMetadataBatch(0, metadata);

        vm.expectEmit(true, true, true, true, address(adapter));
        emit IERC8004AdapterCounterfactual.CounterfactualAgentWalletSet(
            expectedHash, address(token), 0, 1, wallet, address(token)
        );
        token.counterfactualSetAgentWallet(0, wallet);

        vm.expectEmit(true, true, true, true, address(adapter));
        emit IERC8004AdapterCounterfactual.CounterfactualAgentWalletUnset(
            expectedHash, address(token), 0, 1, address(token)
        );
        token.counterfactualUnsetAgentWallet(0);
    }

    function testEveryUnsignedCounterfactualWriterDeniesHolderAdminAndStranger() external {
        _assertEveryCounterfactualWriterDenied(holder);
        _assertEveryCounterfactualWriterDenied(admin);
        _assertEveryCounterfactualWriterDenied(stranger);
    }

    // -----------------------------------------------------------------
    //  bindExisting
    // -----------------------------------------------------------------

    function testBindExistingSucceedsWhenTheContractOwnsAndApprovesTheAgent() external {
        uint256 agentId = token.prepareExistingAgent(registry);
        assertEq(registry.ownerOf(agentId), address(token));

        token.bindExisting(agentId, 0);

        assertEq(registry.ownerOf(agentId), address(adapter));
        IERCAgentBindings.Binding memory binding = adapter.bindingOf(agentId);
        assertEq(uint8(binding.standard), uint8(IERCAgentBindings.TokenStandard.CONTRACT));
        assertEq(binding.tokenContract, address(token));
        assertEq(binding.tokenId, 0);
        assertEq(registry.getMetadata(agentId, adapter.BINDING_METADATA_KEY()), abi.encodePacked(address(adapter)));
    }

    function testBindExistingRejectsAStrangerHoldingTheAgent() external {
        vm.prank(stranger);
        uint256 agentId = registry.register("ipfs://stranger-agent");
        vm.prank(stranger);
        registry.approve(address(adapter), agentId);

        _expectNotController(stranger);
        vm.prank(stranger);
        adapter.bindExisting(agentId, IERCAgentBindings.TokenStandard.CONTRACT, address(token), 0);
    }

    // -----------------------------------------------------------------
    //  Post-bind control
    // -----------------------------------------------------------------

    function testPostBindMetadataAndWalletControlStaysWithTheBoundContract() external {
        uint256 agentId = token.register(0);

        token.setAgentURI(agentId, "ipfs://updated");
        assertEq(registry.tokenURI(agentId), "ipfs://updated");

        token.setMetadata(agentId, "controller", bytes("bound-contract"));
        assertEq(registry.getMetadata(agentId, "controller"), bytes("bound-contract"));

        uint256 deadline = block.timestamp + 4 minutes;
        token.setAgentWallet(agentId, wallet, deadline, _signAgentWallet(agentId, wallet, address(adapter), deadline));
        assertEq(registry.getAgentWallet(agentId), wallet);

        token.unsetAgentWallet(agentId);
        assertEq(registry.getAgentWallet(agentId), address(0));

        // Holders, the adapter admin, and strangers control none of it.
        _expectNotControllerOf(holder, agentId);
        vm.prank(holder);
        adapter.setMetadata(agentId, "controller", bytes("holder"));

        _expectNotControllerOf(admin, agentId);
        vm.prank(admin);
        adapter.setAgentURI(agentId, "ipfs://admin");

        _expectNotControllerOf(stranger, agentId);
        vm.prank(stranger);
        adapter.unsetAgentWallet(agentId);
    }

    // -----------------------------------------------------------------
    //  Canonical binding coordinate
    // -----------------------------------------------------------------

    function testNonZeroTokenIdRevertsAtTheTokenAuthorityRoute() external {
        _expectNonZeroTokenId(address(token), 1);
        token.register(1);

        _expectNonZeroTokenId(address(token), type(uint256).max);
        adapter.register(
            IERCAgentBindings.TokenStandard.CONTRACT, address(token), type(uint256).max, "ipfs://non-canonical"
        );

        _expectNonZeroTokenId(address(token), 7);
        token.counterfactualRegister(7);

        // The id check runs before the control check, so it is not reachable-around by a stranger.
        _expectNonZeroTokenId(address(token), 1);
        vm.prank(stranger);
        adapter.register(IERCAgentBindings.TokenStandard.CONTRACT, address(token), 1, "ipfs://stranger");

        // Same rule for a binder that is not a token.
        MockContractBinder binder = new MockContractBinder(adapter);
        _expectNonZeroTokenId(address(binder), 1);
        binder.register(1);
    }

    function testNonZeroTokenIdRevertsAtTheBindingControlRoute() external {
        uint256 agentId = token.prepareExistingAgent(registry);

        _expectNonZeroTokenId(address(token), 1);
        token.bindExisting(agentId, 1);

        // Nothing moved: the agent is still the bound contract's, unbound.
        assertEq(registry.ownerOf(agentId), address(token));
        vm.expectRevert(abi.encodeWithSelector(Adapter8004.UnknownAgent.selector, agentId));
        adapter.bindingOf(agentId);

        // The canonical coordinate still binds.
        token.bindExisting(agentId, 0);
        assertEq(registry.ownerOf(agentId), address(adapter));
    }

    function testEveryContractBindingWriteEntryPointRejectsANonZeroTokenId() external {
        IERC8004IdentityRegistry.MetadataEntry[] memory metadata = _metadata("k", "v");
        uint256 agentId = token.prepareExistingAgent(registry);

        _expectNonZeroTokenId(address(token), 1);
        token.register(1);

        _expectNonZeroTokenId(address(token), 1);
        token.registerWithMetadata(1, metadata);

        _expectNonZeroTokenId(address(token), 1);
        token.registerAndSetPrimary(1);

        _expectNonZeroTokenId(address(token), 1);
        token.bindExisting(agentId, 1);

        _expectNonZeroTokenId(address(token), 1);
        token.counterfactualRegister(1);

        _expectNonZeroTokenId(address(token), 1);
        token.counterfactualRegisterWithMetadata(1, "ipfs://non-canonical", metadata);

        _expectNonZeroTokenId(address(token), 1);
        token.counterfactualSetAgentURI(1, "ipfs://non-canonical");

        _expectNonZeroTokenId(address(token), 1);
        token.counterfactualSetMetadata(1, "k", bytes("v"));

        _expectNonZeroTokenId(address(token), 1);
        token.counterfactualSetMetadataBatch(1, metadata);

        _expectNonZeroTokenId(address(token), 1);
        token.counterfactualSetAgentWallet(1, wallet);

        _expectNonZeroTokenId(address(token), 1);
        token.counterfactualUnsetAgentWallet(1);

        // Nothing was minted, bound, or claimed along the way.
        assertEq(registry.ownerOf(agentId), address(token));
        assertEq(adapter.primaryAgentOf(address(token)), adapter.PRIMARY_AGENT_UNSET());
    }

    // -----------------------------------------------------------------
    //  Raw event compatibility
    // -----------------------------------------------------------------

    function testCounterfactualAgentRegisteredRawLayoutIsUnchangedForContractBindings() external {
        IERC8004IdentityRegistry.MetadataEntry[] memory metadata = _metadata("k", "v");

        vm.recordLogs();
        bytes32 hash = token.counterfactualRegisterWithMetadata(0, "ipfs://raw", metadata);
        Vm.Log[] memory logs = vm.getRecordedLogs();

        assertEq(logs.length, 1, "counterfactual register is emit-only");
        assertEq(logs[0].emitter, address(adapter));

        // Selector and the three fixed indexed topics are the pre-CONTRACT ones.
        assertEq(logs[0].topics.length, 4);
        assertEq(
            logs[0].topics[0],
            keccak256(
                "CounterfactualAgentRegistered(bytes32,address,uint256,uint8,uint8,string,(string,bytes)[],address)"
            )
        );
        assertEq(logs[0].topics[1], hash);
        assertEq(logs[0].topics[2], bytes32(uint256(uint160(address(token)))));
        assertEq(logs[0].topics[3], bytes32(uint256(0)), "a contract binding's tokenId topic is always 0");

        // Non-indexed head words: `uint8 version` then `uint8 standard`.
        assertEq(_word(logs[0].data, 0), 1, "payload version");
        assertEq(_word(logs[0].data, 0), adapter.counterfactualPayloadVersion());
        assertEq(_word(logs[0].data, 1), 5, "non-indexed standard is the appended CONTRACT value");

        // Whole body, including `emitter == tokenContract` for a contract-authorized claim.
        assertEq(
            keccak256(logs[0].data),
            keccak256(
                abi.encode(uint8(1), IERCAgentBindings.TokenStandard.CONTRACT, "ipfs://raw", metadata, address(token))
            )
        );
    }

    function testAgentBoundRawLayoutIsUnchangedForContractBindings() external {
        vm.recordLogs();
        uint256 agentId = token.register(0);
        Vm.Log[] memory logs = vm.getRecordedLogs();

        Vm.Log memory bound = _findLog(logs, keccak256("AgentBound(uint256,uint8,address,uint256,address)"));
        assertEq(bound.emitter, address(adapter));
        assertEq(bound.topics.length, 4);
        assertEq(bound.topics[1], bytes32(agentId));
        assertEq(bound.topics[2], bytes32(uint256(5)), "indexed standard is the appended CONTRACT value");
        assertEq(bound.topics[3], bytes32(uint256(uint160(address(token)))));
        assertEq(keccak256(bound.data), keccak256(abi.encode(uint256(0), address(token))));
    }

    function testCounterfactualRawLayoutIsUnchangedForOwnableContractBindings() external {
        address contractOwner = makeAddr("rawCounterfactualOwner");
        OwnableERC20Binder ownable = new OwnableERC20Binder(adapter, contractOwner);

        vm.recordLogs();
        vm.prank(contractOwner);
        bytes32 hash = adapter.counterfactualRegister(
            IERCAgentBindings.TokenStandard.CONTRACT_OWNABLE, address(ownable), 0, "ipfs://raw-ownable"
        );
        Vm.Log[] memory logs = vm.getRecordedLogs();

        assertEq(logs.length, 1);
        assertEq(
            logs[0].topics[0],
            keccak256(
                "CounterfactualAgentRegistered(bytes32,address,uint256,uint8,uint8,string,(string,bytes)[],address)"
            )
        );
        assertEq(logs[0].topics[1], hash);
        assertEq(logs[0].topics[2], bytes32(uint256(uint160(address(ownable)))));
        assertEq(logs[0].topics[3], bytes32(uint256(0)));
        assertEq(_word(logs[0].data, 0), 1);
        assertEq(_word(logs[0].data, 1), 6);
    }

    function testAgentBoundRawLayoutIsUnchangedForOwnableContractBindings() external {
        address contractOwner = makeAddr("rawBoundOwner");
        OwnableERC20Binder ownable = new OwnableERC20Binder(adapter, contractOwner);

        vm.recordLogs();
        vm.prank(contractOwner);
        uint256 agentId = adapter.register(
            IERCAgentBindings.TokenStandard.CONTRACT_OWNABLE, address(ownable), 0, "ipfs://raw-ownable"
        );
        Vm.Log[] memory logs = vm.getRecordedLogs();

        Vm.Log memory bound = _findLog(logs, keccak256("AgentBound(uint256,uint8,address,uint256,address)"));
        assertEq(bound.topics[1], bytes32(agentId));
        assertEq(bound.topics[2], bytes32(uint256(6)));
        assertEq(bound.topics[3], bytes32(uint256(uint160(address(ownable)))));
        assertEq(keccak256(bound.data), keccak256(abi.encode(uint256(0), contractOwner)));
    }

    // -----------------------------------------------------------------
    //  Alias (the standard is deliberately excluded from registrationHash)
    // -----------------------------------------------------------------

    function testHybridContractAliasesERC721ContractAndOwnableClaimsOntoOneIdentity() external {
        HybridERC721Contract hybrid = new HybridERC721Contract(adapter);
        bytes32 expectedHash = adapter.registrationHash(address(hybrid), 0);

        vm.recordLogs();
        // Authorized as an unminted single-owner id 0, then under both contract authority models.
        assertEq(hybrid.counterfactualRegisterAsERC721(0, "ipfs://as-721"), expectedHash);
        assertEq(hybrid.counterfactualRegister(0), expectedHash);
        assertEq(hybrid.counterfactualRegisterAsOwnable(0, "ipfs://as-ownable"), expectedHash);
        Vm.Log[] memory logs = vm.getRecordedLogs();

        assertEq(logs.length, 3);
        bytes32 topic0 = keccak256(
            "CounterfactualAgentRegistered(bytes32,address,uint256,uint8,uint8,string,(string,bytes)[],address)"
        );
        for (uint256 i; i < 3; ++i) {
            assertEq(logs[i].emitter, address(adapter));
            assertEq(logs[i].topics[0], topic0);
            // Identical identity topics: the hash is standard-independent, and the standard is not
            // indexed either.
            assertEq(logs[i].topics[1], expectedHash);
            assertEq(logs[i].topics[2], bytes32(uint256(uint160(address(hybrid)))));
            assertEq(logs[i].topics[3], bytes32(uint256(0)));
        }

        // Only the non-indexed body distinguishes them, and log order decides the winner: the losing
        // ERC-721 and CONTRACT bodies are emitted first and the winning CONTRACT_OWNABLE body last,
        // so last-event-wins
        // resolves the identity to that claim's content — standard *and* agentURI *and* emitter.
        IERC8004IdentityRegistry.MetadataEntry[] memory empty = new IERC8004IdentityRegistry.MetadataEntry[](0);
        assertEq(
            keccak256(logs[0].data),
            keccak256(
                abi.encode(uint8(1), IERCAgentBindings.TokenStandard.ERC721, "ipfs://as-721", empty, address(hybrid))
            ),
            "log 0 is the superseded ERC-721 claim"
        );
        assertEq(
            keccak256(logs[1].data),
            keccak256(
                abi.encode(
                    uint8(1), IERCAgentBindings.TokenStandard.CONTRACT, "ipfs://erc20-agent", empty, address(hybrid)
                )
            ),
            "log 1 is the superseded contract-self claim"
        );
        assertEq(
            keccak256(logs[2].data),
            keccak256(
                abi.encode(
                    uint8(1),
                    IERCAgentBindings.TokenStandard.CONTRACT_OWNABLE,
                    "ipfs://as-ownable",
                    empty,
                    address(hybrid)
                )
            ),
            "log 2 is the winning ownable-contract claim"
        );
        assertEq(_word(logs[0].data, 1), uint8(IERCAgentBindings.TokenStandard.ERC721));
        assertEq(_word(logs[1].data, 1), uint8(IERCAgentBindings.TokenStandard.CONTRACT));
        assertEq(_word(logs[2].data, 1), uint8(IERCAgentBindings.TokenStandard.CONTRACT_OWNABLE));
    }

    // -----------------------------------------------------------------
    //  Permanent authority vs immutable bindings
    // -----------------------------------------------------------------

    function testAuthorityCanReassertClaimsButBindingsStayImmutable() external {
        uint256 firstAgentId = token.register(0);

        // The permanent authority can re-emit a counterfactual claim at any later time...
        assertEq(token.counterfactualRegister(0), adapter.registrationHash(address(token), 0));

        // ...and mint further, distinct ERC-8004 identities for the same contract, here through the
        // metadata-bearing full register overload, whose entries must land in the registry.
        uint256 secondAgentId = token.registerWithMetadata(0, _metadata("role", "treasury"));
        assertTrue(secondAgentId != firstAgentId);
        assertEq(adapter.bindingOf(secondAgentId).tokenContract, address(token));
        assertEq(uint8(adapter.bindingOf(secondAgentId).standard), uint8(IERCAgentBindings.TokenStandard.CONTRACT));
        assertEq(registry.getMetadata(secondAgentId, "role"), bytes("treasury"));
        assertEq(registry.tokenURI(secondAgentId), "ipfs://erc20-agent");
        assertEq(
            registry.getMetadata(secondAgentId, adapter.BINDING_METADATA_KEY()), abi.encodePacked(address(adapter))
        );
        assertEq(registry.getAgentWallet(secondAgentId), address(0));
        assertTrue(adapter.isController(secondAgentId, address(token)));

        // ...but an agent that is already bound can never be rebound, by anyone.
        uint256 existingAgentId = token.prepareExistingAgent(registry);
        token.bindExisting(existingAgentId, 0);

        vm.expectRevert(abi.encodeWithSelector(Adapter8004.AlreadyBound.selector, existingAgentId));
        token.bindExisting(existingAgentId, 0);

        vm.expectRevert(abi.encodeWithSelector(Adapter8004.AlreadyBound.selector, firstAgentId));
        vm.prank(stranger);
        adapter.bindExisting(firstAgentId, IERCAgentBindings.TokenStandard.ERC721, address(token), 0);

        // The original binding is byte-for-byte what it was at registration.
        IERCAgentBindings.Binding memory binding = adapter.bindingOf(firstAgentId);
        assertEq(uint8(binding.standard), uint8(IERCAgentBindings.TokenStandard.CONTRACT));
        assertEq(binding.tokenContract, address(token));
        assertEq(binding.tokenId, 0);
    }

    // -----------------------------------------------------------------
    //  Registry may not be bound
    // -----------------------------------------------------------------

    function testIdentityRegistryCannotBeBoundAsAContract() external {
        vm.expectRevert(Adapter8004.InvalidTokenContractIsRegistry.selector);
        adapter.register(IERCAgentBindings.TokenStandard.CONTRACT, address(registry), 0, "ipfs://registry");

        vm.expectRevert(Adapter8004.InvalidTokenContractIsRegistry.selector);
        adapter.registerAndSetPrimary(IERCAgentBindings.TokenStandard.CONTRACT, address(registry), 0, "ipfs://registry");

        vm.expectRevert(Adapter8004.InvalidTokenContractIsRegistry.selector);
        adapter.counterfactualRegister(
            IERCAgentBindings.TokenStandard.CONTRACT, address(registry), 0, "ipfs://registry"
        );

        // The registry rejection precedes the canonical-id check, matching the other standards.
        vm.expectRevert(Adapter8004.InvalidTokenContractIsRegistry.selector);
        adapter.register(IERCAgentBindings.TokenStandard.CONTRACT, address(registry), 1, "ipfs://registry");

        // A codeless address is still the generic rejection.
        vm.expectRevert(Adapter8004.InvalidTokenContract.selector);
        adapter.register(IERCAgentBindings.TokenStandard.CONTRACT, address(0), 0, "ipfs://zero");
    }

    // -----------------------------------------------------------------
    //  Helpers
    // -----------------------------------------------------------------

    function _assertEveryCounterfactualWriterDenied(address account) internal {
        IERC8004IdentityRegistry.MetadataEntry[] memory metadata = _metadata("k", "v");

        _expectNotController(account);
        vm.prank(account);
        adapter.counterfactualRegister(IERCAgentBindings.TokenStandard.CONTRACT, address(token), 0, "ipfs://denied");

        _expectNotController(account);
        vm.prank(account);
        adapter.counterfactualRegister(
            IERCAgentBindings.TokenStandard.CONTRACT, address(token), 0, "ipfs://denied", metadata
        );

        _expectNotController(account);
        vm.prank(account);
        adapter.counterfactualSetAgentURI(IERCAgentBindings.TokenStandard.CONTRACT, address(token), 0, "ipfs://denied");

        _expectNotController(account);
        vm.prank(account);
        adapter.counterfactualSetMetadata(IERCAgentBindings.TokenStandard.CONTRACT, address(token), 0, "k", bytes("v"));

        _expectNotController(account);
        vm.prank(account);
        adapter.counterfactualSetMetadataBatch(IERCAgentBindings.TokenStandard.CONTRACT, address(token), 0, metadata);

        _expectNotController(account);
        vm.prank(account);
        adapter.counterfactualSetAgentWallet(IERCAgentBindings.TokenStandard.CONTRACT, address(token), 0, wallet);

        _expectNotController(account);
        vm.prank(account);
        adapter.counterfactualUnsetAgentWallet(IERCAgentBindings.TokenStandard.CONTRACT, address(token), 0);
    }

    function _findLog(Vm.Log[] memory logs, bytes32 topic0) internal pure returns (Vm.Log memory found) {
        uint256 matches;
        for (uint256 i; i < logs.length; ++i) {
            if (logs[i].topics.length != 0 && logs[i].topics[0] == topic0) {
                found = logs[i];
                ++matches;
            }
        }
        require(matches == 1, "expected exactly one matching log");
    }

    /// @dev Reads the `index`-th 32-byte word of an event body without `abi.decode`, which would
    /// need the whole five-field counterfactual tuple (and blows the stack in these tests).
    function _word(bytes memory data, uint256 index) internal pure returns (uint256 value) {
        uint256 offset = index * 32;
        for (uint256 i; i < 32; ++i) {
            value = (value << 8) | uint8(data[offset + i]);
        }
    }

    function _metadata(string memory metadataKey, string memory metadataValue)
        internal
        pure
        returns (IERC8004IdentityRegistry.MetadataEntry[] memory metadata)
    {
        metadata = new IERC8004IdentityRegistry.MetadataEntry[](1);
        metadata[0] =
            IERC8004IdentityRegistry.MetadataEntry({metadataKey: metadataKey, metadataValue: bytes(metadataValue)});
    }

    /// @dev Asserts the target answers none of the ownership/balance shapes the other standards use,
    /// so probing it would revert rather than resolve.
    function _assertNoOwnershipSurface(address target) internal view {
        (bool ownerOfOk,) = target.staticcall(abi.encodeWithSignature("ownerOf(uint256)", uint256(0)));
        assertFalse(ownerOfOk, "binder must not answer ownerOf");
        (bool idBalanceOk,) =
            target.staticcall(abi.encodeWithSignature("balanceOf(address,uint256)", address(this), uint256(0)));
        assertFalse(idBalanceOk, "binder must not answer balanceOf(address,uint256)");
        (bool balanceOk,) = target.staticcall(abi.encodeWithSignature("balanceOf(address)", address(this)));
        assertFalse(balanceOk, "binder must not answer balanceOf(address)");
        (bool ownerOk,) = target.staticcall(abi.encodeWithSignature("owner()"));
        assertFalse(ownerOk, "binder must not answer owner()");
    }

    function _expectNotController(address account) internal {
        vm.expectRevert(abi.encodeWithSelector(Adapter8004.NotController.selector, account, type(uint256).max));
    }

    function _expectNotControllerOf(address account, uint256 agentId) internal {
        vm.expectRevert(abi.encodeWithSelector(Adapter8004.NotController.selector, account, agentId));
    }

    function _expectNonZeroTokenId(address tokenContract, uint256 tokenId) internal {
        vm.expectRevert(abi.encodeWithSelector(Adapter8004.NonZeroTokenIdForContract.selector, tokenContract, tokenId));
    }

    function _signAgentWallet(uint256 agentId, address newWallet, address owner, uint256 deadline)
        internal
        view
        returns (bytes memory)
    {
        bytes32 domainSeparator = keccak256(
            abi.encode(
                DOMAIN_TYPEHASH,
                keccak256(bytes("ERC8004IdentityRegistry")),
                keccak256(bytes("1")),
                block.chainid,
                address(registry)
            )
        );
        bytes32 structHash = keccak256(abi.encode(AGENT_WALLET_SET_TYPEHASH, agentId, newWallet, owner, deadline));
        (uint8 v, bytes32 r, bytes32 s) =
            vm.sign(walletPk, keccak256(abi.encodePacked(hex"1901", domainSeparator, structHash)));
        return abi.encodePacked(r, s, v);
    }
}
