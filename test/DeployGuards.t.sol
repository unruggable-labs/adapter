// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Test} from "forge-std/Test.sol";
import {DeployAdapterScript} from "../script/DeployAdapter.s.sol";
import {DeployVanityProxy} from "../script/DeployVanityProxy.s.sol";
import {VanityChainConfig} from "../script/VanityChainConfig.sol";
import {AdapterImplementation} from "../src/AdapterImplementation.sol";
import {MockIdentityRegistry} from "./mocks/MockIdentityRegistry.sol";

/// @notice The fresh deployment scripts must refuse every chain that already runs an adapter proxy,
/// so an operator cannot create a second proxy by running the wrong script.
contract DeployGuardsTest is Test {
    uint256 constant DEPLOYER_KEY = 0xA11CE;

    function _liveChains() internal pure returns (uint256[4] memory chains, address[4] memory proxies) {
        chains = [uint256(1), 8453, 11155111, 4663];
        proxies = [
            0xde152AfB7db5373F34876E1499fbD893A82dD336,
            0x270d25D2c59A8bcA1B0f40ad95fF7806c0025c27,
            0x7621630cB63a73a194f45A3E6801B8C6A7eC2f92,
            0x000000009d62675362a58911e3f32FEcf46F5E18
        ];
    }

    function testLiveProxyTable() external pure {
        (uint256[4] memory chains, address[4] memory proxies) = _liveChains();
        for (uint256 i; i < chains.length; ++i) {
            assertEq(VanityChainConfig.liveProxyForChain(chains[i]), proxies[i]);
        }
        assertEq(VanityChainConfig.liveProxyForChain(31337), address(0));
    }

    function testDeployAdapterRefusesEveryChainWithALiveProxy() external {
        (uint256[4] memory chains, address[4] memory proxies) = _liveChains();
        DeployAdapterScript script = new DeployAdapterScript();
        vm.setEnv("IDENTITY_REGISTRY_ADDRESS", vm.toString(address(new MockIdentityRegistry())));
        vm.setEnv("DEPLOYER_PRIVATE_KEY", vm.toString(DEPLOYER_KEY));
        for (uint256 i; i < chains.length; ++i) {
            vm.chainId(chains[i]);
            vm.expectRevert(abi.encodeWithSelector(VanityChainConfig.ProxyAlreadyLive.selector, chains[i], proxies[i]));
            script.run();
        }
    }

    function testDeployAdapterStillWorksOnAFreshChain() external {
        DeployAdapterScript script = new DeployAdapterScript();
        MockIdentityRegistry registry = new MockIdentityRegistry();
        vm.setEnv("IDENTITY_REGISTRY_ADDRESS", vm.toString(address(registry)));
        vm.setEnv("DEPLOYER_PRIVATE_KEY", vm.toString(DEPLOYER_KEY));
        vm.chainId(31337);
        AdapterImplementation adapter = script.run();
        assertEq(adapter.owner(), vm.addr(DEPLOYER_KEY));
        assertEq(address(adapter.identityRegistry()), address(registry));
    }

    function testDeployVanityProxyRefusesEveryChainWithALiveProxy() external {
        (uint256[4] memory chains, address[4] memory proxies) = _liveChains();
        DeployVanityProxy script = new DeployVanityProxy();
        vm.setEnv("PROXY_SALT", vm.toString(bytes32(uint256(42))));
        for (uint256 i; i < chains.length; ++i) {
            vm.chainId(chains[i]);
            vm.expectRevert(abi.encodeWithSelector(VanityChainConfig.ProxyAlreadyLive.selector, chains[i], proxies[i]));
            script.run();
        }
    }

    function testDeployVanityProxyStillRejectsUnknownChainsFirst() external {
        DeployVanityProxy script = new DeployVanityProxy();
        vm.setEnv("PROXY_SALT", vm.toString(bytes32(uint256(42))));
        vm.chainId(31337);
        vm.expectRevert("unsupported chain");
        script.run();
    }
}
