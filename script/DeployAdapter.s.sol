// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Script} from "forge-std/Script.sol";
import {ERC1967Proxy} from "@openzeppelin/contracts/proxy/ERC1967/ERC1967Proxy.sol";
import {AdapterImplementation} from "../src/AdapterImplementation.sol";

contract DeployAdapterScript is Script {
    function run() external returns (AdapterImplementation adapter) {
        // 1. Load the target ERC-8004 registry the adapter will forward into.
        address identityRegistry = vm.envAddress("IDENTITY_REGISTRY_ADDRESS");

        // 2. Load the deployer private key. The deployer becomes the admin.
        uint256 deployerKey = vm.envUint("DEPLOYER_PRIVATE_KEY");
        address deployer = vm.addr(deployerKey);

        // 3. Start the deployment broadcast as the deployer.
        vm.startBroadcast(deployerKey);

        // 4. Deploy the adapter implementation, baking the registry into its runtime code.
        AdapterImplementation implementation = new AdapterImplementation(identityRegistry);

        // 5. Deploy the proxy and initialize it with deployer-as-admin. The registry is no longer an
        //    initializer argument; it came from the constructor above.
        ERC1967Proxy proxy =
            new ERC1967Proxy(address(implementation), abi.encodeCall(AdapterImplementation.initialize, (deployer)));

        // 6. Return the proxy address typed as the adapter interface.
        adapter = AdapterImplementation(address(proxy));

        // 7. Stop the deployment broadcast.
        vm.stopBroadcast();
    }
}
