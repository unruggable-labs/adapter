// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Test} from "forge-std/Test.sol";
import {ERC1967Proxy} from "@openzeppelin/contracts/proxy/ERC1967/ERC1967Proxy.sol";
import {AdapterImplementation} from "../../src/AdapterImplementation.sol";
import {IERC8217} from "../../src/interfaces/IERC8217.sol";
import {MockIdentityRegistry} from "../mocks/MockIdentityRegistry.sol";

/// R1 #11 was unvalidated coordinates. This is abi.encode word-alignment vs a packed second-preimage.
contract GrokR2_7_EncodePreimage is Test {
    /// Success condition: (address(1), tokenId=0) collides with (address(0), tokenId=2^160) under hashBinding.
    function test_defense_addressAndTokenIdOccupySeparateEncodeWords() external {
        MockIdentityRegistry registry = new MockIdentityRegistry();
        AdapterImplementation adapter = AdapterImplementation(
            address(
                new ERC1967Proxy(
                    address(new AdapterImplementation(address(registry))),
                    abi.encodeCall(AdapterImplementation.initialize, (makeAddr("admin")))
                )
            )
        );
        address one = address(1);
        bytes32 a = adapter.hashBinding(IERC8217.Standard.ERC721, one, 0);
        bytes32 b = adapter.hashBinding(IERC8217.Standard.ERC721, address(0), uint256(1) << 160);
        assertTrue(a != b, "abi.encode does not pack address into tokenId");
        bytes32 c = adapter.hashBinding(IERC8217.Standard.ERC1155, one, 0);
        assertTrue(a != c, "standard is its own 32-byte word");
    }
}
