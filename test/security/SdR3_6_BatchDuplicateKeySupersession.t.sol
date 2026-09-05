// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Test} from "forge-std/Test.sol";
import {ERC1967Proxy} from "@openzeppelin/contracts/proxy/ERC1967/ERC1967Proxy.sol";

import {Adapter8004} from "../../src/Adapter8004.sol";
import {IERC8217} from "../../src/interfaces/IERC8217.sol";
import {IERC8004IdentityRegistry} from "../../src/interfaces/IERC8004IdentityRegistry.sol";
import {MockIdentityRegistry} from "../mocks/MockIdentityRegistry.sol";
import {MockERC721} from "../mocks/MockERC721.sol";

/// SdR3 #6 — BatchDuplicateKeySupersession. `setMetadataBatch` writes and emits each entry in order
/// (:233-237). A batch with the same key twice emits two `MetadataSet` logs while the registry keeps
/// only the last value, so an indexer that takes the FIRST log-occurrence of a key diverges from
/// on-chain state. NOT one of the prior 40: R2 #3 tested batch reserved-key atomicity; none tests
/// duplicate-key supersession vs event ordering. Defended: registry state is last-write-wins and
/// consistent; a first-wins indexer is a consumer bug, not a contract defect.
contract SdR3_6_BatchDuplicateKeySupersession is Test {
    MockIdentityRegistry internal registry;
    Adapter8004 internal adapter;
    MockERC721 internal token;

    address internal admin = makeAddr("admin");
    address internal owner = makeAddr("owner");
    uint256 internal constant TID = 1;

    function setUp() external {
        registry = new MockIdentityRegistry();
        Adapter8004 impl = new Adapter8004(address(registry));
        ERC1967Proxy proxy = new ERC1967Proxy(address(impl), abi.encodeCall(Adapter8004.initialize, (admin)));
        adapter = Adapter8004(address(proxy));
        token = new MockERC721();
        token.mint(owner, TID);
    }

    /// Success condition: duplicate keys in one batch resolve to the LAST value on-chain.
    function test_duplicateKeyBatchKeepsLastValue() external {
        vm.prank(owner);
        uint256 agentId = adapter.register(IERC8217.Standard.ERC721, address(token), TID, "ipfs://a");

        IERC8004IdentityRegistry.MetadataEntry[] memory entries = new IERC8004IdentityRegistry.MetadataEntry[](2);
        entries[0] = IERC8004IdentityRegistry.MetadataEntry({metadataKey: "k", metadataValue: bytes("first")});
        entries[1] = IERC8004IdentityRegistry.MetadataEntry({metadataKey: "k", metadataValue: bytes("second")});

        vm.prank(owner);
        adapter.setMetadataBatch(agentId, entries);

        assertEq(adapter.getMetadata(agentId, "k"), bytes("second"), "on-chain state is the last write, not the first");
    }
}
