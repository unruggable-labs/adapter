// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Script, console2} from "forge-std/Script.sol";

interface IOwnable {
    function owner() external view returns (address);
    function transferOwnership(address newOwner) external;
}

/// @dev Transfers ownership of WrappedBNSv2 and WrappedENS to a multisig.
///
///      Required env vars:
///        DEPLOYER_PRIVATE_KEY  – hex private key of the current owner
///        NEW_OWNER             – multisig address to receive ownership
///
///      Run:
///        NEW_OWNER=0x09cbc0d92aabe6f53ac7e84f0ba0fbfd05eb80f2 \
///        forge script script/TransferExternalOwnership.s.sol \
///          --rpc-url https://mainnet.base.org \
///          --broadcast \
///          --verify \
///          -vvvv
contract TransferExternalOwnershipScript is Script {
    address constant WRAPPED_BNS_V2 = 0xa98741B7EE20B096a6262A705A088f8c0563Dfa4;
    address constant WRAPPED_ENS    = 0xC7AFf3b228b8353d1811802F90f389815431a194;

    function run() external {
        uint256 deployerKey = vm.envUint("DEPLOYER_PRIVATE_KEY");
        address newOwner    = vm.envAddress("NEW_OWNER");

        _transfer(WRAPPED_BNS_V2, "WrappedBNSv2", deployerKey, newOwner);
        _transfer(WRAPPED_ENS,    "WrappedENS",   deployerKey, newOwner);
    }

    function _transfer(
        address contractAddr,
        string memory label,
        uint256 deployerKey,
        address newOwner
    ) internal {
        IOwnable target = IOwnable(contractAddr);
        address previousOwner = target.owner();

        console2.log("--- %s (%s) ---", label, contractAddr);
        console2.log("  current owner :", previousOwner);
        console2.log("  new owner     :", newOwner);

        vm.startBroadcast(deployerKey);
        target.transferOwnership(newOwner);
        vm.stopBroadcast();

        console2.log("  transferOwnership broadcast complete");
    }
}
