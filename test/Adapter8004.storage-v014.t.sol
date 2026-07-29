// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Test} from "forge-std/Test.sol";
import {ERC1967Proxy} from "@openzeppelin/contracts/proxy/ERC1967/ERC1967Proxy.sol";
import {IERC721} from "@openzeppelin/contracts/token/ERC721/IERC721.sol";
import {ReentrancyGuard} from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import {Initializable} from "@openzeppelin/contracts-upgradeable/proxy/utils/Initializable.sol";
import {OwnableUpgradeable} from "@openzeppelin/contracts-upgradeable/access/OwnableUpgradeable.sol";
import {UUPSUpgradeable} from "@openzeppelin/contracts-upgradeable/proxy/utils/UUPSUpgradeable.sol";
import {Adapter8004} from "../src/Adapter8004.sol";
import {IDelegateRegistry} from "../src/interfaces/IDelegateRegistry.sol";
import {IERCAgentBindings} from "../src/interfaces/IERCAgentBindings.sol";
import {IERC8004IdentityRegistry} from "../src/interfaces/IERC8004IdentityRegistry.sol";
import {MockIdentityRegistry} from "./mocks/MockIdentityRegistry.sol";
import {MockERC721} from "./mocks/MockERC721.sol";
import {MockDelegateRegistry} from "./mocks/MockDelegateRegistry.sol";

/// @dev Minimal test implementation with the exact regular storage baseline shared by the
/// a20035c Mainnet/Base implementation and the 4647ddd Sepolia implementation. Test-only helpers
/// expose slot-1 setup without inventing any slots after `_bindings`.
abstract contract Adapter8004LiveBaseline is Initializable, OwnableUpgradeable, UUPSUpgradeable, ReentrancyGuard {
    IERC8004IdentityRegistry public identityRegistry;
    mapping(uint256 agentId => IERCAgentBindings.Binding binding) private _bindings;

    constructor() {
        _disableInitializers();
    }

    function initialize(address identityRegistry_, address initialOwner) external initializer {
        __Ownable_init(initialOwner);
        identityRegistry = IERC8004IdentityRegistry(identityRegistry_);
    }

    function seedLiveBinding(
        uint256 agentId,
        IERCAgentBindings.TokenStandard standard,
        address tokenContract,
        uint256 tokenId
    ) external onlyOwner {
        _bindings[agentId] =
            IERCAgentBindings.Binding({standard: standard, tokenContract: tokenContract, tokenId: tokenId});
    }

    function bindingOf(uint256 agentId) external view returns (IERCAgentBindings.Binding memory) {
        return _bindings[agentId];
    }

    function isController(uint256 agentId, address account) external view returns (bool) {
        IERCAgentBindings.Binding memory binding = _bindings[agentId];
        address tokenOwner = IERC721(binding.tokenContract).ownerOf(binding.tokenId);
        return account == tokenOwner || _isDelegate(account, tokenOwner, binding.tokenContract, binding.tokenId);
    }

    function _isDelegate(address account, address owner, address tokenContract, uint256 tokenId)
        internal
        view
        virtual
        returns (bool);

    function _authorizeUpgrade(address) internal override onlyOwner {}
}

contract Adapter8004MainnetBaseBaseline is Adapter8004LiveBaseline {
    function _isDelegate(address, address, address, uint256) internal pure override returns (bool) {
        return false;
    }
}

contract Adapter8004SepoliaBaseline is Adapter8004LiveBaseline {
    address public constant DELEGATE_REGISTRY = 0x00000000000000447e69651d841bD8D104Bed493;
    bytes32 public constant DELEGATE_RIGHTS = keccak256("adapter8004.manage");

    function _isDelegate(address account, address owner, address tokenContract, uint256 tokenId)
        internal
        view
        override
        returns (bool)
    {
        if (DELEGATE_REGISTRY.code.length == 0) return false;
        return IDelegateRegistry(DELEGATE_REGISTRY).checkDelegateForERC721(
            account, owner, tokenContract, tokenId, DELEGATE_RIGHTS
        );
    }
}

