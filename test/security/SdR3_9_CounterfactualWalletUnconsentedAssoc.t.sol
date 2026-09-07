// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Test} from "forge-std/Test.sol";
import {ERC1967Proxy} from "@openzeppelin/contracts/proxy/ERC1967/ERC1967Proxy.sol";

import {AdapterImplementation} from "../../src/AdapterImplementation.sol";
import {IERC8217} from "../../src/interfaces/IERC8217.sol";
import {IERC8004AdapterCounterfactual} from "../../src/interfaces/IERC8004AdapterCounterfactual.sol";
import {MockIdentityRegistry} from "../mocks/MockIdentityRegistry.sol";
import {MockERC721} from "../mocks/MockERC721.sol";

/// SdR3 #9 — CounterfactualWalletUnconsentedAssoc. `counterfactualSetAgentWallet` (:451-467) lets a
/// controller name ANY `newWallet` for a counterfactual identity with no consent — unlike on-chain
/// `setAgentWallet`, which the registry gates with a wallet signature. A controller can forge an
/// agent->victim wallet association in the log. NOT one of the prior 40: R1 #15 used the caller as
/// the wallet in the combined AndUBID path; this is the arbitrary-`newWallet` single setter.
/// Defended-by-design: the interface documents this as an unverified off-chain claim consumers must
/// confirm via the reverse (WalletUBID) direction.
contract SdR3_9_CounterfactualWalletUnconsentedAssoc is Test {
    event CounterfactualAgentWalletSet(
        bytes32 indexed ubid,
        address indexed boundAddress,
        uint256 indexed tokenId,
        IERC8217.Standard standard,
        address newWallet,
        address emitter
    );

    MockIdentityRegistry internal registry;
    AdapterImplementation internal adapter;
    MockERC721 internal token;

    address internal admin = makeAddr("admin");
    address internal controller = makeAddr("controller");
    address internal victim = makeAddr("victim");
    uint256 internal constant TID = 1;

    function setUp() external {
        registry = new MockIdentityRegistry();
        AdapterImplementation impl = new AdapterImplementation(address(registry));
        ERC1967Proxy proxy = new ERC1967Proxy(address(impl), abi.encodeCall(AdapterImplementation.initialize, (admin)));
        adapter = AdapterImplementation(address(proxy));
        token = new MockERC721();
        token.mint(controller, TID);
    }

    /// Success condition: a controller emits an agent->victim wallet claim without any victim consent.
    function test_controllerForgesAgentToVictimWalletClaim() external {
        bytes32 ubid = adapter.hashBinding(IERC8217.Standard.ERC721, address(token), TID);

        vm.expectEmit(true, true, true, true, address(adapter));
        emit CounterfactualAgentWalletSet(ubid, address(token), TID, IERC8217.Standard.ERC721, victim, controller);

        vm.prank(controller);
        bytes32 got = adapter.counterfactualSetAgentWallet(IERC8217.Standard.ERC721, address(token), TID, victim);
        assertEq(got, ubid, "returns the derived ubid; no consent from victim was required");
    }
}
