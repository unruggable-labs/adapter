// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Script} from "forge-std/Script.sol";
import {AdapterImplementation} from "../src/AdapterImplementation.sol";

contract TransferAdapterOwnershipScript is Script {
    function run() external returns (address proxy, address previousOwner, address newOwner) {
        proxy = vm.envAddress("ADAPTER_PROXY_ADDRESS");
        newOwner = vm.envAddress("ADAPTER_NEW_OWNER");
        uint256 ownerKey = vm.envUint("DEPLOYER_PRIVATE_KEY");

        AdapterImplementation adapter = AdapterImplementation(payable(proxy));
        previousOwner = adapter.owner();

        vm.startBroadcast(ownerKey);
        adapter.transferOwnership(newOwner);
        vm.stopBroadcast();
    }
}
