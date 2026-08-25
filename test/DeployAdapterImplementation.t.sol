// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Test} from "forge-std/Test.sol";
import {DeployAdapterImplementationScript} from "../script/DeployAdapterImplementation.s.sol";

contract DeployAdapterImplementationScriptTest is Test {
    function testRunRejectsMismatchedProxyForChainBeforeFileWrite() external {
        DeployAdapterImplementationScript script = new DeployAdapterImplementationScript();
        address supplied = 0x270d25D2c59A8bcA1B0f40ad95fF7806c0025c27;
        address expected = 0xde152AfB7db5373F34876E1499fbD893A82dD336;

        vm.chainId(1);
        vm.setEnv("ADAPTER_PROXY_ADDRESS", vm.toString(supplied));

        vm.expectRevert(
            abi.encodeWithSelector(
                DeployAdapterImplementationScript.MismatchedProxyForChain.selector, uint256(1), expected, supplied
            )
        );
        script.run();
    }

    function testRunRejectsRegistryEnvThatDoesNotMatchLiveProxyBeforeBroadcast() external {
        DeployAdapterImplementationScript script = new DeployAdapterImplementationScript();
        address proxy = 0xde152AfB7db5373F34876E1499fbD893A82dD336;
        address liveRegistry = makeAddr("live registry");
        address suppliedRegistry = makeAddr("wrong registry");

        vm.chainId(1);
        vm.setEnv("ADAPTER_PROXY_ADDRESS", vm.toString(proxy));
        vm.setEnv("DEPLOYER_PRIVATE_KEY", vm.toString(uint256(1)));
        vm.setEnv("IDENTITY_REGISTRY_ADDRESS", vm.toString(suppliedRegistry));
        vm.mockCall(proxy, abi.encodeWithSignature("identityRegistry()"), abi.encode(liveRegistry));

        vm.expectRevert(bytes("IDENTITY_REGISTRY_ADDRESS does not match the live proxy registry"));
        script.run();
    }
}
