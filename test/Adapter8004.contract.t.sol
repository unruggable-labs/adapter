// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Test} from "forge-std/Test.sol";
import {ERC1967Proxy} from "@openzeppelin/contracts/proxy/ERC1967/ERC1967Proxy.sol";

import {Adapter8004} from "../src/Adapter8004.sol";
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
    //  Unsigned counterfactual surface
    // -----------------------------------------------------------------

    function testCounterfactualRegisterFallsThroughTheSameAuthorityChain() external {
        bytes32 expectedHash = adapter.registrationHash(address(token), 0);
        assertEq(token.counterfactualRegister(0), expectedHash);

        token.counterfactualSetAgentWallet(0, wallet);

        _expectNotController(stranger);
        vm.prank(stranger);
        adapter.counterfactualRegister(IERCAgentBindings.TokenStandard.CONTRACT, address(token), 0, "ipfs://stranger");

        _expectNotController(holder);
        vm.prank(holder);
        adapter.counterfactualSetAgentWallet(IERCAgentBindings.TokenStandard.CONTRACT, address(token), 0, wallet);
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

    // -----------------------------------------------------------------
    //  Helpers
    // -----------------------------------------------------------------

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
