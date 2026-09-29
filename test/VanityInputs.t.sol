// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Test} from "forge-std/Test.sol";
import {DeployVanityProxy} from "../script/DeployVanityProxy.s.sol";
import {ComputeVanityInputs} from "../script/ComputeVanityInputs.s.sol";
import {AdapterImplementation} from "../src/AdapterImplementation.sol";
import {ERC1967Proxy} from "@openzeppelin/contracts/proxy/ERC1967/ERC1967Proxy.sol";

contract DeployVanityHarness is DeployVanityProxy {
    function registry() external view returns (address) {
        return _registryForChain();
    }
}

contract ComputeVanityHarness is ComputeVanityInputs {
    function registry() external view returns (address) {
        return _registryForChain();
    }
}

contract VanityInputsTest is Test {
    address constant REGISTRY = 0x8004A169FB4a3325136EB29fA0ceB6D2e539a432;
    address constant SAFE = 0x03302Df40186D9B85faEA4fbb6cC5da028B23149;
    address constant FACTORY = 0x4e59b44847b379578588920cA78FbF26c0B4956C;
    DeployVanityHarness deployer;
    ComputeVanityHarness compute;

    function setUp() external {
        deployer = new DeployVanityHarness();
        compute = new ComputeVanityHarness();
    }

    function testSupportedRegistrySelection() external {
        uint256[4] memory chains = [uint256(1), 8453, 4663, 11155111];
        for (uint256 i; i < chains.length; ++i) {
            vm.chainId(chains[i]);
            address expected = chains[i] == 11155111 ? 0x8004A818BFB912233c491871b3d84c89A494BD9e : REGISTRY;
            assertEq(deployer.registry(), expected);
            assertEq(compute.registry(), expected);
            compute.run();
        }
    }

    function testFuzzRejectUnknownChains(uint64 chain) external {
        vm.assume(chain != 1 && chain != 8453 && chain != 4663 && chain != 11155111);
        vm.chainId(chain);
        vm.setEnv("PROXY_SALT", vm.toString(bytes32(uint256(42))));
        vm.expectRevert("unsupported chain");
        deployer.run();
        vm.expectRevert("unsupported chain");
        compute.run();
    }

    function testRobinhoodFrozenHashesAndIndependentAddresses() external {
        vm.chainId(4663);
        bytes32 implHash =
            keccak256(abi.encodePacked(type(AdapterImplementation).creationCode, abi.encode(deployer.registry())));
        assertEq(implHash, 0x5b3785cf0fbcd80f67ead4953f7a775604ad6f9bbbba55040810e25f1aef1558);
        address impl = _predict(FACTORY, bytes32(0), implHash);
        assertEq(impl, 0x3d74ff0c1E0A78C5a291fA91F82f15bd54335231);
        bytes memory init = abi.encodeCall(AdapterImplementation.initialize, (SAFE));
        bytes32 proxyHash = keccak256(abi.encodePacked(type(ERC1967Proxy).creationCode, abi.encode(impl, init)));
        assertEq(proxyHash, 0xbb43a76de1130e845b39e4d6ff11934b8ccf9b4aae11084e955d7f7219cc9953);
        bytes32 salt = bytes32(uint256(42));
        assertEq(_predict(FACTORY, salt, proxyHash), vm.computeCreate2Address(salt, proxyHash, FACTORY));
    }

    function testAtomicOwnerInitializationAndActualCreate2Address() external {
        AdapterImplementation impl = new AdapterImplementation(REGISTRY);
        bytes memory init = abi.encodeCall(AdapterImplementation.initialize, (SAFE));
        bytes32 salt = keccak256("atomic-owner-test");
        bytes32 hash = keccak256(abi.encodePacked(type(ERC1967Proxy).creationCode, abi.encode(address(impl), init)));
        address predicted = _predict(address(this), salt, hash);
        ERC1967Proxy proxy = new ERC1967Proxy{salt: salt}(address(impl), init);
        assertEq(address(proxy), predicted);
        AdapterImplementation adapter = AdapterImplementation(predicted);
        assertEq(adapter.owner(), SAFE);
        assertEq(address(adapter.identityRegistry()), REGISTRY);
        vm.expectRevert();
        adapter.initialize(address(this));
        vm.expectRevert();
        impl.initialize(SAFE);
    }

    function _predict(address factory, bytes32 salt, bytes32 hash) internal pure returns (address) {
        return address(uint160(uint256(keccak256(abi.encodePacked(bytes1(0xff), factory, salt, hash)))));
    }
}