contract Adapter8004StorageV014Test is Test {
    address internal constant DELEGATE_REGISTRY = 0x00000000000000447e69651d841bD8D104Bed493;
    bytes32 internal constant DELEGATE_RIGHTS = keccak256("adapter8004.manage");

    MockIdentityRegistry internal registry;
    MockERC721 internal token;
    address internal account = makeAddr("new-primary-account");
    address internal cold = makeAddr("cold");
    address internal hot = makeAddr("hot");

    function setUp() external {
        registry = new MockIdentityRegistry();
        token = new MockERC721();
        token.mint(cold, 41);
    }

    function testDirectUpgradeFromMainnetBaseLiveBaselinePreservesSlotsZeroAndOne() external {
        Adapter8004LiveBaseline baseline = _deployBaseline(new Adapter8004MainnetBaseBaseline());
        baseline.seedLiveBinding(7, IERCAgentBindings.TokenStandard.ERC721, address(token), 41);
        address proxy = address(baseline);

        assertEq(address(uint160(uint256(vm.load(proxy, bytes32(uint256(0)))))), address(registry));
        _assertSlotsTwoThroughFourEmpty(proxy);

        Adapter8004 adapter = _upgrade(baseline);

        assertEq(address(adapter.identityRegistry()), address(registry));
        IERCAgentBindings.Binding memory binding = adapter.bindingOf(7);
        assertEq(uint8(binding.standard), uint8(IERCAgentBindings.TokenStandard.ERC721));
        assertEq(binding.tokenContract, address(token));
        assertEq(binding.tokenId, 41);
        assertEq(adapter.primaryAgentOf(account), type(uint256).max);
        assertEq(adapter.primaryCounterfactualAgentOf(account), bytes32(type(uint256).max));
        assertEq(adapter.primaryAgentNonces(account), 0);
        _assertSlotsTwoThroughFourEmpty(proxy);

        vm.startPrank(account);
        adapter.setPrimaryAgent(9);
        adapter.setPrimaryCounterfactualAgent(address(token), 41);
        vm.stopPrank();

        assertEq(uint256(vm.load(proxy, _mappingSlot(account, 2))), ~uint256(9));
        assertEq(vm.load(proxy, _mappingSlot(account, 3)), ~adapter.registrationHash(address(token), 41));

        vm.store(proxy, _mappingSlot(account, 4), bytes32(uint256(11)));
        assertEq(adapter.primaryAgentNonces(account), 11);
    }

    function testDirectUpgradeFromSepoliaLiveBaselineRetainsDelegateXyzBehavior() external {
        MockDelegateRegistry mockImpl = new MockDelegateRegistry();
        vm.etch(DELEGATE_REGISTRY, address(mockImpl).code);
        MockDelegateRegistry delegateRegistry = MockDelegateRegistry(DELEGATE_REGISTRY);
        delegateRegistry.delegateERC721(hot, cold, address(token), 41, DELEGATE_RIGHTS, true);

        Adapter8004LiveBaseline baseline = _deployBaseline(new Adapter8004SepoliaBaseline());
        baseline.seedLiveBinding(7, IERCAgentBindings.TokenStandard.ERC721, address(token), 41);
        assertTrue(baseline.isController(7, hot));
        _assertSlotsTwoThroughFourEmpty(address(baseline));

        Adapter8004 adapter = _upgrade(baseline);

        assertEq(adapter.DELEGATE_REGISTRY(), DELEGATE_REGISTRY);
        assertEq(adapter.DELEGATE_RIGHTS(), DELEGATE_RIGHTS);
        assertTrue(adapter.isController(7, hot));
        _assertSlotsTwoThroughFourEmpty(address(adapter));
    }

    function _deployBaseline(Adapter8004LiveBaseline implementation) private returns (Adapter8004LiveBaseline) {
        return Adapter8004LiveBaseline(
            address(
                new ERC1967Proxy(
                    address(implementation),
                    abi.encodeCall(Adapter8004LiveBaseline.initialize, (address(registry), address(this)))
                )
            )
        );
    }

    function _upgrade(Adapter8004LiveBaseline baseline) private returns (Adapter8004 adapter) {
        Adapter8004 replacement = new Adapter8004();
        baseline.upgradeToAndCall(address(replacement), bytes(""));
        adapter = Adapter8004(address(baseline));
    }

    function _assertSlotsTwoThroughFourEmpty(address proxy) private view {
        for (uint256 slot = 2; slot <= 4; ++slot) {
            assertEq(vm.load(proxy, _mappingSlot(account, slot)), bytes32(0));
        }
    }

    function _mappingSlot(address key, uint256 slot) private pure returns (bytes32) {
        return keccak256(abi.encode(key, slot));
    }
}
