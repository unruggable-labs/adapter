// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Test} from "forge-std/Test.sol";
import {ERC1967Proxy} from "@openzeppelin/contracts/proxy/ERC1967/ERC1967Proxy.sol";

import {Adapter8004} from "../../src/Adapter8004.sol";
import {IERC8217} from "../../src/interfaces/IERC8217.sol";
import {MockIdentityRegistry} from "../mocks/MockIdentityRegistry.sol";
import {MockDelegateRegistry} from "../mocks/MockDelegateRegistry.sol";
import {MockERC721} from "../mocks/MockERC721.sol";

/// SdR3 #8 — RegistrarEmitterSkew. `AgentBound.registeredBy` is `msg.sender` (:171). A delegate.xyz
/// delegate (not the token owner) may register, so the event records the delegate — an indexer that
/// treats `registeredBy` as "the owner" is misled. NOT one of the prior 40: R1 #16 was attestation
/// reputation-on-resale; none inspects the `registeredBy` / `emitter` provenance field. Defended-by-
/// design: the field is documented as the caller, and the delegate is a legitimate controller.
contract SdR3_8_RegistrarEmitterSkew is Test {
    event AgentBound(
        uint256 indexed agentId,
        IERC8217.Standard indexed standard,
        address indexed boundAddress,
        uint256 tokenId,
        address registeredBy
    );

    MockIdentityRegistry internal registry;
    Adapter8004 internal adapter;
    MockDelegateRegistry internal delegateRegistry;
    MockERC721 internal token;

    address internal admin = makeAddr("admin");
    address internal owner = makeAddr("owner");
    address internal delegate = makeAddr("delegate");
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

    /// Success condition: a non-owner delegate registers, and `registeredBy` is the delegate, not the owner.
    function test_delegateRegistersAndAppearsAsRegisteredBy() external {
        delegateRegistry.delegateERC721(delegate, owner, address(token), TID, bytes32(0), true);

        vm.expectEmit(false, true, true, true, address(adapter));
        emit AgentBound(0, IERC8217.Standard.ERC721, address(token), TID, delegate);

        vm.prank(delegate);
        adapter.register(IERC8217.Standard.ERC721, address(token), TID, "ipfs://a");
    }
}
