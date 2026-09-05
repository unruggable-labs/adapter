// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Test} from "forge-std/Test.sol";
import {ERC1967Proxy} from "@openzeppelin/contracts/proxy/ERC1967/ERC1967Proxy.sol";

import {Adapter8004} from "../../src/Adapter8004.sol";
import {IERC8217} from "../../src/interfaces/IERC8217.sol";
import {MockIdentityRegistry} from "../mocks/MockIdentityRegistry.sol";
import {MockDelegateRegistry} from "../mocks/MockDelegateRegistry.sol";
import {MockERC721} from "../mocks/MockERC721.sol";

/// SdR3 #3 — SubdelegationNotTransitive. A delegate of the owner cannot re-delegate the adapter
/// authority onward: every adapter check names the current owner as `from`, so a grant whose `from`
/// is the first-hop delegate matches nothing. NOT one of the prior 40: no prior scenario probes a
/// delegate-of-a-delegate chain.
contract SdR3_3_SubdelegationNotTransitive is Test {
    MockIdentityRegistry internal registry;
    Adapter8004 internal adapter;
    MockDelegateRegistry internal delegateRegistry;
    MockERC721 internal token;

    address internal admin = makeAddr("admin");
    address internal owner = makeAddr("owner");
    address internal eve = makeAddr("eve");
    address internal mallory = makeAddr("mallory");
    uint256 internal constant TID = 1;

    function setUp() external {
        registry = new MockIdentityRegistry();
        Adapter8004 impl = new Adapter8004(address(registry));
        ERC1967Proxy proxy = new ERC1967Proxy(address(impl), abi.encodeCall(Adapter8004.initialize, (admin)));
        adapter = Adapter8004(address(proxy));

        MockDelegateRegistry mockImpl = new MockDelegateRegistry();
        vm.etch(adapter.DELEGATE_REGISTRY(), address(mockImpl).code);
        delegateRegistry = MockDelegateRegistry(adapter.DELEGATE_REGISTRY());

        token = new MockERC721();
        token.mint(owner, TID);
    }

    /// Success condition (defense): a subdelegation from Eve to Mallory grants Mallory nothing,
    /// while Eve's direct grant from the owner works.
    function test_subdelegationConfersNothing() external {
        vm.prank(owner);
        uint256 agentId = adapter.register(IERC8217.Standard.ERC721, address(token), TID, "ipfs://a");

        delegateRegistry.delegateERC721(eve, owner, address(token), TID, bytes32(0), true);
        delegateRegistry.delegateAll(mallory, eve, bytes32(0), true); // Eve tries to pass it on.

        assertTrue(adapter.isController(agentId, eve), "direct owner delegate works");
        assertFalse(adapter.isController(agentId, mallory), "subdelegate gains nothing (not transitive)");
    }
}
