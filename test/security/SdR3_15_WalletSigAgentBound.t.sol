// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Test} from "forge-std/Test.sol";
import {ERC1967Proxy} from "@openzeppelin/contracts/proxy/ERC1967/ERC1967Proxy.sol";

import {AdapterImplementation} from "../../src/AdapterImplementation.sol";
import {IERC8217} from "../../src/interfaces/IERC8217.sol";
import {MockIdentityRegistry} from "../mocks/MockIdentityRegistry.sol";
import {MockERC721} from "../mocks/MockERC721.sol";

/// SdR3 #15 — WalletSigAgentBound. `setAgentWallet` forwards `(newWallet, deadline, signature)`
/// verbatim to the registry (:248). This tests whether a valid signature for agent A can be replayed
/// through the adapter onto agent B. The registry binds `agentId` into its EIP-712 struct hash, so
/// the replay fails. NOT one of the prior 40: R1 #19 flagged the forwarding as untested; no test
/// actually attempts the cross-agent replay. Defended: the registry's domain binds the agent id.
contract SdR3_15_WalletSigAgentBound is Test {
    MockIdentityRegistry internal registry;
    AdapterImplementation internal adapter;
    MockERC721 internal token;

    address internal admin = makeAddr("admin");
    address internal ownerA = makeAddr("ownerA");
    address internal ownerB = makeAddr("ownerB");
    address internal newWallet;
    uint256 internal newWalletPk;

    bytes32 internal constant TYPEHASH =
        keccak256("AgentWalletSet(uint256 agentId,address newWallet,address owner,uint256 deadline)");
    bytes32 internal constant DOMAIN_TYPEHASH =
        keccak256("EIP712Domain(string name,string version,uint256 chainId,address verifyingContract)");

    function setUp() external {
        (newWallet, newWalletPk) = makeAddrAndKey("newWallet");
        registry = new MockIdentityRegistry();
        AdapterImplementation impl = new AdapterImplementation(address(registry));
        ERC1967Proxy proxy = new ERC1967Proxy(address(impl), abi.encodeCall(AdapterImplementation.initialize, (admin)));
        adapter = AdapterImplementation(address(proxy));

        token = new MockERC721();
        token.mint(ownerA, 1);
        token.mint(ownerB, 2);
    }

    function _domainSeparator() internal view returns (bytes32) {
        return keccak256(
            abi.encode(
                DOMAIN_TYPEHASH,
                keccak256(bytes("ERC8004IdentityRegistry")),
                keccak256(bytes("1")),
                block.chainid,
                address(registry)
            )
        );
    }

    function _sign(uint256 agentId, uint256 deadline) internal view returns (bytes memory) {
        // The registry uses owner = ownerOf(agentId), which is the adapter (it holds the identity NFT).
        bytes32 structHash = keccak256(abi.encode(TYPEHASH, agentId, newWallet, address(adapter), deadline));
        bytes32 digest = keccak256(abi.encodePacked("\x19\x01", _domainSeparator(), structHash));
        (uint8 v, bytes32 r, bytes32 s) = vm.sign(newWalletPk, digest);
        return abi.encodePacked(r, s, v);
    }

    /// Success condition (defense): a signature valid for agent A is rejected when replayed on agent B.
    function test_walletSignatureIsNotReplayableAcrossAgents() external {
        vm.prank(ownerA);
        uint256 agentA = adapter.register(IERC8217.Standard.ERC721, address(token), 1, "ipfs://a");
        vm.prank(ownerB);
        uint256 agentB = adapter.register(IERC8217.Standard.ERC721, address(token), 2, "ipfs://b");

        uint256 deadline = block.timestamp + 1 minutes;
        bytes memory sigForA = _sign(agentA, deadline);

        // Valid on A.
        vm.prank(ownerA);
        adapter.setAgentWallet(agentA, newWallet, deadline, sigForA);
        assertEq(adapter.getAgentWallet(agentA), newWallet, "sig valid for its own agent");

        // Replaying A's signature on B reverts inside the registry.
        vm.prank(ownerB);
        vm.expectRevert(bytes("invalid wallet sig"));
        adapter.setAgentWallet(agentB, newWallet, deadline, sigForA);
    }
}
