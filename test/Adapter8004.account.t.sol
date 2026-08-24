// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Test} from "forge-std/Test.sol";
import {ERC1967Proxy} from "@openzeppelin/contracts/proxy/ERC1967/ERC1967Proxy.sol";
import {IERC721} from "@openzeppelin/contracts/token/ERC721/IERC721.sol";

import {Adapter8004} from "../src/Adapter8004.sol";
import {IERC8217} from "../src/interfaces/IERC8217.sol";
import {IERC8004IdentityRegistry} from "../src/interfaces/IERC8004IdentityRegistry.sol";
import {MockIdentityRegistry} from "./mocks/MockIdentityRegistry.sol";
import {MockDelegateRegistry} from "./mocks/MockDelegateRegistry.sol";

/// @dev Binds itself as `ACCOUNT` from inside its own constructor, when it has no runtime code yet.
/// Only `ACCOUNT` permits this, because it is the only standard that applies no code test. Records the
/// code length it saw during construction so the test can assert the premise rather than assume it, and
/// exposes a post-deployment write so the same binding can be exercised once code exists.
contract ConstructorAccountBinder {
    Adapter8004 private immutable ADAPTER;

    uint256 public agentId;
    bytes32 public ubi;
    uint256 public codeLengthDuringConstruction;

    constructor(Adapter8004 adapter, bool useCounterfactual) {
        ADAPTER = adapter;
        codeLengthDuringConstruction = address(this).code.length;

        if (useCounterfactual) {
            ubi = adapter.counterfactualRegister(IERC8217.TokenStandard.ACCOUNT, address(this), 0, "ipfs://ctor-cf");
        } else {
            agentId = adapter.register(IERC8217.TokenStandard.ACCOUNT, address(this), 0, "ipfs://ctor");
        }
    }

    function setURI(string calldata newURI) external {
        ADAPTER.setAgentURI(agentId, newURI);
    }
}

/// @dev The same constructor-time bind under a standard that still requires runtime code. Every
/// deployment reverts, which is the half that shows the code test was made standard-aware rather than
/// switched off.
contract ConstructorCodeRequiringBinder {
    constructor(Adapter8004 adapter, IERC8217.TokenStandard standard) {
        adapter.register(standard, address(this), 0, "ipfs://ctor");
    }
}

