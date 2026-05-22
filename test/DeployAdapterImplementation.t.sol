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
}
