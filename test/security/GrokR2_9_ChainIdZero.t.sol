// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Test} from "forge-std/Test.sol";
import {ERC1967Proxy} from "@openzeppelin/contracts/proxy/ERC1967/ERC1967Proxy.sol";
import {AdapterImplementation} from "../../src/AdapterImplementation.sol";
import {IERC8217} from "../../src/interfaces/IERC8217.sol";
import {MockIdentityRegistry} from "../mocks/MockIdentityRegistry.sol";
import {MockERC721} from "../mocks/MockERC721.sol";

/// R1 #13 used nonzero chainids. This is chainid=0, which ERC-7930 rejects.
contract GrokR2_9_ChainIdZero is Test {
    /// Success condition: chainid 0 still derives a UBID, colliding with another chain's encoding.
    function test_defense_chainIdZeroRevertsInvalidChainId() external {
        MockIdentityRegistry registry = new MockIdentityRegistry();
        AdapterImplementation adapter = AdapterImplementation(
            address(
                new ERC1967Proxy(
                    address(new AdapterImplementation(address(registry))),
                    abi.encodeCall(AdapterImplementation.initialize, (makeAddr("admin")))
                )
            )
        );
        MockERC721 token = new MockERC721();
        vm.chainId(0);
        vm.expectRevert(AdapterImplementation.InvalidChainId.selector);
        adapter.hashBinding(IERC8217.Standard.ERC721, address(token), 1);
        vm.expectRevert(AdapterImplementation.InvalidChainId.selector);
        adapter.interoperableAddress(address(adapter));
        vm.expectRevert(AdapterImplementation.InvalidChainId.selector);
        adapter.chainIdentifier();
    }
}
