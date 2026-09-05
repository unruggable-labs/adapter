// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Test} from "forge-std/Test.sol";
import {ERC1967Proxy} from "@openzeppelin/contracts/proxy/ERC1967/ERC1967Proxy.sol";

import {Adapter8004} from "../../src/Adapter8004.sol";
import {IERC8217} from "../../src/interfaces/IERC8217.sol";
import {MockIdentityRegistry} from "../mocks/MockIdentityRegistry.sol";
import {MockDelegateRegistry} from "../mocks/MockDelegateRegistry.sol";
import {MockERC1155F} from "../mocks/MockERC1155F.sol";

/// SdR3 #1 — DelegateProfileConfusion. The ERC-1155F / ERC-6909F "ownerOf-profile" single-owner
/// path reuses the ERC-721 delegate check (`_isERC721Delegate`, :884-898). A delegate.xyz grant
/// registered at ERC-721 token scope therefore governs an ERC-1155F binding at the same coordinate.
/// NOT one of the prior 40: R1's delegate items were ACCOUNT-blanket (#6) and ownership round-trip
/// (#7); R2 had no delegate items. No prior test drives a 721-scoped grant against a 1155F binding.
contract SdR3_1_DelegateProfileConfusion is Test {
    MockIdentityRegistry internal registry;
    Adapter8004 internal adapter;
    MockDelegateRegistry internal delegateRegistry;
    MockERC1155F internal token;

    address internal admin = makeAddr("admin");
    address internal owner = makeAddr("owner");
    address internal delegate = makeAddr("delegate");
    address internal stranger = makeAddr("stranger");
    uint256 internal constant TID = 5;

    function setUp() external {
        registry = new MockIdentityRegistry();
        Adapter8004 impl = new Adapter8004(address(registry));
        ERC1967Proxy proxy = new ERC1967Proxy(address(impl), abi.encodeCall(Adapter8004.initialize, (admin)));
        adapter = Adapter8004(address(proxy));

        MockDelegateRegistry mockImpl = new MockDelegateRegistry();
        vm.etch(adapter.DELEGATE_REGISTRY(), address(mockImpl).code);
        delegateRegistry = MockDelegateRegistry(adapter.DELEGATE_REGISTRY());

        token = new MockERC1155F();
        token.mint(owner, TID);
    }

    /// Success condition: an ERC-721-scoped delegate.xyz grant makes the grantee `isController`
    /// of an ERC-1155F binding at the same (contract, tokenId).
    function test_erc721ScopedGrantGovernsErc1155FBinding() external {
        vm.prank(owner);
        uint256 agentId = adapter.register(IERC8217.Standard.ERC1155F, address(token), TID, "ipfs://a");

        delegateRegistry.delegateERC721(delegate, owner, address(token), TID, bytes32(0), true);

        assertTrue(adapter.isController(agentId, delegate), "721-scope delegate controls the 1155F binding");
        assertFalse(adapter.isController(agentId, stranger), "an undelegated stranger does not");
    }
}
