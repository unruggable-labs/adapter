// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Script} from "forge-std/Script.sol";
import {Adapter8004} from "../src/Adapter8004.sol";

contract UpgradeAdapterScript is Script {
    function run() external returns (address proxy, address implementation) {
        proxy = vm.envAddress("ADAPTER_PROXY_ADDRESS");
        uint256 ownerKey = vm.envUint("DEPLOYER_PRIVATE_KEY");

        // Read the registry the live proxy already points at and bake exactly that one into the new
        // implementation. `_authorizeUpgrade` on the outgoing implementation checks the same
        // equality, so a mismatch here fails on chain rather than repointing the proxy.
        address registry = address(Adapter8004(payable(proxy)).identityRegistry());
        require(registry != address(0), "proxy reports no registry");

        vm.startBroadcast(ownerKey);

        implementation = address(new Adapter8004(registry));
        require(
            address(Adapter8004(payable(implementation)).identityRegistry()) == registry,
            "new implementation reports a different registry"
        );
        Adapter8004(payable(proxy)).upgradeToAndCall(implementation, bytes(""));

        vm.stopBroadcast();
    }
}
