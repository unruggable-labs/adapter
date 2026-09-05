// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Test} from "forge-std/Test.sol";
import {ERC1967Proxy} from "@openzeppelin/contracts/proxy/ERC1967/ERC1967Proxy.sol";
import {Adapter8004} from "../../src/Adapter8004.sol";
import {IERC8217} from "../../src/interfaces/IERC8217.sol";
import {MockIdentityRegistry} from "../mocks/MockIdentityRegistry.sol";
import {MockERC721} from "../mocks/MockERC721.sol";

/// R1 #13 was same adapter, same/different chainid. This is two proxies, one chain, one token.
contract GrokR2_6_CrossProxyUbid is Test {
    /// Success condition: two adapter proxies derive the same UBID for one token, so history collides.
    function test_defense_twoProxiesDoNotShareAUbid() external {
        MockIdentityRegistry registry = new MockIdentityRegistry();
        address admin = makeAddr("admin");
        Adapter8004 a = Adapter8004(
            address(
                new ERC1967Proxy(
                    address(new Adapter8004(address(registry))), abi.encodeCall(Adapter8004.initialize, (admin))
                )
            )
        );
        Adapter8004 b = Adapter8004(
            address(
                new ERC1967Proxy(
                    address(new Adapter8004(address(registry))), abi.encodeCall(Adapter8004.initialize, (admin))
                )
            )
        );
        MockERC721 token = new MockERC721();
        bytes32 ha = a.hashBinding(IERC8217.Standard.ERC721, address(token), 1);
        bytes32 hb = b.hashBinding(IERC8217.Standard.ERC721, address(token), 1);
        assertTrue(ha != hb, "adapter interoperable address is in the preimage");
        assertEq(ha, a.hashBinding(IERC8217.Standard.ERC721, address(token), 1));
    }
}
