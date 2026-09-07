// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Test} from "forge-std/Test.sol";
import {ERC1967Proxy} from "@openzeppelin/contracts/proxy/ERC1967/ERC1967Proxy.sol";

import {AdapterImplementation} from "../../src/AdapterImplementation.sol";
import {MockIdentityRegistry} from "../mocks/MockIdentityRegistry.sol";

/// SdR3 #16 — TokenURIUnboundPassthrough. `tokenURI` forwards to the registry with no binding check
/// (:186-188), so it returns real data for an identity minted DIRECTLY on the registry (never via the
/// adapter, no `agent-binding` record). A consumer treating adapter `tokenURI` as proof of an
/// adapter binding is misled, yet `bindingOf` correctly reverts. NOT one of the prior 40: R2 #5
/// checked `ownerOf`/`isController`/`bindingOf` skew on an unbound id; it did not contrast a
/// truthful `tokenURI` passthrough against a reverting `bindingOf`. Defended: the view forwarders
/// are intentionally binding-agnostic; authority/binding views are not.
contract SdR3_16_TokenURIUnboundPassthrough is Test {
    MockIdentityRegistry internal registry;
    AdapterImplementation internal adapter;

    address internal admin = makeAddr("admin");
    address internal stranger = makeAddr("stranger");

    function setUp() external {
        registry = new MockIdentityRegistry();
        AdapterImplementation impl = new AdapterImplementation(address(registry));
        ERC1967Proxy proxy = new ERC1967Proxy(address(impl), abi.encodeCall(AdapterImplementation.initialize, (admin)));
        adapter = AdapterImplementation(address(proxy));
    }

    /// Success condition: adapter `tokenURI` returns data for a directly-registered id while
    /// `bindingOf` reverts `UnknownAgent`.
    function test_tokenURIForwardsForUnboundIdentity() external {
        vm.prank(stranger);
        uint256 directId = registry.register("ipfs://direct-not-via-adapter");

        assertEq(adapter.tokenURI(directId), "ipfs://direct-not-via-adapter", "tokenURI forwards regardless of binding");

        vm.expectRevert(abi.encodeWithSelector(AdapterImplementation.UnknownAgent.selector, directId));
        adapter.bindingOf(directId);
    }
}