/// @dev Covers the `ACCOUNT` standard, which is the one standard that accepts an address with no
/// runtime code. The negatives here matter as much as the positives: relaxing the code test for
/// `ACCOUNT` must not relax it for the other seven standards, and must not relax either the zero
/// address or the registry-address rejection for any standard including `ACCOUNT`.
contract Adapter8004AccountTest is Test {
    Adapter8004 internal adapter;
    MockIdentityRegistry internal registry;

    address internal eoa = address(0xE0A);
    address internal admin = address(0xADD1);
    address internal hot = address(0x407);

    function setUp() external {
        registry = new MockIdentityRegistry();
        Adapter8004 implementation = new Adapter8004(address(registry));
        ERC1967Proxy proxy = new ERC1967Proxy(address(implementation), abi.encodeCall(Adapter8004.initialize, (admin)));
        adapter = Adapter8004(address(proxy));
    }

    // --- positives: a code-less address is a first-class principal under ACCOUNT ---

    function testAccountRegistersFromCodelessAddress() external {
        assertEq(eoa.code.length, 0, "fixture must have no code");

        vm.prank(eoa);
        uint256 agentId = adapter.register(IERC8217.TokenStandard.ACCOUNT, eoa, 0, "ipfs://agent");

        IERC8217.Binding memory binding = adapter.bindingOf(agentId);
        assertEq(uint8(binding.standard), uint8(IERC8217.TokenStandard.ACCOUNT), "standard");
        assertEq(binding.boundAddress, eoa, "bound address");
        assertEq(binding.tokenId, 0, "token id");
        assertTrue(adapter.isController(agentId, eoa), "the account controls its own identity");
    }

    function testAccountCounterfactualRegisterFromCodelessAddress() external {
        vm.prank(eoa);
        bytes32 ubi = adapter.counterfactualRegister(IERC8217.TokenStandard.ACCOUNT, eoa, 0, "ipfs://cf");
        assertEq(
            ubi,
            adapter.bindingHashFor(IERC8217.TokenStandard.ACCOUNT, eoa, 0),
            "hash is the ACCOUNT identity for this pair"
        );
        // Inverted from the pre-`0.0.17` assertion, which required this to equal the hash for any
        // other standard at the same pair. The standard is in the preimage now, so `(eoa, 0)` claimed
        // as `ACCOUNT` and the same pair claimed as `ERC721` are two identities, not one.
        assertTrue(ubi != adapter.bindingHashFor(IERC8217.TokenStandard.ERC721, eoa, 0), "hash is standard-specific");
    }

    /// @dev The motivating defect. Before this change the code test was the only gate, so whether an
    /// EOA could bind at all depended on whether a 7702 delegation happened to be installed at that
    /// moment: 23 bytes of designator cleared the guard, and an ordinary transaction from the same
    /// key cleared `account == boundAddress`. The exclusion was therefore accidental and unstable
    /// rather than a decision. Both shapes must now behave identically.
    function testDelegatedAndUndelegatedAccountsBehaveIdentically() external {
        address plain = address(0xA11);
        address delegated = address(0xA22);
        vm.etch(delegated, abi.encodePacked(hex"ef0100", address(0xBEEF)));
        assertEq(plain.code.length, 0, "undelegated EOA");
        assertEq(delegated.code.length, 23, "7702 delegation designator");

        vm.prank(plain);
        uint256 plainAgent = adapter.register(IERC8217.TokenStandard.ACCOUNT, plain, 0, "ipfs://a");
        vm.prank(delegated);
        uint256 delegatedAgent = adapter.register(IERC8217.TokenStandard.ACCOUNT, delegated, 0, "ipfs://b");

        assertTrue(adapter.isController(plainAgent, plain), "plain account controls");
        assertTrue(adapter.isController(delegatedAgent, delegated), "delegated account controls");
    }

    // --- negatives: everything else still rejects a code-less address ---

    function testEveryOtherStandardStillRejectsCodelessAddress() external {
        IERC8217.TokenStandard[7] memory standards = [
            IERC8217.TokenStandard.ERC721,
            IERC8217.TokenStandard.ERC1155,
            IERC8217.TokenStandard.ERC6909,
            IERC8217.TokenStandard.ERC1155F,
            IERC8217.TokenStandard.ERC6909F,
            IERC8217.TokenStandard.CONTRACT_OWNABLE,
            IERC8217.TokenStandard.CONTRACT_ADMIN
        ];

        for (uint256 i; i < standards.length; ++i) {
            vm.prank(eoa);
            vm.expectRevert(Adapter8004.InvalidBoundAddress.selector);
            adapter.register(standards[i], eoa, 0, "ipfs://x");

            vm.prank(eoa);
            vm.expectRevert(Adapter8004.InvalidBoundAddress.selector);
            adapter.counterfactualRegister(standards[i], eoa, 0, "ipfs://x");
        }
    }

    /// @dev `_bindings` uses a zero `boundAddress` as its unbound sentinel, so a zero binding would
    /// be indistinguishable from no binding. `ACCOUNT` waives the code test but must not waive this.
    function testAccountRejectsZeroAddress() external {
        vm.prank(eoa);
        vm.expectRevert(Adapter8004.InvalidBoundAddress.selector);
        adapter.register(IERC8217.TokenStandard.ACCOUNT, address(0), 0, "ipfs://x");

        vm.prank(eoa);
        vm.expectRevert(Adapter8004.InvalidBoundAddress.selector);
        adapter.counterfactualRegister(IERC8217.TokenStandard.ACCOUNT, address(0), 0, "ipfs://x");
    }

    function testAccountRejectsRegistryAddress() external {
        vm.prank(eoa);
        vm.expectRevert(Adapter8004.BoundAddressIsRegistry.selector);
        adapter.register(IERC8217.TokenStandard.ACCOUNT, address(registry), 0, "ipfs://x");
    }

    function testAccountStillRequiresCanonicalTokenId() external {
        vm.prank(eoa);
        vm.expectRevert(abi.encodeWithSelector(Adapter8004.NonZeroTokenIdForAccount.selector, eoa, uint256(1)));
        adapter.register(IERC8217.TokenStandard.ACCOUNT, eoa, 1, "ipfs://x");
    }

    function testAccountAuthorityIsSelfOnly() external {
        vm.prank(eoa);
        uint256 agentId = adapter.register(IERC8217.TokenStandard.ACCOUNT, eoa, 0, "ipfs://agent");

        address stranger = address(0xBAD);
        assertFalse(adapter.isController(agentId, stranger), "a stranger has no authority");

        vm.prank(stranger);
        vm.expectRevert(abi.encodeWithSelector(Adapter8004.NotController.selector, stranger, agentId));
        adapter.setAgentURI(agentId, "ipfs://hijacked");
    }

    // --- constructor-time binding, which the relaxation newly permits ---

    /// @dev A consequence of dropping the code test that the plan did not anticipate. A contract has no
    /// runtime code while its constructor runs, so before this change the code test rejected it and the
    /// docs stated that constructor-time binding was impossible. `ACCOUNT` applies no code test and
    /// `msg.sender` during construction is already the contract's final address, so it now succeeds.
    /// The second half of this test matters as much as the first: code appears immediately afterwards,
    /// and nothing about the binding depends on the code length it was created under.
    function testAccountBindsFromItsOwnConstructorAndKeepsControlAfterward() external {
        ConstructorAccountBinder binder = new ConstructorAccountBinder(adapter, false);

        assertEq(binder.codeLengthDuringConstruction(), 0, "premise: no runtime code during construction");
        assertGt(address(binder).code.length, 0, "code exists once deployed");

        uint256 agentId = binder.agentId();
        IERC8217.Binding memory binding = adapter.bindingOf(agentId);
        assertEq(uint8(binding.standard), uint8(IERC8217.TokenStandard.ACCOUNT), "standard");
        assertEq(binding.boundAddress, address(binder), "bound address");
        assertEq(binding.tokenId, 0, "canonical id");
        assertTrue(adapter.isController(agentId, address(binder)), "sole controller after deployment");
        assertFalse(adapter.isController(agentId, eoa), "and nobody else");

        // The binding is still usable now that the address has code, which is the after-the-fact half.
        binder.setURI("ipfs://after-deploy");
        assertEq(registry.tokenURI(agentId), "ipfs://after-deploy");
    }

    /// @dev The counterfactual register path runs the same guard, so it gains the same ability. Worth its
    /// own case because it is the entry point a constructor is most likely to reach for: it mints nothing
    /// and takes no delivery, so it has no dependency on the deploying contract being able to receive.
    function testAccountCounterfactualRegisterAlsoWorksFromAConstructor() external {
        ConstructorAccountBinder binder = new ConstructorAccountBinder(adapter, true);

        assertEq(binder.codeLengthDuringConstruction(), 0, "premise: no runtime code during construction");
        assertEq(
            binder.ubi(),
            adapter.bindingHashFor(IERC8217.TokenStandard.ACCOUNT, address(binder), 0),
            "hash matches the pair under the standard it claimed"
        );
    }

    /// @dev The contrast. Every standard that calls into the bound address still rejects a constructor-time
    /// bind, because the code test still applies to all seven and there is no runtime code yet.
    function testEveryCodeRequiringStandardStillRejectsAConstructorTimeBind() external {
        IERC8217.TokenStandard[7] memory standards = [
            IERC8217.TokenStandard.ERC721,
            IERC8217.TokenStandard.ERC1155,
            IERC8217.TokenStandard.ERC6909,
            IERC8217.TokenStandard.ERC1155F,
            IERC8217.TokenStandard.ERC6909F,
            IERC8217.TokenStandard.CONTRACT_OWNABLE,
            IERC8217.TokenStandard.CONTRACT_ADMIN
        ];

        for (uint256 i; i < standards.length; ++i) {
            vm.expectRevert(Adapter8004.InvalidBoundAddress.selector);
            new ConstructorCodeRequiringBinder(adapter, standards[i]);
        }
    }

    // --- negatives: ACCOUNT is offered no delegation route ---

    /// @dev `ACCOUNT` authority is exactly `msg.sender == boundAddress`, and the absence of a
    /// delegate.xyz route is a decision rather than an omission. An account that granted a delegation
    /// for some unrelated purpose would otherwise be handing that delegate permanent control of its
    /// agent identity, because a binding is immutable and could never withdraw it. Every delegation
    /// shape the adapter honors for the other standards is checked here. The blanket wallet-level grant
    /// is the one that matters most, since it is the shape most likely to already exist.
    function testAccountGrantsNoDelegationRoute() external {
        MockDelegateRegistry delegateRegistry = _installDelegateRegistry();
        bytes32 rights = adapter.DELEGATE_RIGHTS();

        vm.prank(eoa);
        uint256 agentId = adapter.register(IERC8217.TokenStandard.ACCOUNT, eoa, 0, "ipfs://agent");

        delegateRegistry.delegateAll(hot, eoa, rights, true);
        _assertHotHasNoAuthority(agentId, "wallet-level ALL");
        delegateRegistry.delegateAll(hot, eoa, rights, false);

        // Empty rights is honored for every other standard, so it is the widest grant available here.
        delegateRegistry.delegateAll(hot, eoa, bytes32(0), true);
        _assertHotHasNoAuthority(agentId, "wallet-level ALL with empty rights");
        delegateRegistry.delegateAll(hot, eoa, bytes32(0), false);

        delegateRegistry.delegateContract(hot, eoa, eoa, rights, true);
        _assertHotHasNoAuthority(agentId, "contract-scoped on the bound address");
        delegateRegistry.delegateContract(hot, eoa, eoa, rights, false);

        delegateRegistry.delegateERC721(hot, eoa, eoa, 0, rights, true);
        _assertHotHasNoAuthority(agentId, "token-scoped on the bound address at the canonical id");
    }

    /// @dev The same rule before any binding exists. A delegation cannot be used to claim the identity
    /// of the address that granted it, on either the on-chain or the counterfactual path.
    function testAccountDelegateCannotClaimTheAccountIdentity() external {
        MockDelegateRegistry delegateRegistry = _installDelegateRegistry();
        delegateRegistry.delegateAll(hot, eoa, adapter.DELEGATE_RIGHTS(), true);

        vm.prank(hot);
        vm.expectRevert(abi.encodeWithSelector(Adapter8004.NotController.selector, hot, type(uint256).max));
        adapter.register(IERC8217.TokenStandard.ACCOUNT, eoa, 0, "ipfs://hot");

        vm.prank(hot);
        vm.expectRevert(abi.encodeWithSelector(Adapter8004.NotController.selector, hot, type(uint256).max));
        adapter.counterfactualRegister(IERC8217.TokenStandard.ACCOUNT, eoa, 0, "ipfs://hot");
    }

    /// @dev Extends the sentinel invariant past `register`. Under every standard other than `ACCOUNT`
    /// the code test also rejects `address(0)` and reverts with the same selector, so the zero clause is
    /// only separately observable under `ACCOUNT`. Checking it at each entry point is therefore the only
    /// way the invariant gets a margin worth having.
    function testAccountRejectsZeroAddressAtEveryEntryPoint() external {
        vm.startPrank(eoa);

        vm.expectRevert(Adapter8004.InvalidBoundAddress.selector);
        adapter.register(IERC8217.TokenStandard.ACCOUNT, address(0), 0, "ipfs://x");

        vm.expectRevert(Adapter8004.InvalidBoundAddress.selector);
        adapter.counterfactualRegister(IERC8217.TokenStandard.ACCOUNT, address(0), 0, "ipfs://x");

        vm.expectRevert(Adapter8004.InvalidBoundAddress.selector);
        adapter.counterfactualSetAgentURI(IERC8217.TokenStandard.ACCOUNT, address(0), 0, "ipfs://x");

        vm.expectRevert(Adapter8004.InvalidBoundAddress.selector);
        adapter.counterfactualSetMetadata(IERC8217.TokenStandard.ACCOUNT, address(0), 0, "k", bytes("v"));

        IERC8004IdentityRegistry.MetadataEntry[] memory batch = new IERC8004IdentityRegistry.MetadataEntry[](1);
        batch[0] = IERC8004IdentityRegistry.MetadataEntry({metadataKey: "k", metadataValue: bytes("v")});
        vm.expectRevert(Adapter8004.InvalidBoundAddress.selector);
        adapter.counterfactualSetMetadataBatch(IERC8217.TokenStandard.ACCOUNT, address(0), 0, batch);

        vm.expectRevert(Adapter8004.InvalidBoundAddress.selector);
        adapter.counterfactualSetAgentWallet(IERC8217.TokenStandard.ACCOUNT, address(0), 0, eoa);

        vm.expectRevert(Adapter8004.InvalidBoundAddress.selector);
        adapter.counterfactualUnsetAgentWallet(IERC8217.TokenStandard.ACCOUNT, address(0), 0);

        vm.stopPrank();
    }

    // --- helpers ---

    /// @dev Places the delegate.xyz v2 mock at the canonical hardcoded address the adapter reads, so a
    /// delegation can actually be granted under test. Installed per test rather than in `setUp` so the
    /// code-test cases above keep running against a bare fixture.
    function _installDelegateRegistry() private returns (MockDelegateRegistry) {
        MockDelegateRegistry impl = new MockDelegateRegistry();
        vm.etch(adapter.DELEGATE_REGISTRY(), address(impl).code);
        return MockDelegateRegistry(adapter.DELEGATE_REGISTRY());
    }

    function _assertHotHasNoAuthority(uint256 agentId, string memory shape) private {
        assertFalse(adapter.isController(agentId, hot), shape);

        vm.prank(hot);
        vm.expectRevert(abi.encodeWithSelector(Adapter8004.NotController.selector, hot, agentId));
        adapter.setAgentURI(agentId, "ipfs://hijacked");

        vm.prank(hot);
        vm.expectRevert(abi.encodeWithSelector(Adapter8004.NotController.selector, hot, agentId));
        adapter.setMetadata(agentId, "k", bytes("v"));
    }
}
