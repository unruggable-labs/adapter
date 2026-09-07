// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Test} from "forge-std/Test.sol";
import {ERC1967Proxy} from "@openzeppelin/contracts/proxy/ERC1967/ERC1967Proxy.sol";

import {AdapterImplementation} from "../../src/AdapterImplementation.sol";
import {IERC8217} from "../../src/interfaces/IERC8217.sol";
import {IERC8004IdentityRegistry} from "../../src/interfaces/IERC8004IdentityRegistry.sol";
import {MockIdentityRegistry} from "../mocks/MockIdentityRegistry.sol";
import {MockERC721} from "../mocks/MockERC721.sol";

/// SdR3 #5 — UnboundedBatchLoopGrief. `setMetadataBatch` (:222-238) loops over caller-supplied
/// entries with no length bound; a controller can drive an arbitrarily long loop. NOT one of the
/// prior 40: no prior scenario tests batch-loop economics. Defended by design: only the caller pays,
/// no other party is griefed and no state is corrupted.
contract SdR3_5_UnboundedBatchLoopGrief is Test {
    MockIdentityRegistry internal registry;
    AdapterImplementation internal adapter;
    MockERC721 internal token;

    address internal admin = makeAddr("admin");
    address internal owner = makeAddr("owner");
    uint256 internal constant TID = 1;

    function setUp() external {
        registry = new MockIdentityRegistry();
        AdapterImplementation impl = new AdapterImplementation(address(registry));
        ERC1967Proxy proxy = new ERC1967Proxy(address(impl), abi.encodeCall(AdapterImplementation.initialize, (admin)));
        adapter = AdapterImplementation(address(proxy));
        token = new MockERC721();
        token.mint(owner, TID);
    }

    /// Success condition: a large metadata batch is accepted; the caller alone bears the cost.
    function test_largeBatchIsAcceptedAndWrites() external {
        vm.prank(owner);
        uint256 agentId = adapter.register(IERC8217.Standard.ERC721, address(token), TID, "ipfs://a");

        uint256 n = 200;
        IERC8004IdentityRegistry.MetadataEntry[] memory entries = new IERC8004IdentityRegistry.MetadataEntry[](n);
        for (uint256 i; i < n; ++i) {
            entries[i] = IERC8004IdentityRegistry.MetadataEntry({
                metadataKey: string(abi.encodePacked("k", i)),
                metadataValue: bytes("v")
            });
        }

        vm.prank(owner);
        adapter.setMetadataBatch(agentId, entries);

        assertEq(
            adapter.getMetadata(agentId, string(abi.encodePacked("k", uint256(199)))), bytes("v"), "last entry written"
        );
    }
}
