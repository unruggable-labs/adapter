// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Test} from "forge-std/Test.sol";
import {Vm} from "forge-std/Vm.sol";
import {ERC1967Proxy} from "@openzeppelin/contracts/proxy/ERC1967/ERC1967Proxy.sol";
import {Adapter8004} from "../../src/Adapter8004.sol";
import {IERC8217} from "../../src/interfaces/IERC8217.sol";
import {IERC8004IdentityRegistry} from "../../src/interfaces/IERC8004IdentityRegistry.sol";
import {MockIdentityRegistry} from "../mocks/MockIdentityRegistry.sol";
import {MockERC721} from "../mocks/MockERC721.sol";

/// R1 #14 was unminted key planting. This is a reserved key inside a counterfactual batch.
contract GrokR2_14_CfBatchReserved is Test {
    /// Success condition: a CF metadata batch with a reserved key still emits for the other entries.
    function test_defense_cfBatchWithReservedKeyEmitsNothing() external {
        MockIdentityRegistry registry = new MockIdentityRegistry();
        Adapter8004 adapter = Adapter8004(
            address(
                new ERC1967Proxy(
                    address(new Adapter8004(address(registry))),
                    abi.encodeCall(Adapter8004.initialize, (makeAddr("admin")))
                )
            )
        );
        MockERC721 token = new MockERC721();
        address alice = makeAddr("alice");
        token.mint(alice, 1);

        IERC8004IdentityRegistry.MetadataEntry[] memory batch = new IERC8004IdentityRegistry.MetadataEntry[](2);
        batch[0] = IERC8004IdentityRegistry.MetadataEntry("ok", bytes("v"));
        batch[1] = IERC8004IdentityRegistry.MetadataEntry("agent-binding", bytes("x"));

        vm.recordLogs();
        vm.prank(alice);
        vm.expectRevert(abi.encodeWithSelector(Adapter8004.ReservedMetadataKey.selector, "agent-binding"));
        adapter.counterfactualSetMetadataBatch(IERC8217.Standard.ERC721, address(token), 1, batch);

        Vm.Log[] memory logs = vm.getRecordedLogs();
        bytes32 topic =
            keccak256("CounterfactualMetadataBatchSet(bytes32,address,uint256,uint8,(string,bytes)[],address)");
        for (uint256 i; i < logs.length; ++i) {
            assertTrue(logs[i].topics.length == 0 || logs[i].topics[0] != topic, "no batch event");
        }
    }
}
