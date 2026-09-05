// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Test} from "forge-std/Test.sol";
import {ERC1967Proxy} from "@openzeppelin/contracts/proxy/ERC1967/ERC1967Proxy.sol";

import {Adapter8004} from "../../src/Adapter8004.sol";
import {IERC8217} from "../../src/interfaces/IERC8217.sol";
import {MockIdentityRegistry} from "../mocks/MockIdentityRegistry.sol";
import {MockERC1155} from "../mocks/MockERC1155.sol";

/// SdR3 #11 — MultiHolderMetadataLastWins. Plain ERC-1155 control is any positive balance
/// (:820-822), so two legitimate co-holders can both emit `CounterfactualMetadataSet` for the same
/// UBID and key in the same block; only log order (higher index) resolves it. NOT one of the prior
/// 40: R1 #14 was pre-claim poisoning by one actor; none tests two concurrent legitimate holders
/// racing the same key. Defended-by-design: multi-holder control is the documented ERC-1155 model.
contract SdR3_11_MultiHolderMetadataLastWins is Test {
    MockIdentityRegistry internal registry;
    Adapter8004 internal adapter;
    MockERC1155 internal token;

    address internal admin = makeAddr("admin");
    address internal holderA = makeAddr("holderA");
    address internal holderB = makeAddr("holderB");
    uint256 internal constant TID = 7;

    function setUp() external {
        registry = new MockIdentityRegistry();
        Adapter8004 impl = new Adapter8004(address(registry));
        ERC1967Proxy proxy = new ERC1967Proxy(address(impl), abi.encodeCall(Adapter8004.initialize, (admin)));
        adapter = Adapter8004(address(proxy));
        token = new MockERC1155();
        token.mint(holderA, TID, 1);
        token.mint(holderB, TID, 1);
    }

    /// Success condition: both co-holders can emit competing counterfactual metadata for one UBID.
    function test_twoHoldersBothAuthorizedToWriteSameKey() external {
        vm.prank(holderA);
        bytes32 ubidA = adapter.counterfactualSetMetadata(IERC8217.Standard.ERC1155, address(token), TID, "k", bytes("A"));

        vm.prank(holderB);
        bytes32 ubidB = adapter.counterfactualSetMetadata(IERC8217.Standard.ERC1155, address(token), TID, "k", bytes("B"));

        assertEq(ubidA, ubidB, "same UBID; last emitted log wins off-chain, chain does not arbitrate");
    }
}
